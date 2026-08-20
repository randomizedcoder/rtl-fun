# Phase 7 L2 (§7.3): prove the patched binutils assembles + disassembles the parser
# mnemonics correctly. Body for the `parser-asm-test` writeShellApplication
# (nix/parser-asm-test.nix), which puts the parser-patched riscv64-none-elf binutils
# (nix/parser-binutils.nix) on PATH ahead of the stock one.
#
# One vector table (verif/gen/parser_asm_vectors.c) emits BOTH a `.s` of every
# mnemonic and its expected word (from the generated, drift-checked intrinsics). We
# then: (1) assemble the `.s` with the patched `as` and check each objdump word equals
# the expected word — gas == generator == model; (2) check `objdump -d` renders every
# mnemonic (readable disassembly, the L2 exit clause). No `.insn`/`.word` blobs.
#
# Run:  nix run .#parser-asm-test     (from the repo root)

set -euo pipefail

ROOT="${REPO_ROOT:-$PWD}"
VEC_SRC="${VEC_SRC:-$ROOT/verif/gen/parser_asm_vectors.c}"
GENERATED="${GENERATED:-$ROOT/toolchain/generated}"
CC="${CC:-cc}"
PFX="${CV_SW_PREFIX:-riscv64-none-elf-}"
AS="${PFX}as"
OBJDUMP="${PFX}objdump"

if [ ! -f "$VEC_SRC" ]; then
  echo "parser-asm-test: $VEC_SRC not found — run from the repo root" >&2
  exit 2
fi

echo "== using assembler: $(command -v "$AS")"
"$AS" --version | head -1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== generate test.s + expected words from the vector table =="
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -I "$GENERATED" "$VEC_SRC" -o "$TMP/genvec"
"$TMP/genvec" "$TMP/test.s" "$TMP/expected.words"

echo "== assemble with the parser-patched binutils =="
"$AS" -march=rv64gc -o "$TMP/test.o" "$TMP/test.s"

echo "== check every assembled word == the generated/model golden =="
"$OBJDUMP" -d "$TMP/test.o" \
  | awk -F'\t' '/^[[:space:]]+[0-9a-f]+:/{gsub(/[[:space:]]/,"",$2); print $2}' \
  > "$TMP/actual.words"

if ! diff -u "$TMP/expected.words" "$TMP/actual.words"; then
  echo "parser-asm-test: assembled words differ from the generated goldens" >&2
  echo "  (left = intrinsic/model expectation, right = patched-as output)" >&2
  exit 1
fi
n=$(wc -l < "$TMP/expected.words")
echo "  ok: $n mnemonics assembled to the exact golden encodings"

echo "== check objdump renders every mnemonic (readable disassembly) =="
disasm="$("$OBJDUMP" -d "$TMP/test.o")"
missing=0
# The mnemonic is the first token of each instruction line in the generated .s.
while read -r mn; do
  [ -n "$mn" ] || continue
  if ! printf '%s\n' "$disasm" | grep -qE "[[:space:]]${mn//./\\.}([[:space:]]|$)"; then
    echo "  MISSING in disassembly: $mn" >&2
    missing=$((missing + 1))
  fi
done < <(awk '/^\t*prs\./{print $1}' "$TMP/test.s")

if [ "$missing" -ne 0 ]; then
  echo "parser-asm-test: $missing mnemonic(s) did not disassemble to a readable form" >&2
  exit 1
fi
echo "  ok: objdump disassembles all parser mnemonics"

echo "== round-trip: reassemble objdump's disassembly, expect identical words =="
# objdump prints the readable form (prose sugar where it exists). Feed that text
# straight back into the assembler and require the SAME encodings — proving the
# disassembly is itself valid assembly (the Stage-1.5 exit clause). Fields (tab
# separated): $3 = mnemonic, $4 = operands (absent for prs.stp).
{
  printf '\t.text\n\t.globl _start\n_start:\n'
  "$OBJDUMP" -d "$TMP/test.o" \
    | awk -F'\t' '/^[[:space:]]+[0-9a-f]+:/{
        op = $4; sub(/[[:space:]]*#.*$/, "", op);
        if (op == "") print "\t" $3; else print "\t" $3 " " op }'
} > "$TMP/reasm.s"

"$AS" -march=rv64gc -o "$TMP/reasm.o" "$TMP/reasm.s"
"$OBJDUMP" -d "$TMP/reasm.o" \
  | awk -F'\t' '/^[[:space:]]+[0-9a-f]+:/{gsub(/[[:space:]]/,"",$2); print $2}' \
  > "$TMP/reasm.words"

if ! diff -u "$TMP/actual.words" "$TMP/reasm.words"; then
  echo "parser-asm-test: objdump disassembly did not reassemble to the same words" >&2
  echo "  (left = first assembly, right = reassembled disassembly)" >&2
  exit 1
fi
echo "  ok: disassembly reassembles to identical encodings (assemble->disasm->assemble)"

echo "parser-asm-test: PASS"
