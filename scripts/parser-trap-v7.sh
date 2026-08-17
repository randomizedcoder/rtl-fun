#!/usr/bin/env bash
#
# scripts/parser-trap-v7.sh — V7 in-core faulting-instruction squash (gap G7).
#
# The *test* half of the `cva6-parser-trap-v7` app; the Nix wrapper
# (nix/parser-trap-v7.nix) prepends the cva6-baseline.sh build body (PATCHED source
# + CVA6_WORK=build/parser-core), so by the time this runs the patched
# Variane_testharness already exists. Preferred entry point:
#
#   nix run .#cva6-parser-trap-v7
#
# It assembles tests/cva6-parser/parser_trap_v7.S — a CPPRSWR parser write preceded
# by an `ecall` that flushes it in flight — and runs it on the patched model. The
# program self-checks (fault-run result == clean-run result, and the fault fired
# once) and writes tohost=1 on PASS. A green run demonstrates the I1 speculation-
# safety path (flush -> rollback -> re-execute) end-to-end through a real machine-mode
# exception (Table C V7, part of gap G7).
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
OUT="$WORK/parser-trap-v7"
MAXCYC="${MAX_CYCLES:-200000}"

echo "== CVA6 parser V7: a faulting instruction must not corrupt an in-flight parser op =="
echo "  model : $BIN"
echo "  test  : $TESTDIR/parser_trap_v7.S"

if [ ! -x "$BIN" ]; then
  echo "ERROR: patched model not found at $BIN" >&2
  echo "       (the Nix wrapper builds it first; in the dev shell run 'nix run .#cva6-parser')" >&2
  exit 1
fi

mkdir -p "$OUT"
echo "== assembling ELF with $GCC =="
RV_INCLUDES=("$TESTDIR")   # so parser_trap_v7.S can #include "trap.S" / "htif.S"
rv_assemble "$OUT/parser_trap_v7.elf" "$TESTDIR/link.ld" "$TESTDIR/parser_trap_v7.S"

echo "== running on the patched model (max $MAXCYC cycles) =="
LOG="$OUT/parser_trap_v7.log"
run_model "$OUT/parser_trap_v7.elf" "$LOG"
rc=$MODEL_RC
cat "$LOG"

# PASS iff fesvr SUCCESS + rc0: the program only writes tohost=1 when the re-executed
# CPPRSWR committed the SAME value as the fault-free run AND the ecall trapped exactly
# once (a mismatch or wrong trap count writes tohost=7 => FAILED).
if model_success "$LOG" && [ "$rc" -eq 0 ]; then
  echo "== PASS: V7 — the ecall-squashed parser op re-executed and committed the same result (G7) =="
  exit 0
else
  echo "== FAIL: V7 — a faulting instruction corrupted the parser op result or the fault did not fire (rc=$rc) ==" >&2
  exit 1
fi
