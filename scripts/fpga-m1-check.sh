# scripts/fpga-m1-check.sh — M1 host oracle: read flow_keys over UART, diff vs model.
#
#   nix run .#fpga-m1-check              read the board, PASS/FAIL vs the model
#   nix run .#fpga-m1-check -- 115200    force a baud
#   FPGA_UART_SECS=6 nix run .#fpga-m1-check
#
# The M1 design (fpga/tang-mega-138k-pro/src/m1_top.sv) parses one ROM-baked packet
# and streams the result forever as:
#     FK <96 hex = 48 flow_keys bytes> <8 hex exit code> <4 hex seq>\r\n
# This reads that line and compares it, byte-for-byte, against the SAME golden vectors
# the Verilator suite uses (roms/m1/expected.hex + params.hex) — the Phase-6 oracle
# with the transport swapped from Verilator DPI to a UART. A match is the M1 exit
# criterion: our RTL parsed a real packet on real silicon and got the model's answer.
#
# fpga.sh (FPGA_UART + fpga_perm_hint) is prepended by the Nix wrapper.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$PWD}"
ROMS="$REPO_ROOT/fpga/tang-mega-138k-pro/roms/m1"
SECS="${FPGA_UART_SECS:-5}"
PORT="$FPGA_UART"

if [ ! -r "$ROMS/expected.hex" ] || [ ! -r "$ROMS/params.hex" ]; then
  echo "ERROR: missing $ROMS/{expected,params}.hex — run 'nix run .#fpga-m1-roms' first." >&2
  exit 1
fi
if [ ! -e "$PORT" ] || [ ! -r "$PORT" ] || [ ! -w "$PORT" ]; then
  echo "ERROR: UART $PORT not accessible by $(id -un)." >&2
  echo "  Needs the 'dialout' group; in a pre-switch shell use: sg dialout -c '<cmd>'" >&2
  fpga_perm_hint
  exit 1
fi

# expected flow_keys as one lowercase 96-char hex string; expected code = params line 3.
exp_fk=$(tr -d '\n' < "$ROMS/expected.hex" | tr 'A-F' 'a-f' | tr -cd '0-9a-f')
exp_code=$(sed -n 3p "$ROMS/params.hex" | tr 'A-F' 'a-f' | tr -cd '0-9a-f')

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

raw_read() {          # raw_read <baud> <secs> <outfile>
  stty -F "$PORT" "$1" raw -echo -echoe -echok -echoctl -echoke -crtscts 2>/dev/null || return 1
  timeout "$2" cat "$PORT" > "$3" 2>/dev/null || true
  [ -s "$3" ]
}

# Baud candidates: 115200 is what the design sends; 28800 / 460800 cover the
# documented 4x-baud firmware rescale (not present on this board, but cheap to try).
if [ $# -ge 1 ]; then bauds=("$1"); else bauds=(115200 28800 460800); fi

for b in "${bauds[@]}"; do
  echo "=== reading $PORT at $b for ${SECS}s ==="
  raw_read "$b" "$SECS" "$tmp/cap" || { echo "  no data at $b"; continue; }
  if EXP_FK="$exp_fk" EXP_CODE="$exp_code" python3 - "$tmp/cap" <<'PY'
import os, re, sys
data = open(sys.argv[1], 'rb').read().decode('latin-1')
exp_fk, exp_code = os.environ['EXP_FK'], os.environ['EXP_CODE']
m = None
for line in data.splitlines():
    g = re.match(r'^FK ([0-9a-fA-F]{96}) ([0-9a-fA-F]{8}) ([0-9a-fA-F]{4})\s*$', line.strip())
    if g:
        m = g  # keep the last complete, well-formed frame seen
if not m:
    print("  no well-formed 'FK ...' line at this baud"); sys.exit(2)
fk, code, seq = m.group(1).lower(), m.group(2).lower(), m.group(3).lower()
ok = True
if fk != exp_fk:
    ok = False
    print("  flow_keys MISMATCH")
    print("    got     ", fk)
    print("    expected", exp_fk)
    # point at the first differing byte
    for i in range(0, 96, 2):
        if fk[i:i+2] != exp_fk[i:i+2]:
            print(f"    first diff at byte {i//2}: {fk[i:i+2]} != {exp_fk[i:i+2]}"); break
else:
    print("  flow_keys MATCH (48 bytes)")
if code != exp_code:
    ok = False
    print(f"  exit code MISMATCH: got {code}, expected {exp_code}")
else:
    print(f"  exit code MATCH ({code})")
print(f"  live seq counter = {seq}")
sys.exit(0 if ok else 3)
PY
  then
    echo
    echo "RESULT: PASS — M1 parsed the packet on the board == libparsermodel (baud $b)."
    exit 0
  else
    rc=$?
    [ "$rc" -eq 2 ] && continue   # nothing parseable at this baud: try the next
    echo
    echo "RESULT: FAIL — a frame was read but did not match the model (baud $b)."
    exit 1
  fi
done

echo
echo "RESULT: FAIL — no well-formed M1 frame on $PORT."
echo "  Is the M1 bitstream loaded?  nix run .#fpga-load -- build/fpga-m1/impl/pnr"
exit 1
