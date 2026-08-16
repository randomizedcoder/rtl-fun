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

# 1. generate the test vectors from the golden model (--suite emits the whole
#    directed suite under $BUILD/cases/ plus the baseline case in $BUILD).
cc -std=c11 -O2 -Wall -Wextra -I "$MODEL" \
  "$RTL/gen/gen_parser_rom.c" "$MODEL/parser.c" "$MODEL/program.c" "$MODEL/encoding.c" \
  -o "$BUILD/gen_parser_rom"
# suite + decode both run every directed case; decode also needs enc.hex per case.
if [ "$MODE" = "suite" ] || [ "$MODE" = "decode" ]; then
  "$BUILD/gen_parser_rom" "$BUILD" --suite
else
  "$BUILD/gen_parser_rom" "$BUILD"
fi

# 2. source list + common Verilator flags (bug-indicating lints stay fatal;
#    UNUSEDPARAM/UNUSEDSIGNAL are waived: the package defines the full ISA
#    vocabulary and datapath temporaries are intentionally wider than one use).
srcs=(
  "$RTL/parser_pkg.sv"
  "$RTL/parser_pktbuf.sv"
  "$RTL/parser_cam.sv"
  "$RTL/parser_decode.sv"
  "$RTL/parser_execute.sv"
  "$RTL/parser_top.sv"
  "$RTL/parser_smoke_tb.sv"
)
common=(
  -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET
  --assert +define+PARSER_ASSERT
  "-I$RTL" "-I$BUILD"
  --top-module parser_smoke_tb
)

if [ "$MODE" = "lint" ]; then
  verilator --lint-only "${common[@]}" "${srcs[@]}"
  # also lint the CVA6 seam FU (not instantiated in the smoke test): the
  # in-pipeline unit + its handshake assertions must stay elaboration-clean.
  verilator --lint-only \
    -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET --assert +define+PARSER_ASSERT \
    "-I$RTL" "-I$BUILD" --top-module cva6_parser_wrap \
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
if [ "$MODE" = "suite" ] || [ "$MODE" = "decode" ]; then
  echo "=================================================="
  if [ "$MODE" = "decode" ]; then
    echo "parser directed suite (decode path: 32-bit words -> parser_decode)"
  else
    echo "parser directed suite"
  fi
  echo "=================================================="
  fails=0
  ncase=0
  # manifest fields: name category expect_ok exp_code len
  # (expect_ok/len only used by gen's self-check; the runner needs name/cat/code)
  while read -r name category _expect_ok exp_code _len; do
    ncase=$((ncase + 1))
    cdir="$BUILD/cases/$name"
    # program + CAM (+enc for decode mode) are shared; link them beside vectors.
    ln -sf ../../program.hex ../../cam.hex ../../enc.hex "$cdir"/
    if ( cd "$cdir" && "$BUILD/obj_dir/parser-sim" ) > "$cdir/run.log" 2>&1; then
      result="PASS"
    else
      result="FAIL"
      fails=$((fails + 1))
    fi
    printf '  %-22s %-9s exp_code=%-4s  %s\n' "$name" "$category" "$exp_code" "$result"
    [ "$result" = "FAIL" ] && sed 's/^/      /' "$cdir/run.log"
  done < "$BUILD/cases.txt"
  echo "--------------------------------------------------"
  echo "parser suite: $ncase cases, $fails failures"
  echo "=================================================="
  [ "$fails" -eq 0 ] || exit 1
  exit 0
fi

( cd "$BUILD" && ./obj_dir/parser-sim )

if [ "$MODE" = "trace" ] || [ "$MODE" = "debug" ]; then
  echo "parser-sim: waveform at $BUILD/parser.vcd  (view: gtkwave $BUILD/parser.vcd)"
fi
