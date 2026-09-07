# scripts/fpga-load.sh — program a bitstream into FPGA SRAM (volatile).
#
#   nix run .#fpga-load -- path/to/design.fs
#
# SRAM loads are the fast inner loop: they take effect immediately and vanish on
# power cycle, so they cannot brick anything. Use .#fpga-flash for persistence.
set -euo pipefail

fpga_preflight || exit 1

fs=$(fpga_resolve_fs "${1:-}") || exit 1
echo "=== load to SRAM (volatile): $fs ==="

if ! ofl -m "$fs"; then
  echo
  echo "RESULT: FAIL — SRAM programming did not complete."
  fpga_perm_hint
  exit 1
fi

echo
echo "RESULT: PASS — bitstream loaded to SRAM. It is gone on the next power cycle."
