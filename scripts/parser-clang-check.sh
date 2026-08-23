# scripts/parser-clang-check.sh — prove the parser-patched Clang stands up (Phase 7, C0).
#
# Body for the `parser-clang-check` writeShellApplication (nix/parser-clang.nix), which
# puts the parser-aware clang (built against the parser-patched libLLVM) on PATH. This is
# the C0 de-risk: it stands up the from-source Clang build and proves the MC layer is
# actually linked in — BEFORE any __builtin_riscv_prs_* codegen (that lands in C1).
#
# Two proofs, no builtins involved:
#   1. Integrated-as sees the parser MC layer: assemble a spread of prs.* mnemonics through
#      clang's INTEGRATED assembler and require the exact golden words. clang -c routes asm
#      through the (patched) RISCVAsmParser in the libLLVM this clang links, so a correct
#      word proves the parser MC patch reaches clang with no -mattr gate.
#   2. The existing C slice compiles under clang: build tests/cva6-parser/parser_slice.c
#      (unchanged, the .insn intrinsics path) at -O2 and require its 53-word parse_prog to
#      be byte-identical to the golden model ROM (enc.hex) — the same parity guard the Spike
#      slice runner uses, proving the naked/contiguous authoring survives the clang backend.
#
# Run:  nix run .#parser-clang-check     (from the repo root)

set -euo pipefail

ROOT="${REPO_ROOT:-$PWD}"
GENERATED="${GENERATED:-$ROOT/toolchain/generated}"
VEC_SRC="${VEC_SRC:-$ROOT/verif/gen/parser_asm_vectors.c}"
TESTDIR="$ROOT/tests/cva6-parser"
CLANG="${CLANG:-clang}"
OBJDUMP="${OBJDUMP:-riscv64-none-elf-objdump}"
# prs.* live in the default RISCV decoder namespace with NO predicate, so a bare rv64gc
# target assembles them — no parser -march/-mattr feature needed.
CTARGET=(--target=riscv64-unknown-elf -march=rv64gc -mabi=lp64d)

echo "== parser-patched clang =="
command -v "$CLANG"
"$CLANG" --version | sed -n '1p'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- 1. integrated-as sees the parser MC layer -----------------------------
echo "== build the {asmline, word} vector twins (drift-checked generator) =="
cc -std=c11 -O2 -Wall -Wextra -Werror -I "$GENERATED" "$VEC_SRC" -o "$TMP/genvec"
"$TMP/genvec" "$TMP/vec.s" "$TMP/vec.words"
mapfile -t ASM < <(awk '/^\t*prs\./{sub(/^\t/,""); print}' "$TMP/vec.s")
mapfile -t WORD < <(cat "$TMP/vec.words")
N="${#ASM[@]}"
if [ "$N" -eq 0 ] || [ "$N" -ne "${#WORD[@]}" ]; then
  echo "parser-clang-check: vector twins empty or mismatched ($N vs ${#WORD[@]})" >&2
  exit 2
fi

# A spread across the encoding space: first (custom-0 immediate), middle (a custom-3
# move / dest-decorated form), last (a prose-sugar operand form).
echo "== assemble a spread of prs.* through clang's integrated assembler =="
fail=0
for i in 0 "$((N / 2))" "$((N - 1))"; do
  line="${ASM[$i]}"; want="${WORD[$i]}"
  printf '\t%s\n' "$line" | "$CLANG" "${CTARGET[@]}" -c -x assembler - -o "$TMP/one.o"
  got="$("$OBJDUMP" -d "$TMP/one.o" | awk -F'\t' '/:\t/{gsub(/ /,"",$2); print $2; exit}')"
  if [ "$got" = "$want" ]; then
    echo "  ok: $line -> 0x$got"
  else
    echo "  FAIL: $line  clang=0x$got golden=0x$want" >&2
    fail=1
  fi
done
if [ "$fail" -ne 0 ]; then
  echo "parser-clang-check: clang integrated-as did not match the golden words" >&2
  exit 1
fi

# ---- 2. the existing C slice compiles under clang; parse_prog == model ROM --
echo "== generate the golden model ROM (enc.hex) =="
gen_vectors "$TMP" --suite >/dev/null

echo "== compile parser_slice.c with the patched clang (-O2, unchanged .insn path) =="
"$CLANG" "${CTARGET[@]}" -O2 -Wall -Wextra -Werror -nostdlib -ffreestanding \
  -fno-stack-protector \
  -I "$ROOT/toolchain" -I "$ROOT/model" \
  -c "$TESTDIR/parser_slice.c" -o "$TMP/parser_slice.o"

echo "== byte-parity: clang parser_slice.o parse_prog == model enc.hex =="
"$OBJDUMP" --disassemble=parse_prog "$TMP/parser_slice.o" \
  | awk -F'\t' '/^[[:space:]]+[0-9a-f]+:/{gsub(/[[:space:]]/,"",$2); print $2}' \
  | head -n "$(wc -l < "$TMP/enc.hex")" > "$TMP/slice.words"
if ! diff -u "$TMP/enc.hex" "$TMP/slice.words"; then
  echo "parser-clang-check: clang's parser_slice.o does not encode == the model ROM" >&2
  echo "  (left = model enc.hex, right = clang parser_slice.o parse_prog)" >&2
  exit 1
fi
echo "  ok: $(wc -l < "$TMP/enc.hex") slice words == the golden model ROM (compiled by clang)"

echo "parser-clang-check: PASS (clang builds; integrated-as assembles prs.*; slice byte-parity holds)"
