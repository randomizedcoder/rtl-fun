# Build + run the cva6_parser_wrap directed testbench (I1 / gap G2).
#
# Body for the parser-wrap-test writeShellApplication (nix/rtl.nix). This verilates
# JUST the CVA6-seam FU (cva6_parser_wrap + parser_execute) with its handshake and
# speculation-safety assertions ON (+define+PARSER_ASSERT) and runs
# rtl/parser_wrap_tb.sv, which proves the commit-visible parser-state mechanism:
# rollback-on-flush, commit advances the architectural shadow, and pending-queue
# backpressure. No CVA6 build, no golden model — a fast, focused unit check.
#
#   nix run .#parser-wrap-test
#
# Tools (verilator, cc, make) come from the wrapper's runtimeInputs. Run from the
# repo root; artifacts land in build/parser-wrap/ (gitignored).

set -euo pipefail

REPO="${REPO:-$PWD}"
RTL="$REPO/rtl"
BUILD="${PARSER_BUILD:-$REPO/build/parser-wrap}"

if [ ! -d "$RTL" ]; then
  echo "parser-wrap-test: $RTL not found — run from the repo root" >&2
  exit 2
fi
mkdir -p "$BUILD"

# cva6_parser_wrap instantiates only parser_execute (the pktbuf/CAM are external
# ports, tied off by the testbench), so the source list is minimal.
srcs=(
  "$RTL/parser_pkg.sv"
  "$RTL/parser_execute.sv"
  "$RTL/cva6_parser_wrap.sv"
  "$RTL/parser_wrap_tb.sv"
)

echo "== verilating cva6_parser_wrap testbench (assertions on) =="
( cd "$BUILD" && rm -rf obj_dir && verilator --binary -O3 -o parser-wrap-test \
    -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET \
    --assert +define+PARSER_ASSERT \
    "-I$RTL" --top-module parser_wrap_tb \
    "${srcs[@]}" )

echo "== running =="
( cd "$BUILD" && ./obj_dir/parser-wrap-test )
