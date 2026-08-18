#!/usr/bin/env bash
#
# scripts/parser-ctxsw-v10.sh — V10 in-core between-parse context switch of the parser
# register state (Table C V10, gap G7 / §3.1 item 4; ratifies D7).
#
# The *test* half of the `cva6-parser-ctxsw-v10` app; the Nix wrapper
# (nix/parser-ctxsw-v10.nix) prepends the cva6-baseline.sh build body (PATCHED source
# + CVA6_WORK=build/parser-core), so by the time this runs the patched
# Variane_testharness already exists. Preferred entry point:
#
#   nix run .#cva6-parser-ctxsw-v10
#
# It assembles tests/cva6-parser/parser_ctxsw_v10.S — spill/clobber/reload of the five
# writable parser registers {p11,p13,p14,p15,p16} via the custom-3 move ABI (CPPRSRD /
# CPPRSWR) across a simulated context switch — and runs it on the patched model. The
# program self-checks (each reg was truly clobbered, then restored bit-for-bit) and
# writes tohost=1 on PASS. A green run ratifies D7: the custom-3 move ABI round-trips a
# parser thread's live register context through memory, in-core, over the real pipeline.
#
# Inputs (wrapper-provided; dev-shell fallbacks):
#   CVA6_WORK   build dir holding cva6/work-ver/Variane_testharness (build/parser-core)
#   REPO_ROOT   repo root holding tests/cva6-parser (defaults to $PWD)
#
set -euo pipefail

# Shared helpers (rv_assemble, run_model, model_success). readFile-prepended by the
# Nix wrapper; sourced here when run directly in the dev shell.
if ! declare -F rv_assemble >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
fi

WORK="${CVA6_WORK:-$PWD/build/parser-core}"
BIN="$WORK/cva6/work-ver/Variane_testharness"
TESTDIR="$REPO_ROOT/tests/cva6-parser"
OUT="$WORK/parser-ctxsw-v10"
MAXCYC="${MAX_CYCLES:-200000}"

echo "== CVA6 parser V10: a between-parse context switch must round-trip the parser register state =="
echo "  model : $BIN"
echo "  test  : $TESTDIR/parser_ctxsw_v10.S"

if [ ! -x "$BIN" ]; then
  echo "ERROR: patched model not found at $BIN" >&2
  echo "       (the Nix wrapper builds it first; in the dev shell run 'nix run .#cva6-parser')" >&2
  exit 1
fi

mkdir -p "$OUT"
echo "== assembling ELF with $GCC =="
RV_INCLUDES=("$TESTDIR")   # so parser_ctxsw_v10.S can #include "htif.S"
rv_assemble "$OUT/parser_ctxsw_v10.elf" "$TESTDIR/link.ld" "$TESTDIR/parser_ctxsw_v10.S"

echo "== running on the patched model (max $MAXCYC cycles) =="
LOG="$OUT/parser_ctxsw_v10.log"
run_model "$OUT/parser_ctxsw_v10.elf" "$LOG"
rc=$MODEL_RC
cat "$LOG"

# PASS iff fesvr SUCCESS + rc0: the program only writes tohost=1 when EVERY writable
# p-reg was truly clobbered by the "other thread" AND restored bit-for-bit from the
# spilled context (a stuck/ignored write => tohost=11; a lossy restore => tohost=10).
if model_success "$LOG" && [ "$rc" -eq 0 ]; then
  echo "== PASS: V10 — the parser register context round-tripped through the custom-3 move ABI (D7) =="
  exit 0
else
  echo "== FAIL: V10 — a parser register was not clobbered or not restored bit-exact (rc=$rc) ==" >&2
  exit 1
fi
