#!/usr/bin/env bash
#
# scripts/parser-trap-v6.sh — V6 in-core interrupt-mid-parse + resume (gap G7).
#
# The *test* half of the `cva6-parser-trap-v6` app; the Nix wrapper
# (nix/parser-trap-v6.nix) prepends the cva6-baseline.sh build body (PATCHED source
# + CVA6_WORK=build/parser-core), so by the time this runs the patched
# Variane_testharness already exists. Preferred entry point:
#
#   nix run .#cva6-parser-trap-v6
#
# It assembles tests/cva6-parser/parser_trap_v6.S — a CPPRSWR parser write taken
# mid-flight by a CLINT machine *software* interrupt (msip) — and runs it on the
# patched model. The program self-checks (interrupt-run result == clean-run result,
# and the interrupt fired exactly once) and writes tohost=1 on PASS. A green run
# demonstrates the I1 speculation-safety path (flush -> rollback -> re-execute)
# end-to-end through a real asynchronous machine-mode interrupt — the companion to
# V7's synchronous exception (Table C V6, closing gap G7).
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
OUT="$WORK/parser-trap-v6"
MAXCYC="${MAX_CYCLES:-200000}"

echo "== CVA6 parser V6: an async interrupt mid-parse must not corrupt an in-flight parser op =="
echo "  model : $BIN"
echo "  test  : $TESTDIR/parser_trap_v6.S"

if [ ! -x "$BIN" ]; then
  echo "ERROR: patched model not found at $BIN" >&2
  echo "       (the Nix wrapper builds it first; in the dev shell run 'nix run .#cva6-parser')" >&2
  exit 1
fi

mkdir -p "$OUT"
echo "== assembling ELF with $GCC =="
RV_INCLUDES=("$TESTDIR")   # so parser_trap_v6.S can #include "trap.S" / "htif.S"
rv_assemble "$OUT/parser_trap_v6.elf" "$TESTDIR/link.ld" "$TESTDIR/parser_trap_v6.S"

echo "== running on the patched model (max $MAXCYC cycles) =="
LOG="$OUT/parser_trap_v6.log"
run_model "$OUT/parser_trap_v6.elf" "$LOG"
rc=$MODEL_RC
cat "$LOG"

# PASS iff fesvr SUCCESS + rc0: the program only writes tohost=1 when the re-executed
# CPPRSWR committed the SAME value as the interrupt-free run AND the software interrupt
# fired exactly once (a mismatch or wrong trap count writes tohost=6 => FAILED).
if model_success "$LOG" && [ "$rc" -eq 0 ]; then
  echo "== PASS: V6 — the interrupt-squashed parser op re-executed and committed the same result (G7) =="
  exit 0
else
  echo "== FAIL: V6 — an interrupt corrupted the parser op result or it did not fire exactly once (rc=$rc) ==" >&2
  exit 1
fi
