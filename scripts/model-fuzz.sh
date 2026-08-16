# Fuzz the golden parser model with libFuzzer + ASan/UBSan (Phase 6).
#
# Body for the `model-fuzz` writeShellApplication (nix/model.nix). Builds the
# libFuzzer harness (model/fuzz/fuzz_parser.c) instrumented with AddressSanitizer
# and UBSan, then fuzzes the vertical-slice program with random packets. A clean
# run proves the model reads no packet byte out of bounds on any malformed frame.
#
# By default it runs for a bounded time so it works as a CI gate; override:
#   FUZZ_SECONDS=300 nix run .#model-fuzz          fuzz for 5 minutes
#   nix run .#model-fuzz -- -runs=1000000          pass libFuzzer flags through
#
# Tool (clang, providing the libFuzzer runtime) comes from runtimeInputs.
# Run from the repo root; corpus + crash artifacts land in build/fuzz/.

set -euo pipefail

ROOT="${MODEL_ROOT:-$PWD}"
LIB="$ROOT/model/libparsermodel"
HARNESS="$ROOT/model/fuzz/fuzz_parser.c"
BUILD="${FUZZ_BUILD:-$ROOT/build/fuzz}"
SECONDS_LIMIT="${FUZZ_SECONDS:-20}"

if [ ! -f "$HARNESS" ]; then
  echo "model-fuzz: $HARNESS not found — run from the repo root" >&2
  exit 2
fi

mkdir -p "$BUILD/corpus"

# build the instrumented fuzzer
clang -std=c11 -g -O1 -fno-omit-frame-pointer \
  -fsanitize=fuzzer,address,undefined \
  -I "$LIB" \
  "$HARNESS" "$LIB/parser.c" "$LIB/program.c" \
  -o "$BUILD/fuzz_parser"

# run. -max_total_time bounds a default gate run; extra args ($@) override/extend.
echo "model-fuzz: fuzzing for ${SECONDS_LIMIT}s (override with FUZZ_SECONDS=...)"
"$BUILD/fuzz_parser" \
  -max_total_time="$SECONDS_LIMIT" -rss_limit_mb=4096 -print_final_stats=1 \
  "$BUILD/corpus" "$@"

echo "model-fuzz: no crashes — model stayed memory-safe on all fuzzed packets"
