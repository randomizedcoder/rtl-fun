# scripts/parser-clang-moves.sh — prove the Clang custom-3 register-move builtins
# (__builtin_riscv_prs_mv_x_p / mv_p_x / cam_read / array_read) both ENCODE and
# EXECUTE correctly (Phase 7 C3). Body for the `parser-clang-moves` writeShellApplication
# (nix/parser-clang-moves.nix): the parser-patched clang + parser-aware llvm-objdump +
# the standalone parser Spike on PATH.
#
# Two layers (register operands => the emitted word's rd/rs are allocator-chosen, so the
# C1 fixed-golden-word test cannot apply):
#   (a) STRUCTURAL, table-driven off toolchain/generated/parser-clang-moves.tsv: compile one
#       call per (move, p-register) row and assert (emitted_word & mask) == fixed — pinning
#       the opcode/CoP/Func3/S/I/R bits AND that the selected p-register lands in Cpreg[28:24].
#   (b) FUNCTIONAL: compile tests/cva6-parser/parser_moves.c (a builtins-only write->read
#       round-trip: WAW, p11 sign-extend, and a randomized N=256 property loop over p15/p16)
#       and run it on the standalone parser Spike — PASS iff it self-reports tohost=1 (exit 0).
#
# Run:  nix run .#parser-clang-moves     (from the repo root)

set -euo pipefail

# Shared helpers (REPO_ROOT/GCC + rv_assemble); readFile-prepended by the Nix wrapper,
# sourced here when run directly from the dev shell.
if ! declare -F rv_assemble >/dev/null 2>&1; then
  _lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
  # shellcheck source=/dev/null
  . "$_lib/common.sh"
fi

ROOT="${REPO_ROOT:-$PWD}"
DATA="${DATA:-$ROOT/toolchain/generated/parser-clang-moves.tsv}"
TESTDIR="$ROOT/tests/cva6-parser"
CLANG="${CLANG:-clang}"
OBJDUMP="${LLVM_OBJDUMP:-llvm-objdump}"     # parser-aware: decodes prs.* mnemonics
CTARGET=(--target=riscv64-unknown-elf -march=rv64gc -mabi=lp64d)
SPIKE="${SPIKE:-${SPIKE_PARSER:+$SPIKE_PARSER/bin/}spike}"
ISA="${PARSER_SPIKE_ISA:-rv64gc}"

if [ ! -f "$DATA" ]; then
  echo "parser-clang-moves: $DATA not found — run parser-gen-check first" >&2
  exit 2
fi

echo "== parser-patched clang =="
command -v "$CLANG"
"$CLANG" --version | sed -n '1p'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- (a) structural: (emitted_word & mask) == fixed per (move, preg) row ----
# Generate one function per row (in table order). ninputs GPR value args become register-
# forced function params; a read (hasout=1) returns the result. At -O0 each function emits
# exactly one prs.* instruction, in order — the twin of parser-clang-builtins-test.
echo "== (a) structural: table-driven masked-word check (parser-clang-moves.tsv) =="
awk -F'\t' '!/^#/ && NF>=6 {
  id=$1; preg=$2; nin=$3; hasout=$4; n++;
  params=""; args=(preg);
  for (k=0;k<nin;k++){ params=params (k?", ":"") "unsigned long a" k; args=args ", a" k; }
  if (params=="") params="void";
  if (hasout=="1") printf "unsigned long m%d(%s){ return __builtin_riscv_%s(%s); }\n", n, params, id, args;
  else             printf "void m%d(%s){ __builtin_riscv_%s(%s); }\n", n, params, id, args;
}' "$DATA" > "$TMP/moves.c"

awk -F'\t' '!/^#/ && NF>=6 {print $5, $6, $1, $2}' "$DATA" > "$TMP/golden"   # fixed mask id preg
nrows="$(wc -l < "$TMP/golden")"

"$CLANG" "${CTARGET[@]}" -O0 -Wall -Wextra -Werror -c "$TMP/moves.c" -o "$TMP/moves.o"
# The emitted prs.* word is field 2 of each disassembled prs.* line, in definition order.
"$OBJDUMP" -d "$TMP/moves.o" | awk '/[ \t]prs\./ {print $2}' > "$TMP/got.words"
ngot="$(wc -l < "$TMP/got.words")"
if [ "$ngot" -ne "$nrows" ]; then
  echo "parser-clang-moves: emitted $ngot prs.* words, expected $nrows (one per row)" >&2
  exit 1
fi

fail=0; i=0
while read -r fixed mask id preg; do
  i=$((i + 1))
  word="$(sed -n "${i}p" "$TMP/got.words")"
  masked="$(printf '%08x' $(( 0x$word & 0x$mask )))"
  if [ "$masked" = "$fixed" ]; then
    echo "  ok: $id p$preg -> 0x$word  (& 0x$mask == 0x$fixed)"
  else
    echo "  FAIL: $id p$preg -> 0x$word  (& 0x$mask == 0x$masked, want 0x$fixed)" >&2
    fail=1
  fi
done < "$TMP/golden"
[ "$fail" -eq 0 ] || { echo "parser-clang-moves: structural mask check failed" >&2; exit 1; }
echo "  ok: $nrows move encodings pin opcode/CoP/Func3/S/I/R + Cpreg under mask"

# ---- (b) functional: the builtins round-trip runs on the standalone Spike ----
echo "== (b) functional: parser_moves.c (builtins round-trip) on the standalone Spike =="
if ! command -v "$SPIKE" >/dev/null 2>&1; then
  echo "parser-clang-moves: parser spike not found at '$SPIKE'" >&2
  exit 1
fi
# -mcmodel=medany: this ELF links at the DRAM base (0x80000000), out of medlow's
# absolute ±2GB range — the 64-bit constants clang pools (.LCPI) need PC-relative
# addressing or the R_RISCV_HI20 relocation is truncated at link.
"$CLANG" "${CTARGET[@]}" -mcmodel=medany -O2 -Wall -Wextra -Werror -nostdlib -ffreestanding \
  -fno-stack-protector -c "$TESTDIR/parser_moves.c" -o "$TMP/parser_moves.o"
RV_INCLUDES=("$TESTDIR")
rv_assemble "$TMP/moves.elf" "$TESTDIR/link.ld" "$TMP/parser_moves.o" "$TESTDIR/htif.S"

set +e
"$SPIKE" "--isa=$ISA" "$TMP/moves.elf" > "$TMP/moves.log" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "parser-clang-moves: the builtins round-trip did NOT self-report success (rc=$rc)" >&2
  sed 's/^/      /' "$TMP/moves.log" | tail -8 >&2
  exit 1
fi
echo "  ok: p-register write->read round-trip (WAW + p11 sign-extend + 256 random values) == self-check"

echo "parser-clang-moves: PASS (4 register-move builtins: $nrows encodings pinned + functional round-trip on Spike)"
