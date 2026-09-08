# scripts/fpga-m2-rtl.sh — flatten the M2 SystemVerilog to Verilog for GowinSynthesis.
#
#   nix run .#fpga-m2-rtl     -> build/fpga-m2-rtl/parser_m2.v
#
# Same route as fpga-m1-rtl (see there for the SP00018 / sv2v / yosys rationale): our
# SystemVerilog trips a GowinSynthesis front-end bug, so we sv2v the parser + m2_top to
# plain Verilog and yosys-flatten it to one self-contained module Gowin accepts. The
# difference from M1 is the design: m2_top receives the packet over UART (uart_rx.v)
# and streams the result back (uart_tx.v), so BOTH UART modules are included, and only
# the shared program + CAM are baked from ROM (no packet ROM — the packet is injected).
#
# common.sh (REPO_ROOT / RTL / TB) is prepended by the Nix wrapper.
set -euo pipefail

OUT_DIR="${FPGA_M2_RTL_OUT:-$REPO_ROOT/build/fpga-m2-rtl}"
ROMS="$REPO_ROOT/fpga/tang-mega-138k-pro/roms/m1"       # shared program.hex + cam.hex
SV2V_OUT="$OUT_DIR/parser_m2_sv2v.v"
HOST_OUT="$OUT_DIR/parser_m2_hostpaths.v"
UART_TX="$REPO_ROOT/fpga/tang-mega-138k-pro/src/uart_tx.v"
UART_RX="$REPO_ROOT/fpga/tang-mega-138k-pro/src/uart_rx.v"
FLAT="$OUT_DIR/parser_m2.v"
mkdir -p "$OUT_DIR"

if [ ! -r "$ROMS/program.hex" ] || [ ! -r "$ROMS/cam.hex" ]; then
  echo "ERROR: no program/cam ROM at $ROMS — run 'nix run .#fpga-m1-roms' first." >&2
  exit 1
fi

# Step 1 — sv2v the SystemVerilog (parser datapath + parser_top + m2_top) to Verilog.
# --define=SYNTHESIS drops the sim-only memory zero-init loops so $readmemh survives
# the yosys bake (docs/phase-8-status.md #18).
sv2v --define=SYNTHESIS -I "$RTL" --write="$SV2V_OUT" \
  "$RTL/parser_pkg.sv" \
  "$RTL/parser_cam.sv" \
  "$RTL/parser_pktbuf.sv" \
  "$RTL/parser_decode.sv" \
  "$RTL/parser_execute.sv" \
  "$TB/parser_top.sv" \
  "$REPO_ROOT/fpga/tang-mega-138k-pro/src/m2_top.sv"

# Step 2 — rewrite baked GUEST rom paths (/work/...) to real HOST paths for the yosys
# $readmemh bake below (program + CAM only; the packet buffer is loaded over UART).
sed "s#/work/fpga/tang-mega-138k-pro/roms/m1#$ROMS#g" "$SV2V_OUT" > "$HOST_OUT"

# Step 3 — yosys clean/flatten to one self-contained module (both UARTs inlined).
yosys -q -p "
  read_verilog $HOST_OUT $UART_TX $UART_RX;
  hierarchy -top m2_top;
  flatten; proc; opt -purge; memory_collect; opt_clean;
  rename -top m2_top;
  write_verilog -noattr $FLAT
"

echo "fpga-m2-rtl: wrote $FLAT ($(wc -l < "$FLAT") lines, $(grep -c '^module' "$FLAT") modules)"
echo "  guest path baked into m2.tcl: /work/build/fpga-m2-rtl/parser_m2.v"
echo "  next:  nix run .#fpga-build -- m2"
