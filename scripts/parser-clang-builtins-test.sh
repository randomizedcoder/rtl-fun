# scripts/parser-clang-builtins-test.sh — prove Clang's __builtin_riscv_prs_* emit the
# exact parser encodings (Phase 7 C1). Body for the `parser-clang-builtins-test`
# writeShellApplication (nix/parser-clang.nix): the parser-patched clang + the parser-aware
# llvm-objdump on PATH.
#
# The generated table toolchain/generated/parser-clang-builtins.tsv lists every builtin with
# the word it encodes when ALL its immediate operands are zero (== the fixed mnemonic/suffix/
# dest bits). So we compile one all-zero call per builtin through the patched clang, decode the
# object with the parser-aware llvm-objdump, and require each emitted prs.* word to equal its
# golden `match`. A missing/extra/wrong word is a hard failure; the builtin count must not
# regress below the FLOOR. Operand *placement* is exercised end-to-end by parser-clang-slice
# (C2) against the model ROM; here we pin the fixed encoding of every variant.
#
# Run:  nix run .#parser-clang-builtins-test     (from the repo root)

set -euo pipefail

ROOT="${REPO_ROOT:-$PWD}"
DATA="${DATA:-$ROOT/toolchain/generated/parser-clang-builtins.tsv}"
CLANG="${CLANG:-clang}"
OBJDUMP="${LLVM_OBJDUMP:-llvm-objdump}"   # parser-aware: decodes prs.* mnemonics
# prs.* are in the default RISCV decoder namespace (no predicate), so a bare rv64gc target
# assembles/decodes them — no parser -march/-mattr feature.
CTARGET=(--target=riscv64-unknown-elf -march=rv64gc -mabi=lp64d)

if [ ! -f "$DATA" ]; then
  echo "parser-clang-builtins-test: $DATA not found — run parser-gen-check first" >&2
  exit 2
fi

echo "== parser-patched clang =="
command -v "$CLANG"
"$CLANG" --version | sed -n '1p'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# One all-zero call per builtin, in table order (each lowers to a side-effecting inline asm,
# so -O0 preserves order and count). `used` keeps the function; no naked needed — we filter
# the disassembly to prs.* lines, so any prologue/epilogue is ignored.
{
  echo '__attribute__((used)) void all_prs_builtins(void) {'
  awk -F'\t' '!/^#/ && NF>=3 {
    args = "";
    for (k = 0; k < $2; k++) args = args (k ? ", 0" : "0");
    printf "  __builtin_riscv_%s(%s);\n", $1, args;
  }' "$DATA"
  echo '}'
} > "$TMP/all.c"

awk -F'\t' '!/^#/ && NF>=3 {print $3}' "$DATA" > "$TMP/golden.words"
count="$(wc -l < "$TMP/golden.words")"
echo "== $count builtins: compile the all-zero calls through the patched clang =="
"$CLANG" "${CTARGET[@]}" -O0 -Wall -Wextra -Werror -c "$TMP/all.c" -o "$TMP/all.o"

echo "== decode emitted prs.* words (parser-aware llvm-objdump) and compare to golden =="
# llvm-objdump line for a decoded parser op:  "   <addr>: <word>\tprs.<mnemonic>\t<ops>"
# — take the hex word (field 2) from every line that disassembles to a prs.* mnemonic.
"$OBJDUMP" -d "$TMP/all.o" | awk '/[ \t]prs\./ {print $2}' > "$TMP/got.words"

if ! diff -u "$TMP/golden.words" "$TMP/got.words"; then
  echo "parser-clang-builtins-test: emitted words != golden (match) words" >&2
  echo "  (left = generated golden, right = clang-emitted via llvm-objdump)" >&2
  exit 1
fi

got="$(wc -l < "$TMP/got.words")"
FLOOR="${CLANG_BUILTINS_FLOOR:-67}"
if [ "$got" -lt "$FLOOR" ]; then
  echo "parser-clang-builtins-test: only $got builtins emitted, expected >= $FLOOR (regression?)" >&2
  exit 1
fi

echo "parser-clang-builtins-test: PASS ($got builtins compile + emit the exact golden encodings)"
