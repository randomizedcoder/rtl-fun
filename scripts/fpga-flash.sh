# scripts/fpga-flash.sh — program a bitstream into the on-board SPI flash (persistent).
#
#   nix run .#fpga-flash -- path/to/design.fs
#
# The design survives power cycles: the FPGA reloads it from flash at boot. Slower
# than .#fpga-load, so use SRAM for iteration and flash only when you want the
# board to come up standing on its own.
#
# This is the step most likely to need the openFPGALoader fork: Arora-V (GW5A/
# GW5AST) had SRAM erase/load bugs when the flash is blank and the timeout bit is
# set, fixed upstream in ab8d8fc (2025-03-06). That fix IS in nixpkgs' 1.1.1
# (released 2026-03-11), so it should just work — if it does not, try the fork.
set -euo pipefail

fpga_preflight || exit 1

fs=$(fpga_resolve_fs "${1:-}") || exit 1
echo "=== write to SPI flash (persistent): $fs ==="
echo "This rewrites the board's boot bitstream. Ctrl-C now if that is not what you want."

if ! ofl -f "$fs"; then
  echo
  echo "RESULT: FAIL — flash programming did not complete."
  echo "  If this is an Arora-V erase/timeout error, retry with the fork:"
  echo "    OPENFPGALOADER=\$(nix build --no-link --print-out-paths .#openfpgaloader-fork)/bin/openFPGALoader \\"
  echo "      nix run .#fpga-flash -- $fs"
  fpga_perm_hint
  exit 1
fi

echo
echo "RESULT: PASS — flash written. Power-cycle the board; the design should return unaided."
