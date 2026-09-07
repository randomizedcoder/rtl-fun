# scripts/fpga-m1-rtl.sh — flatten the M1 SystemVerilog to Verilog for GowinSynthesis.
#
#   nix run .#fpga-m1-rtl     -> build/fpga-m1-rtl/parser_m1.v
#
# Why this exists. GowinSynthesis CAN parse our SystemVerilog (packages, always_comb,
# packed structs) but then aborts inside synthesis with an internal
# ERROR (SP00018) "error bus name set" on our packed-struct signals/ports — even
# after every false-latch it warned about was cleared (docs/phase-8-status.md #13).
# sv2v flattens the packed structs to plain bit-vectors, which GowinSynthesis handles.
# For this parser-ONLY design the BRAM-inference harm that makes a full-CVA6 flatten
# a bad idea (fpga-platform-assessment.md §5a) does not apply — the parser has no
# large cache/tag SRAMs. This is the same tool the formal flow already uses.
#
# The output is a BUILD ARTIFACT (gitignored), regenerated from the pinned RTL by the
# pinned sv2v on every run, so it is reproducible without churning the tree — the same
# way build/formal/parser_flat.v is treated. The microVM 9p-mounts the repo, so the
# guest reads it at /work/build/fpga-m1-rtl/parser_m1.v (baked into m1.tcl).
#
# common.sh (REPO_ROOT / RTL / TB) is prepended by the Nix wrapper.
set -euo pipefail

OUT_DIR="${FPGA_M1_RTL_OUT:-$REPO_ROOT/build/fpga-m1-rtl}"
ROMS="$REPO_ROOT/fpga/tang-mega-138k-pro/roms/m1"
SV2V_OUT="$OUT_DIR/parser_m1_sv2v.v"
HOST_OUT="$OUT_DIR/parser_m1_hostpaths.v"
UART="$REPO_ROOT/fpga/tang-mega-138k-pro/src/uart_tx.v"
FLAT="$OUT_DIR/parser_m1.v"
mkdir -p "$OUT_DIR"

if [ ! -r "$ROMS/program.hex" ]; then
  echo "ERROR: no ROM images at $ROMS — run 'nix run .#fpga-m1-roms' first." >&2
  exit 1
fi

# Step 1 — sv2v: SystemVerilog (packages, packed structs, always_comb) -> Verilog.
# --define=SYNTHESIS drops the sim-only memory zero-init loops so $readmemh survives
# the yosys bake (docs/phase-8-status.md #18).
sv2v --define=SYNTHESIS -I "$RTL" --write="$SV2V_OUT" \
  "$RTL/parser_pkg.sv" \
  "$RTL/parser_cam.sv" \
  "$RTL/parser_pktbuf.sv" \
  "$RTL/parser_decode.sv" \
  "$RTL/parser_execute.sv" \
  "$TB/parser_top.sv" \
  "$REPO_ROOT/fpga/tang-mega-138k-pro/src/m1_top.sv"

# Step 2 — rewrite the baked-in GUEST rom paths (/work/...) to real HOST paths so the
# yosys $readmemh below can read them and bake the init into the netlist (no runtime
# file dependency at Gowin synth time).
sed "s#/work/fpga/tang-mega-138k-pro/roms/m1#$ROMS#g" "$SV2V_OUT" > "$HOST_OUT"

# Step 3 — yosys clean: GowinSynthesis's SV/elaboration front end floods SP00018 on the
# raw sv2v output (docs/phase-8-status.md #13). Flatten to a single module (kills the
# $paramod$… names Gowin rejects) and re-emit plain Verilog it can digest — the repo's
# flat_synth.v technique (docs/gowin-microvm.md). uart_tx.v is included so the flattened
# top is self-contained.
yosys -q -p "
  read_verilog $HOST_OUT $UART;
  hierarchy -top m1_top;
  flatten; proc; opt -purge; memory_collect; opt_clean;
  rename -top m1_top;
  write_verilog -noattr $FLAT
"

echo "fpga-m1-rtl: wrote $FLAT ($(wc -l < "$FLAT") lines, $(grep -c '^module' "$FLAT") modules)"
echo "  guest path baked into m1.tcl: /work/build/fpga-m1-rtl/parser_m1.v"
echo "  next:  nix run .#fpga-build -- m1"
