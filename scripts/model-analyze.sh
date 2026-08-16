# Static analysis + sanitizer run for the golden C model (Phase 5/6).
#
# Body for the `model-analyze` writeShellApplication (nix/model.nix). Runs three
# independent static analysers over libparsermodel + the RTL vector generator,
# then rebuilds the test suite under AddressSanitizer + UBSan and runs it so any
# out-of-bounds / UB the analysers can't see statically is caught dynamically:
#
#   1. cppcheck        (--error-exitcode: warnings fail the build)
#   2. gcc -fanalyzer  (-Werror: the GCC static analyzer, compile-only)
#   3. clang-tidy      (bugprone + clang-analyzer, warnings-as-errors)
#   4. ASan/UBSan run  (model-test over the pinned corpus)
#
# Tools (cppcheck, gcc, clang-tidy) come from the wrapper's runtimeInputs.
# CORPUS_DIR is injected by the Nix wrapper. Run from the repo root.

set -euo pipefail

ROOT="${MODEL_ROOT:-$PWD}"
SRC="$ROOT/model"
LIB="$SRC/libparsermodel"
GEN="$ROOT/rtl/gen/gen_parser_rom.c"

if [ ! -d "$LIB" ]; then
  echo "model-analyze: $LIB not found — run from the repo root" >&2
  exit 2
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

csrcs=(
  "$LIB/parser.c" "$LIB/program.c" "$LIB/pcap.c" "$LIB/encoding.c"
  "$SRC/test/test_main.c" "$GEN"
)

echo "== 1/4 cppcheck =="
cppcheck --std=c11 --enable=warning,performance,portability \
  --inline-suppr --error-exitcode=1 \
  --suppress=missingIncludeSystem --suppress=checkersReport \
  -I "$LIB" "${csrcs[@]}"

echo "== 2/4 gcc -fanalyzer =="
for f in "${csrcs[@]}"; do
  gcc -std=c11 -fanalyzer -Wall -Wextra -Werror -I "$LIB" -c "$f" -o /dev/null
done

echo "== 3/4 clang-tidy =="
# bugprone-* + the clang static analyzer, warnings-as-errors. Two checks are
# waived as noise, not bugs: easily-swappable-parameters (flags any adjacent
# same-type args — an API-style opinion) and implicit-widening (pedantic on test
# packet builders). insecureAPI.* is off (freestanding-style model code).
clang-tidy --quiet \
  --warnings-as-errors='*' \
  --checks='-*,bugprone-*,clang-analyzer-*,-bugprone-easily-swappable-parameters,-bugprone-implicit-widening-of-multiplication-result,-clang-analyzer-security.insecureAPI.*' \
  "${csrcs[@]}" -- -std=c11 -I "$LIB"

echo "== 4/4 ASan + UBSan test run =="
cc -std=c11 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
  -Wall -Wextra -Werror -I "$LIB" \
  "$SRC/test/test_main.c" "$LIB/parser.c" "$LIB/program.c" "$LIB/pcap.c" "$LIB/encoding.c" \
  -o "$OUT/pm-test-san"
echo "CORPUS_DIR=${CORPUS_DIR:-<unset>}"
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$OUT/pm-test-san"

echo "model-analyze: all analysers + sanitizer run clean"
