#!/usr/bin/env bash
#
# scripts/parser-negative-control.sh — negative control (gap G11).
#
# The *test* half of the `parser-negative-control` app; the Nix wrapper
# (nix/parser-negative-control.nix) prepends the cva6-baseline.sh build body with
# the STOCK (unpatched) source, so by the time this runs the stock
# Variane_testharness already exists at build/cva6. Preferred entry point:
#
#   nix run .#parser-negative-control
#
# It assembles tests/cva6-parser/negctl.S — a custom-0 PARSER word guarded by a
# trap handler — and runs it on the STOCK model. On the unpatched core the parser
# op is an illegal instruction: it traps, the handler sees mcause=2 and writes
# tohost=1 => fesvr SUCCESS. That SUCCESS is the assertion: the base RV64GC core
# does NOT already accept the parser ops, so cva6-parser-test's PASS is specific to
# the patch (the flip side of docs/analysis/cva6-verification-design.md §2.7 / G11).
#
# Inputs (wrapper-provided; dev-shell fallbacks):
#   CVA6_WORK   build dir holding cva6/work-ver/Variane_testharness (default build/)
#   REPO_ROOT   repo root holding tests/cva6-parser (defaults to $PWD)
#
set -euo pipefail

# Shared helpers (REPO_ROOT/GCC + rv_assemble, run_model). readFile-prepended by
# the Nix wrapper; sourced here when run directly.
if ! declare -F rv_assemble >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
fi

# Anchor on REPO_ROOT, not $PWD: the prepended cva6-baseline.sh build body cd's into
# the build tree, so $PWD has drifted by the time this runs.
WORK="${CVA6_WORK:-$REPO_ROOT/build}"
BIN="$WORK/cva6/work-ver/Variane_testharness"
TESTDIR="$REPO_ROOT/tests/cva6-parser"
OUT="$WORK/negctl"
MAXCYC="${MAX_CYCLES:-100000}"

echo "== CVA6 parser negative control (the STOCK core must reject custom-0) =="
echo "  model : $BIN   (STOCK / unpatched)"
echo "  test  : $TESTDIR/negctl.S"

if [ ! -x "$BIN" ]; then
  echo "ERROR: stock model not found at $BIN" >&2
  echo "       (the Nix wrapper builds it first; in the dev shell run 'nix run .#cva6-baseline')" >&2
  exit 1
fi

mkdir -p "$OUT"
echo "== assembling ELF with $GCC =="
RV_INCLUDES=("$TESTDIR")   # so negctl.S can #include "htif.S"
rv_assemble "$OUT/negctl.elf" "$TESTDIR/link.ld" "$TESTDIR/negctl.S"

echo "== running on the STOCK model (max $MAXCYC cycles) =="
LOG="$OUT/negctl.log"
run_model "$OUT/negctl.elf" "$LOG"
cat "$LOG"

# PASS iff the stock core TRAPPED on the parser op: the handler wrote tohost=1 =>
# fesvr SUCCESS. Any other outcome — the word executed (tohost=3 => FAILED), an
# unexpected trap (tohost=5), or a timeout — is a negative-control failure.
if model_success "$LOG"; then
  echo "== PASS: the stock CVA6 core rejected the custom-0 parser op (illegal-instruction trap) =="
  exit 0
else
  echo "== FAIL: the stock core did NOT reject the parser op as illegal (G11 negative control) ==" >&2
  exit 1
fi
