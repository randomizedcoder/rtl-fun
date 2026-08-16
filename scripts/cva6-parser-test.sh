#!/usr/bin/env bash
#
# scripts/cva6-parser-test.sh — in-core directed test for the PARSER FU.
#
# This is the *test* half of the `cva6-parser-test` app; the Nix wrapper
# (nix/cva6-parser-test.nix) prepends the cva6-baseline.sh build body (with the
# PATCHED source + CVA6_WORK=build/parser-core), so by the time this runs the
# patched Variane_testharness already exists. Preferred entry point:
#
#   nix run .#cva6-parser-test
#
# It assembles tests/cva6-parser/parser_insn.S (custom-0 PARSER ops + a fesvr
# tohost PASS handshake) into an ELF and runs it on the patched model. A green run
# proves the whole in-core chain: fetch -> decode (fu=PARSER) -> issue handshake
# -> EX (cva6_parser_wrap) -> writeback/retire -> pipeline advances. On the stock
# core the same custom-0 words hit the illegal-instruction fallback and trap, so a
# PASS here is specific to the patch. (docs/analysis/cva6-integration.md §3–§8.)
#
# Inputs (wrapper-provided; dev-shell fallbacks):
#   CVA6_WORK   build dir holding cva6/work-ver/Variane_testharness (build/parser-core)
#   REPO_ROOT   repo root holding tests/cva6-parser (defaults to $PWD)
# Toolchain (riscv64-none-elf-*) + the model are on PATH / built by the wrapper.
#
set -euo pipefail

WORK="${CVA6_WORK:-$PWD/build/parser-core}"
ROOT="${REPO_ROOT:-$PWD}"
BIN="$WORK/cva6/work-ver/Variane_testharness"
TESTDIR="$ROOT/tests/cva6-parser"
OUT="$WORK/parser-test"
MAXCYC="${MAX_CYCLES:-200000}"

echo "== CVA6 parser in-core test =="
echo "  model : $BIN"
echo "  test  : $TESTDIR/parser_insn.S"

if [ ! -x "$BIN" ]; then
  echo "ERROR: patched model not found at $BIN" >&2
  echo "       (the Nix wrapper builds it first; in the dev shell run 'nix run .#cva6-parser')" >&2
  exit 1
fi

mkdir -p "$OUT"
GCC="${CV_SW_PREFIX:-riscv64-none-elf-}gcc"
echo "== assembling ELF with $GCC =="
"$GCC" -march=rv64gc -mabi=lp64d -nostdlib -nostartfiles \
  -T "$TESTDIR/link.ld" "$TESTDIR/parser_insn.S" -o "$OUT/parser_insn.elf"

echo "== running on the patched model (max $MAXCYC cycles) =="
LOG="$OUT/parser_insn.log"
# The harness returns nonzero on tohost failure; +max-cycles bounds a hang.
set +e
"$BIN" "$OUT/parser_insn.elf" "+max-cycles=$MAXCYC" >"$LOG" 2>&1
rc=$?
set -e
cat "$LOG"

if grep -q "\*\*\* SUCCESS \*\*\*" "$LOG" && [ "$rc" -eq 0 ]; then
  echo "== PASS: custom-0 PARSER ops executed and retired in-core =="
  exit 0
else
  echo "== FAIL: model did not report SUCCESS (rc=$rc) ==" >&2
  exit 1
fi
