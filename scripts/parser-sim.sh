# Build + run the parser-unit Verilator smoke test (Phase 5).
#
# Body for the parser-sim* writeShellApplications (nix/rtl.nix). The RTL parser
# unit runs the SAME decoded program the golden C model runs; gen_parser_rom.c
# emits the program/CAM/packet/expected vectors from the model (single source of
# truth), then Verilator builds and runs the testbench, which asserts the RTL
# flow_keys equals the model's byte-for-byte.
#
# Debug level is chosen by PARSER_MODE (set by each wrapper):
#   run    optimized (-O3), run the smoke test         (nix run .#parser-sim)
#   trace  + FST waveform (--trace-fst --trace-structs)(nix run .#parser-sim-trace)
#   debug  -O0 -ggdb + waveform, for gdb               (nix run .#parser-sim-debug)
#   lint   --lint-only -Wall, no build                 (nix run .#parser-lint)
#
# Tools (verilator, cc) come from the wrapper's runtimeInputs. Run from the repo
# root; artifacts land in build/parser/ (gitignored).

set -euo pipefail

REPO="${REPO:-$PWD}"
RTL="$REPO/rtl"
MODEL="$REPO/model/libparsermodel"
MODE="${PARSER_MODE:-run}"
BUILD="${PARSER_BUILD:-$REPO/build/parser}"

if [ ! -d "$RTL" ]; then
  echo "parser-sim: $RTL not found — run from the repo root" >&2
  exit 2
fi
mkdir -p "$BUILD"

# 1. generate the test vectors from the golden model
cc -std=c11 -O2 -Wall -Wextra -I "$MODEL" \
  "$RTL/gen/gen_parser_rom.c" "$MODEL/parser.c" "$MODEL/program.c" \
  -o "$BUILD/gen_parser_rom"
"$BUILD/gen_parser_rom" "$BUILD"

# 2. source list + common Verilator flags (bug-indicating lints stay fatal;
#    UNUSEDPARAM/UNUSEDSIGNAL are waived: the package defines the full ISA
#    vocabulary and datapath temporaries are intentionally wider than one use).
srcs=(
  "$RTL/parser_pkg.sv"
  "$RTL/parser_pktbuf.sv"
  "$RTL/parser_cam.sv"
  "$RTL/parser_execute.sv"
  "$RTL/parser_top.sv"
  "$RTL/parser_smoke_tb.sv"
)
common=(
  -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM
  --assert
  "-I$RTL" "-I$BUILD"
  --top-module parser_smoke_tb
)

if [ "$MODE" = "lint" ]; then
  verilator --lint-only "${common[@]}" "${srcs[@]}"
  echo "parser-sim: lint clean (-Wall, bug-class lints fatal)"
  exit 0
fi

# VCD waveforms (no lz4 dependency, unlike --trace-fst); --trace-structs shows
# packed pstate_t / micro_op_t fields by name.
vflags=(--binary -o parser-sim)
case "$MODE" in
  trace)
    vflags+=(-O3 --trace --trace-structs +define+DUMP) ;;
  debug)
    vflags+=(-O0 -CFLAGS -O0 -CFLAGS -ggdb --trace --trace-structs +define+DUMP) ;;
  run|*)
    vflags+=(-O3) ;;
esac

# 3. verilate + run
( cd "$BUILD" && rm -rf obj_dir && verilator "${vflags[@]}" "${common[@]}" "${srcs[@]}" )
( cd "$BUILD" && ./obj_dir/parser-sim )

if [ "$MODE" = "trace" ] || [ "$MODE" = "debug" ]; then
  echo "parser-sim: waveform at $BUILD/parser.vcd  (view: gtkwave $BUILD/parser.vcd)"
fi
