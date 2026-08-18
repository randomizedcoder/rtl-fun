# Prove parser_execute's safety invariants with SymbiYosys (Phase 5/6).
#
# Body for the parser-formal writeShellApplication (nix/rtl.nix). parser_execute
# is combinational, so a 1-step bounded proof is exhaustive — the SMT solver
# considers every machine state / micro-op / packet-window / CAM result at once
# and proves the memory-safety + exit-code invariants in verif/formal for ALL of
# them (verif/formal/parser_execute_fp.sv).
#
# yosys' built-in Verilog frontend can't parse our SystemVerilog (packed structs,
# typedef enums, automatic functions), so we flatten to Verilog-2005 with sv2v
# first, then hand the single file to SymbiYosys. Tools (sv2v, sby, yosys, z3)
# come from the wrapper's runtimeInputs. Run from the repo root; work lands in
# build/formal/.

set -euo pipefail

REPO="${REPO:-$PWD}"
RTL="$REPO/rtl"
FORMAL="$REPO/verif/formal"
BUILD="${PARSER_BUILD:-$REPO/build/formal}"

if [ ! -f "$FORMAL/parser_execute.sby" ]; then
  echo "parser-formal: $FORMAL/parser_execute.sby not found — run from the repo root" >&2
  exit 2
fi

mkdir -p "$BUILD"

# ---- proof 1: parser_execute (combinational, 1-step BMC = exhaustive) ----------
# 1. flatten SystemVerilog -> Verilog-2005 (yosys' builtin frontend can't parse
#    our SV; sv2v produces the subset SymbiYosys needs).
sv2v --write="$BUILD/parser_flat.v" \
  "$RTL/parser_pkg.sv" "$RTL/parser_execute.sv" "$FORMAL/parser_execute_fp.sv"

# 2. run the proof from $BUILD (the .sby references parser_flat.v relatively).
cp "$FORMAL/parser_execute.sby" "$BUILD/parser_execute.sby"
( cd "$BUILD" && sby -f parser_execute.sby )

echo "parser-formal: PASS — parser_execute safety invariants proved (see $BUILD/parser_execute)"

# ---- proof 2: cva6_parser_wrap (SEQUENTIAL — the I1/G2 speculation-safety SVAs) -
# cva6_parser_wrap is a clocked state machine, so its safety properties are
# sequential ($past/$stable) and need a multi-cycle proof, not the combinational
# 1-step flow above. This is the I1 formal follow-up: the two G2 invariants
# (a_arch_committed / a_flush_rollback) — and every other embedded wrap SVA —
# proved over ALL inputs by unbounded k-induction (mode prove). --define=FORMAL
# switches the embedded PRS_ASSERTs on; the wrap instantiates only parser_execute
# and elaborates with its default parameters, so no CVA6 packages are needed.
sv2v --define=FORMAL -I"$RTL" --write="$BUILD/parser_wrap_flat.v" \
  "$RTL/parser_pkg.sv" "$RTL/parser_execute.sv" "$RTL/cva6_parser_wrap.sv"

cp "$FORMAL/parser_wrap.sby" "$BUILD/parser_wrap.sby"
( cd "$BUILD" && sby -f parser_wrap.sby )

echo "parser-formal: PASS — cva6_parser_wrap G2 speculation/flush invariants proved (see $BUILD/parser_wrap)"
