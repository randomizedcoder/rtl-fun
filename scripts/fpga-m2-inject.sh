# scripts/fpga-m2-inject.sh — M2 host oracle: inject packets over UART, diff flow_keys.
#
#   FPGA_UART=/dev/ttyUSB2 nix run .#fpga-m2-inject            baseline packet (roms/m1)
#   FPGA_UART=/dev/ttyUSB2 nix run .#fpga-m2-inject -- --suite the whole 22-case suite
#
# With the m2 bitstream loaded, this sends each packet to the FPGA framed as
#   0x7E  plen_hi plen_lo  nbuf_hi nbuf_lo  <nbuf buffer bytes>
# (plen = PKT_LEN from params.hex; nbuf = bytes in pktbuf.hex), then reads the one
# reply line
#   FK <96 hex flow_keys> <8 hex code> <4 hex seq>\r\n
# and compares it, byte-for-byte, against the case's expected.hex + EXP_CODE — the
# Verilator suite's oracle, transport swapped to a real wire (host -> FPGA -> host).
#
# --suite regenerates the directed suite from the golden model (gen_vectors --suite),
# so it needs no committed per-case vectors; the baseline path uses the committed
# roms/m1 images. fpga.sh (FPGA_UART + fpga_perm_hint) and common.sh (gen_vectors) are
# prepended by the Nix wrapper.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$PWD}"
PORT="$FPGA_UART"
BAUD="${FPGA_BAUD:-115200}"
MODE="${1:-}"

if [ ! -e "$PORT" ] || [ ! -r "$PORT" ] || [ ! -w "$PORT" ]; then
  echo "ERROR: UART $PORT not accessible by $(id -un)." >&2
  echo "  The M2 adapter is usually /dev/ttyUSB2: FPGA_UART=/dev/ttyUSB2 <cmd>" >&2
  echo "  Needs the 'dialout' group; in a pre-switch shell use: sg dialout -c '<cmd>'" >&2
  fpga_perm_hint
  exit 1
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Assemble the list of case directories (each with params.hex/pktbuf.hex/expected.hex).
casedirs=()
if [ "$MODE" = "--suite" ]; then
  echo "=== regenerating the directed suite from the golden model ==="
  mkdir -p "$tmp/suite"
  gen_vectors "$tmp/suite" --suite >/dev/null
  while IFS= read -r d; do casedirs+=("$d"); done \
    < <(find "$tmp/suite/cases" -mindepth 1 -maxdepth 1 -type d | sort)
else
  casedirs=("$REPO_ROOT/fpga/tang-mega-138k-pro/roms/m1")
fi
echo "=== injecting ${#casedirs[@]} packet(s) on $PORT at $BAUD ==="

stty -F "$PORT" "$BAUD" raw -echo -echoe -echok -echoctl -echoke -crtscts -ixon -ixoff

PORT="$PORT" CASES="${casedirs[*]}" python3 - <<'PY'
import os, re, sys, time, select

port  = os.environ['PORT']
cases = os.environ['CASES'].split()

def readfile_bytes(path):
    out = bytearray()
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(int(line, 16) & 0xFF)
    return bytes(out)

def read_params(path):          # PKT_LEN, META_LEN, EXP_CODE (32-bit, two's complement)
    vals = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                vals.append(int(line, 16))
    plen, meta_len, code = vals[0], vals[1], vals[2]
    if code >= 0x80000000:
        code -= 0x100000000
    return plen, meta_len, code

fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)

def drain():
    while True:
        r, _, _ = select.select([fd], [], [], 0.05)
        if not r: break
        try:
            if not os.read(fd, 4096): break
        except BlockingIOError:
            break

def read_line(timeout=2.0):
    buf = bytearray()
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], deadline - time.time())
        if not r: continue
        try:
            chunk = os.read(fd, 256)
        except BlockingIOError:
            continue
        if not chunk: continue
        buf += chunk
        if b"\n" in buf:
            for ln in buf.split(b"\n"):
                if ln.startswith(b"FK "):
                    return ln.decode('latin-1').strip()
    return None

npass = nfail = 0
try:
    for d in cases:
        name = os.path.basename(d.rstrip('/'))
        plen, meta_len, exp_code = read_params(os.path.join(d, 'params.hex'))
        pkt = readfile_bytes(os.path.join(d, 'pktbuf.hex'))
        exp_fk = readfile_bytes(os.path.join(d, 'expected.hex')).hex()
        nbuf = len(pkt)

        frame = bytes([0x7E, (plen >> 8) & 0xFF, plen & 0xFF,
                       (nbuf >> 8) & 0xFF, nbuf & 0xFF]) + pkt
        drain()
        os.write(fd, frame)

        line = read_line()
        if line is None:
            print(f"  {name:26s} FAIL — no reply")
            nfail += 1
            continue
        m = re.match(r'^FK ([0-9a-fA-F]+) ([0-9a-fA-F]{8}) ([0-9a-fA-F]{4})$', line)
        if not m:
            print(f"  {name:26s} FAIL — bad reply: {line!r}")
            nfail += 1
            continue
        got_fk = m.group(1).lower()[:meta_len*2]
        got_code = int(m.group(2), 16)
        if got_code >= 0x80000000: got_code -= 0x100000000
        ok_fk   = (got_fk == exp_fk.lower())
        ok_code = (got_code == exp_code)
        if ok_fk and ok_code:
            print(f"  {name:26s} PASS  code={got_code}")
            npass += 1
        else:
            print(f"  {name:26s} FAIL  code got={got_code} exp={exp_code}  fk_match={ok_fk}")
            if not ok_fk:
                print(f"      got  {got_fk}")
                print(f"      exp  {exp_fk.lower()}")
            nfail += 1
finally:
    os.close(fd)

print("-" * 50)
print(f"M2 inject: {npass+nfail} case(s), {nfail} failure(s)")
sys.exit(1 if nfail else 0)
PY
