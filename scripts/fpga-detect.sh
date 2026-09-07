# scripts/fpga-detect.sh — first hardware contact: scan the JTAG chain.
#
#   nix run .#fpga-detect
#
# This is the go/no-go for the whole board bring-up: it proves host permissions,
# cable selection, MPSSE, and the FPGA itself in one shot. Expect IDCODE
# 0x0001081b -> Gowin GW5AST GW5AST-138 (openFPGALoader src/part.hpp:448).
set -euo pipefail

fpga_preflight || exit 1

echo "=== JTAG chain scan (board=$FPGA_BOARD, expecting $FPGA_IDCODE) ==="

out=""
if ! out=$(ofl --detect 2>&1); then
  echo "$out"
  echo
  echo "RESULT: FAIL — openFPGALoader could not scan the chain."
  fpga_perm_hint
  exit 1
fi
echo "$out"

echo
# Compare NUMERICALLY, not as text: openFPGALoader prints the idcode without
# leading zeros (0x1081b), so a substring match against 0x0001081b never fires.
found=$(grep -oiE 'idcode[[:space:]]+0x[0-9a-f]+' <<<"$out" \
        | grep -oiE '0x[0-9a-f]+' | head -1)

if [ -z "$found" ]; then
  echo "RESULT: FAIL — no IDCODE in the scan output at all."
  fpga_perm_hint
  exit 1
fi

if [ "$((found))" -eq "$((FPGA_IDCODE))" ]; then
  echo "RESULT: PASS — found IDCODE $found (= $FPGA_IDCODE), Gowin GW5AST-138."
else
  echo "RESULT: UNEXPECTED — the chain responded with $found, expected $FPGA_IDCODE."
  echo "  A responding-but-wrong IDCODE usually means the cable is right and the"
  echo "  part is not what we think; record the actual value in"
  echo "  docs/fpga-bringup-tang-mega-138k-pro.md before going further."
  exit 1
fi
