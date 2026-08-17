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

# Shared helpers (canonical paths, gen_vectors, PARSER_VFLAGS + the suite driver).
# readFile-prepended by the Nix wrapper; sourced here when run directly.
if ! declare -F gen_vectors >/dev/null 2>&1; then
  _lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
  # shellcheck source=/dev/null
  . "$_lib/common.sh"
  # shellcheck source=/dev/null
  . "$_lib/suite.sh"
fi

MODE="${PARSER_MODE:-run}"
BUILD="${PARSER_BUILD:-$REPO_ROOT/build/parser}"

if [ ! -d "$RTL" ]; then
  echo "parser-sim: $RTL not found — run from the repo root" >&2
  exit 2
fi
mkdir -p "$BUILD"

# 1. generate the test vectors from the golden model (--suite emits the whole
#    directed suite under $BUILD/cases/ plus the baseline case in $BUILD).
#    suite + decode both run every directed case (decode also needs enc.hex).
if [ "$MODE" = "suite" ] || [ "$MODE" = "decode" ]; then
  gen_vectors "$BUILD" --suite
else
  gen_vectors "$BUILD"
fi

# 2. source list + Verilator flags (PARSER_VFLAGS = the shared warning/assert set).
srcs=(
  "$RTL/parser_pkg.sv"
  "$RTL/parser_pktbuf.sv"
  "$RTL/parser_cam.sv"
  "$RTL/parser_decode.sv"
  "$RTL/parser_execute.sv"
  "$TB/parser_top.sv"
  "$TB/parser_smoke_tb.sv"
)
common=(
  "${PARSER_VFLAGS[@]}"
  "-I$RTL" "-I$TB" "-I$BUILD"
  --top-module parser_smoke_tb
)

if [ "$MODE" = "lint" ]; then
  verilator --lint-only "${common[@]}" "${srcs[@]}"
  # also lint the CVA6 seam FU (not instantiated in the smoke test): the
  # in-pipeline unit + its handshake assertions must stay elaboration-clean.
  verilator --lint-only \
    "${PARSER_VFLAGS[@]}" \
    "-I$RTL" "-I$TB" "-I$BUILD" --top-module cva6_parser_wrap \
    "$RTL/parser_pkg.sv" "$RTL/parser_execute.sv" "$RTL/cva6_parser_wrap.sv"
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
  decode)
    vflags+=(-O3 +define+PARSER_DECODE) ;;
  run|suite|*)
    vflags+=(-O3) ;;
esac

# 3. verilate (once — the tb reads its per-packet params at runtime)
( cd "$BUILD" && rm -rf obj_dir && verilator "${vflags[@]}" "${common[@]}" "${srcs[@]}" )

# 4. run. suite/decode = every directed case in its own dir; otherwise baseline.
# Per-case work for run_suite: symlink the shared vectors beside the per-case
# packet/expected, run the (single) verilated binary in the case dir, PASS iff it
# exits 0; on FAIL surface the run log (indented) via CASE_TRIAGE.
sim_case() {
  local cdir="$4"
  ln -sf ../../program.hex ../../cam.hex ../../enc.hex "$cdir"/
  if ( cd "$cdir" && "$BUILD/obj_dir/parser-sim" ) > "$cdir/run.log" 2>&1; then
    return 0
  fi
  mapfile -t CASE_TRIAGE < <(sed 's/^/      /' "$cdir/run.log")
  return 1
}

if [ "$MODE" = "suite" ] || [ "$MODE" = "decode" ]; then
  if [ "$MODE" = "decode" ]; then
    title="parser directed suite (decode path: 32-bit words -> parser_decode)"
  else
    title="parser directed suite"
  fi
  if run_suite "$BUILD/cases.txt" "$BUILD/cases" "$title" "parser suite" sim_case; then
    exit 0
  else
    exit 1
  fi
fi

( cd "$BUILD" && ./obj_dir/parser-sim )

if [ "$MODE" = "trace" ] || [ "$MODE" = "debug" ]; then
  echo "parser-sim: waveform at $BUILD/parser.vcd  (view: gtkwave $BUILD/parser.vcd)"
fi
