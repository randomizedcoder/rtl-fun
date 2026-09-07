# scripts/fpga-uart.sh — read the board's UART (Phase 8).
#
#   nix run .#fpga-uart              # auto-detect the baud, then stream
#   nix run .#fpga-uart -- 115200    # force a baud
#   FPGA_UART_SECS=10 nix run .#fpga-uart
#
# The board's single "USB JTAG&UART" cable exposes two FT2232 interfaces:
# A is the JTAG we program over, B is this UART. On the host that is the SECOND
# ttyUSB node (see $FPGA_UART in scripts/lib/fpga.sh).
#
# Why auto-detect: Sipeed document a debugger-firmware bug where the actual baud
# comes out FOUR TIMES the configured one, so a design transmitting at 115200 can
# need the host set to 28800 (or 460800) to read cleanly. Rather than trust any
# of that, we try candidates and score each by how much clean printable ASCII it
# yields. The winner is reported explicitly so the real answer gets written down.
set -euo pipefail

SECS="${FPGA_UART_SECS:-4}"
PORT="$FPGA_UART"

if [ ! -e "$PORT" ]; then
  echo "ERROR: no UART device at $PORT" >&2
  echo "  Expected the second FT2232 interface. Check:" >&2
  echo "    ls -l /dev/serial/by-id/ | grep -i sipeed" >&2
  exit 1
fi
if [ ! -r "$PORT" ] || [ ! -w "$PORT" ]; then
  echo "ERROR: $PORT is not readable/writable by $(id -un)." >&2
  echo "  You need the 'dialout' group. In a shell that predates the NixOS" >&2
  echo "  switch, use:  sg dialout -c '<command>'" >&2
  exit 1
fi

raw_read() {          # raw_read <baud> <secs> <outfile>
  stty -F "$PORT" "$1" raw -echo -echoe -echok -echoctl -echoke -crtscts 2>/dev/null || return 1
  timeout "$2" cat "$PORT" > "$3" 2>/dev/null || true
  [ -s "$3" ]
}

# Score a capture: fraction of bytes that are printable ASCII, tab, CR or LF.
score() {
  python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
if not d:
    print("0 0"); raise SystemExit
ok = sum(1 for b in d if 32 <= b < 127 or b in (9, 10, 13))
print(f"{ok*100//len(d)} {len(d)}")
PY
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

if [ $# -ge 1 ]; then
  BAUD="$1"
  echo "=== reading $PORT at $BAUD for ${SECS}s ==="
else
  echo "=== auto-detecting baud on $PORT (${SECS}s each) ==="
  echo "    candidates include 28800 and 460800 because of the documented"
  echo "    4x-baud debugger-firmware bug."
  best=0; best_baud=""
  for b in 115200 28800 460800 9600 19200 38400 57600 230400 921600; do
    if raw_read "$b" "$SECS" "$tmp/$b"; then
      read -r pct len < <(score "$tmp/$b")
      printf '  %7s : %4s bytes, %3s%% printable\n' "$b" "$len" "$pct"
      if [ "$pct" -gt "$best" ]; then best="$pct"; best_baud="$b"; fi
    else
      printf '  %7s : no data\n' "$b"
    fi
  done
  echo
  if [ -z "$best_baud" ] || [ "$best" -lt 90 ]; then
    echo "RESULT: FAIL — no baud produced clean text (best ${best}% at ${best_baud:-none})."
    echo "  Is a design driving uart_tx (P15) loaded? Try:"
    echo "    nix run .#fpga-build -- hello && nix run .#fpga-load -- build/fpga-hello/impl/pnr"
    exit 1
  fi
  BAUD="$best_baud"
  echo "RESULT: baud is $BAUD (${best}% printable)"
  if [ "$BAUD" != "115200" ]; then
    echo "  NOTE: the design transmits at 115200, so a different host baud here"
    echo "        means the debugger firmware is rescaling it. Record this."
  fi
  echo
fi

echo "=== stream ($BAUD, ${SECS}s) ==="
raw_read "$BAUD" "$SECS" "$tmp/out" || true
cat -v "$tmp/out"
echo
echo "=== ${SECS}s of traffic ended ==="
