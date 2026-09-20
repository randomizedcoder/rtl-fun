# scripts/fpga-mig-check.sh
#
# Phase-B verify-before-buy: validate a DDR3 pinout by generating + OOC-synthesizing
# its MIG controller from an explicit .prj — NO board, NO full SoC. This retires the
# MEDIUM-risk DDR3 item for the AX7325B: its 2 GiB / 64-bit layout (4x MT41K256M16,
# 8 byte lanes across BANK32/33/34, AXI addr width 31) is drafted in
# fpga/ax7325b/mig_ax7325b.prj; this proves the byte-lane/bank grouping is legal on
# xc7k325tffg900-2 before the card is purchased.
#
#   nix run .#fpga-mig-check                 validate fpga/ax7325b/mig_ax7325b.prj (default)
#   nix run .#fpga-mig-check -- ax7325b      same, explicit
#   nix run .#fpga-mig-check -- genesys2     validate the stock 32-bit genesys2 .prj (control)
#
# Board selection maps to fpga/<board>/mig_<board>.prj. The tcl is board-file-free
# (part-only) — pins come from the .prj, so no vendor board_part is needed.
#
# HOST-TOOL DEPENDENCY (documented impurity, like the other Vivado targets): Vivado is
# NOT in nixpkgs — `vivado` on PATH (source settings64.sh) or $VIVADO; on NixOS use the
# FHS sandbox (nix run .#vivado-fhs). `nix run` passes the caller's env through — no
# --impure. CVA6's MIG path uses only `vivado`; this script needs no toolchain.
#
# Injected by the Nix wrapper: REPO_ROOT (common.sh).
set -euo pipefail

: "${REPO_ROOT:?REPO_ROOT not set — the Nix wrapper injects it via common.sh}"

BOARD="${1:-ax7325b}"
PART="${XILINX_PART:-xc7k325tffg900-2}"
VIVADO="${VIVADO:-vivado}"

PRJ="${MIG_PRJ:-$REPO_ROOT/fpga/$BOARD/mig_${BOARD}.prj}"
TCL="$REPO_ROOT/fpga/vivado/mig-check.tcl"
OUT_DIR="${FPGA_MIG_CHECK_OUT:-$REPO_ROOT/build/fpga-mig-check/$BOARD}"
LOG="$OUT_DIR/mig-check.log"

require_vivado() {
  if command -v "$VIVADO" >/dev/null 2>&1; then return 0; fi
  echo "ERROR: vivado not found (looked for '$VIVADO')" >&2
  echo "  install free Vivado (2026.1 'Basic' tier covers xc7k325t), generate its" >&2
  echo "  (free) node-locked license, then either:" >&2
  echo "    source /path/to/Xilinx/Vivado/<ver>/settings64.sh   # puts vivado on PATH" >&2
  echo "    export VIVADO=/path/to/Xilinx/Vivado/<ver>/bin/vivado" >&2
  echo "  on NixOS use the FHS sandbox:" >&2
  echo "    export VIVADO_SETTINGS=/path/to/Xilinx/<ver>/Vivado/settings64.sh" >&2
  echo "    export VIVADO=\"\$(nix build --no-link --print-out-paths .#vivado-fhs-vivado)/bin/vivado\"" >&2
  exit 1
}
require_vivado

[ -f "$PRJ" ] || { echo "ERROR: MIG .prj not found: $PRJ" >&2; exit 2; }
[ -f "$TCL" ] || { echo "ERROR: tcl not found: $TCL" >&2; exit 2; }

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "=== fpga-mig-check: DDR3 MIG generate + OOC synth ==="
echo "    board:  $BOARD"
echo "    part:   $PART"
echo "    prj:    $PRJ"
echo "    vivado: $(command -v "$VIVADO")"
echo "    out:    $OUT_DIR"

set +e
( cd "$OUT_DIR" && "$VIVADO" -mode batch -nojournal -nolog \
    -source "$TCL" -tclargs "$PART" "$PRJ" ) 2>&1 | tee "$LOG"
rc="${PIPESTATUS[0]}"
set -e

echo ""
echo "=== fpga-mig-check: VERDICT (board=$BOARD, part=$PART) ==="
gen_ok=0; syn_ok=0
grep -q "MIG_GENERATE_OK" "$LOG" 2>/dev/null && gen_ok=1
grep -q "MIG_SYNTH_OK"    "$LOG" 2>/dev/null && syn_ok=1
if [ "$gen_ok" = 1 ]; then echo "  GENERATE: OK — controller elaborated from the .prj (byte-lane/bank layout legal)"; else echo "  GENERATE: FAILED — inspect $LOG" >&2; fi
if [ "$syn_ok" = 1 ]; then echo "  OOC SYNTH: OK — MIG maps onto $PART IOBs/banks"; else echo "  OOC SYNTH: not completed — inspect $LOG" >&2; fi
grep -m1 "MIG_SYNTH_STATUS:" "$LOG" 2>/dev/null | sed 's/^/  /' || true

if [ "$gen_ok" = 1 ] && [ "$syn_ok" = 1 ]; then
  echo "  RESULT: DDR3 pinout is LEGAL on $PART — the $BOARD memory layout is validated pre-buy."
  exit 0
fi
echo "  RESULT: DDR3 validation INCOMPLETE — see $LOG" >&2
exit "${rc:-1}"
