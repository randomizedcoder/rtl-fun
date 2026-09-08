# scripts/fpga-m2-loopback-check.sh — M2 rung 0: confirm the UART RX pin on the board.
#
#   nix run .#fpga-m2-loopback-check              write a byte pattern, verify the echo
#   nix run .#fpga-m2-loopback-check -- 115200    force a baud
#
# The m2loop design (fpga/tang-mega-138k-pro/src/m2loop_top.v) echoes uart_rx (C21,
# PMOD2_IO0 <- adapter TX) straight back out uart_tx (B20, PMOD2_IO1 -> adapter RX).
# This sends a known 256-byte pattern (every value 0x00..0xFF) down the adapter port
# and checks the whole sequence comes back. If it does, the external 3.3V USB-UART on
# PMOD2 is a working full-duplex fabric UART and M2 packet injection has its return
# path. (The USB debug UART can't do this: its RX pin N16 is CPU-dedicated.)
#
# fpga.sh (FPGA_UART + fpga_perm_hint) is prepended by the Nix wrapper.
set -euo pipefail

PORT="$FPGA_UART"
BAUD="${1:-115200}"

if [ ! -e "$PORT" ] || [ ! -r "$PORT" ] || [ ! -w "$PORT" ]; then
  echo "ERROR: UART $PORT not accessible by $(id -un)." >&2
  echo "  Needs the 'dialout' group; in a pre-switch shell use: sg dialout -c '<cmd>'" >&2
  fpga_perm_hint
  exit 1
fi

echo "=== M2 loopback check on $PORT at $BAUD ==="
# Raw, no echo, no flow control (so 0x11/0x13 pass through), no CR/LF mangling.
stty -F "$PORT" "$BAUD" raw -echo -echoe -echok -echoctl -echoke -crtscts -ixon -ixoff

PORT="$PORT" python3 - <<'PY'
import os, sys, time, select

port = os.environ['PORT']
pattern = bytes(range(256))          # every 8-bit value, lots of edges

fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
try:
    # Drain anything already buffered.
    while True:
        r, _, _ = select.select([fd], [], [], 0.1)
        if not r: break
        try:
            if not os.read(fd, 4096): break
        except BlockingIOError:
            break

    os.write(fd, pattern)

    # 256 bytes each way at 115200 8N1 ~= 44 ms round trip; give it generously long.
    got = bytearray()
    deadline = time.time() + 2.0
    while time.time() < deadline and len(got) < len(pattern) + 16:
        r, _, _ = select.select([fd], [], [], deadline - time.time())
        if not r: continue
        try:
            chunk = os.read(fd, 4096)
        except BlockingIOError:
            continue
        if chunk:
            got += chunk
finally:
    os.close(fd)

got = bytes(got)
idx = got.find(pattern)
print(f"sent {len(pattern)} bytes, received {len(got)} bytes")
if idx >= 0:
    print("RESULT: PASS — full 256-byte pattern echoed back; external UART on PMOD2 (C21/B20) confirmed.")
    sys.exit(0)

# Partial diagnostics: how much of the head of the pattern matched contiguously.
run = 0
for i in range(min(len(got), len(pattern))):
    if got[i] == pattern[i]:
        run += 1
    else:
        break
print(f"RESULT: FAIL — pattern not found intact (longest head match {run} bytes).")
print(f"  first 32 received: {got[:32].hex()}")
sys.exit(1)
PY
