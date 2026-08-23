# Phase 7 L3 (§7.4): prove the parser-patched LLVM MC layer (llvm-mc / llvm-objdump)
# assembles + disassembles the parser mnemonics to the exact isa/parser-opcodes.yaml
# bits — the LLVM twin of parser-asm-test (binutils, L2). Body for the
# `parser-llvm-mc-test` writeShellApplication (nix/parser-llvm-mc-test.nix), which puts
# the parser-patched llvm (nix/parser-llvm.nix) on PATH.
#
# The SAME vector table (verif/gen/parser_asm_vectors.c) drives both legs: it emits a
# `.s` of every mnemonic plus each expected word (from the generated, drift-checked
# intrinsics). L1 of the LLVM leg covers the immediate-only custom-0 ops (the ones whose
# TableGen needs no custom operand class — see toolchain/generated/parser-llvm.td); the
# p-register / destination-decoration / prose forms are a later L increment. So we
# CLASSIFY each vector line: llvm-mc either assembles it (then its word MUST equal the
# golden) or rejects it as not-yet-supported (counted + listed as DEFERRED, never
# silently dropped). A supported line whose word differs is a hard failure.
#
# Run:  nix run .#parser-llvm-mc-test     (from the repo root)

set -euo pipefail

ROOT="${REPO_ROOT:-$PWD}"
VEC_SRC="${VEC_SRC:-$ROOT/verif/gen/parser_asm_vectors.c}"
GENERATED="${GENERATED:-$ROOT/toolchain/generated}"
CC="${CC:-cc}"
MC="${LLVM_MC:-llvm-mc}"
OBJDUMP="${LLVM_OBJDUMP:-llvm-objdump}"
TRIPLE="riscv64"

# L1 covers the immediate-only ops; this many vector LINES are expected to assemble.
# A regression that drops support below this floor fails the test; the exact deferred
# set is always printed. Bump when a later L increment adds operand classes.
FLOOR="${LLVM_MC_SUPPORTED_FLOOR:-10}"

if [ ! -f "$VEC_SRC" ]; then
  echo "parser-llvm-mc-test: $VEC_SRC not found — run from the repo root" >&2
  exit 2
fi

echo "== using assembler: $(command -v "$MC")"
"$MC" --version | sed -n '2p'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== generate test.s + expected words from the vector table =="
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -I "$GENERATED" "$VEC_SRC" -o "$TMP/genvec"
"$TMP/genvec" "$TMP/test.s" "$TMP/expected.words"

# The instruction lines of test.s (leading tab stripped) correspond 1:1, in order, with
# the words in expected.words (genvec writes both in the same loop).
mapfile -t ASM < <(awk '/^\t*prs\./{sub(/^\t/,""); print}' "$TMP/test.s")
mapfile -t WORD < <(cat "$TMP/expected.words")
if [ "${#ASM[@]}" -ne "${#WORD[@]}" ]; then
  echo "parser-llvm-mc-test: asm/word count mismatch (${#ASM[@]} vs ${#WORD[@]})" >&2
  exit 2
fi

echo "== classify + word-check each vector line via llvm-mc --show-encoding =="
supported=0; deferred=0; mism=0
: > "$TMP/supported.s"
printf '\t.text\n\t.globl _start\n_start:\n' > "$TMP/supported.s"
for i in "${!ASM[@]}"; do
  line="${ASM[$i]}"; want="${WORD[$i]}"
  enc="$(printf '%s\n' "$line" | "$MC" --triple="$TRIPLE" --show-encoding 2>/dev/null \
         | grep -oE '\[0x[0-9a-fx,]*\]' | head -1 || true)"
  if [ -z "$enc" ]; then
    echo "  DEFERRED (llvm-mc rejects): $line"
    deferred=$((deferred + 1))
    continue
  fi
  got="$(printf '%s' "$enc" | tr -d '[]' \
         | awk -F, '{printf "%02x%02x%02x%02x", strtonum($4),strtonum($3),strtonum($2),strtonum($1)}')"
  if [ "$got" != "$want" ]; then
    echo "  MISMATCH: $line  llvm-mc=0x$got golden=0x$want" >&2
    mism=$((mism + 1))
  else
    supported=$((supported + 1))
    printf '\t%s\n' "$line" >> "$TMP/supported.s"
  fi
done

echo "  supported=$supported  deferred=$deferred  mismatch=$mism"
if [ "$mism" -ne 0 ]; then
  echo "parser-llvm-mc-test: $mism supported line(s) assembled to the wrong word" >&2
  exit 1
fi
if [ "$supported" -lt "$FLOOR" ]; then
  echo "parser-llvm-mc-test: only $supported lines supported, expected >= $FLOOR (regression?)" >&2
  exit 1
fi
echo "  ok: all $supported supported lines assemble to the exact golden encodings"

echo "== round-trip: reassemble llvm-objdump's disassembly, expect identical words =="
"$MC" --triple="$TRIPLE" --filetype=obj -o "$TMP/supported.o" "$TMP/supported.s"
"$OBJDUMP" -d "$TMP/supported.o" \
  | awk '/^[[:space:]]+[0-9a-f]+:/{print $2}' > "$TMP/asm.words"
# Rebuild a .s from the disassembly text (col after the encoding word is the mnemonic +
# operands) and reassemble; require the identical encodings (assemble->disasm->assemble).
{
  printf '\t.text\n\t.globl _start\n_start:\n'
  "$OBJDUMP" -d "$TMP/supported.o" \
    | awk '/^[[:space:]]+[0-9a-f]+:/{ $1=""; $2=""; sub(/^[[:space:]]+/,""); print "\t" $0 }'
} > "$TMP/reasm.s"
"$MC" --triple="$TRIPLE" --filetype=obj -o "$TMP/reasm.o" "$TMP/reasm.s"
"$OBJDUMP" -d "$TMP/reasm.o" \
  | awk '/^[[:space:]]+[0-9a-f]+:/{print $2}' > "$TMP/reasm.words"

if ! diff -u "$TMP/asm.words" "$TMP/reasm.words"; then
  echo "parser-llvm-mc-test: llvm-objdump disassembly did not reassemble to the same words" >&2
  exit 1
fi
echo "  ok: disassembly reassembles to identical encodings (assemble->disasm->assemble)"

echo "parser-llvm-mc-test: PASS ($supported mnemonics; $deferred deferred to a later L increment)"
