#!/usr/bin/env bash
#
# scripts/parser-baseisa.sh — base-ISA regression on the PATCHED core (gap G11, N6).
#
# The *test* half of the `cva6-parser-baseisa` app; the Nix wrapper
# (nix/parser-baseisa.nix) prepends the cva6-baseline.sh build body (PATCHED source
# + CVA6_WORK=build/parser-core), so by the time this runs the patched
# Variane_testharness already exists. Preferred entry point:
#
#   nix run .#cva6-parser-baseisa
#
# It assembles tests/cva6-parser/base_isa.S — a directed representative slice of
# RV64GC (integer incl. *w, M, A, F/D, CSR, every branch flavour, JAL/JALR), each
# result value-checked — and runs it on the PATCHED model. Every FU writes back
# through the same commit/writeback ports the parser patch touches, so a green run is
# direct evidence the extension is behaviorally transparent to the base ISA. The
# companion to the negative control (N1): N1 proves the stock core REJECTS the parser
# ops; this proves the patched core still ACCEPTS the whole base ISA.
#
# (Directed representative regression; the full upstream riscv-tests suite is the
# heavier deferred complement — verification-design §3.1 item 7.)
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
OUT="$WORK/parser-baseisa"
MAXCYC="${MAX_CYCLES:-200000}"

echo "== CVA6 base-ISA regression: RV64GC must still retire correctly on the PATCHED core =="
echo "  model : $BIN"
echo "  test  : $TESTDIR/base_isa.S"

if [ ! -x "$BIN" ]; then
  echo "ERROR: patched model not found at $BIN" >&2
  echo "       (the Nix wrapper builds it first; in the dev shell run 'nix run .#cva6-parser')" >&2
  exit 1
fi

mkdir -p "$OUT"
echo "== assembling ELF with $GCC =="
RV_INCLUDES=("$TESTDIR")   # so base_isa.S can #include "htif.S"
rv_assemble "$OUT/base_isa.elf" "$TESTDIR/link.ld" "$TESTDIR/base_isa.S"

echo "== running on the patched model (max $MAXCYC cycles) =="
LOG="$OUT/base_isa.log"
run_model "$OUT/base_isa.elf" "$LOG"
rc=$MODEL_RC
cat "$LOG"

# PASS iff fesvr SUCCESS + rc0: the program writes tohost=1 only after every base-ISA
# check value-matched. A mismatch writes tohost=(failing_id<<1)|1 (exit code == the
# failing test id); an unexpected trap writes exit code 0xEE => FAILED either way.
if model_success "$LOG" && [ "$rc" -eq 0 ]; then
  echo "== PASS: base ISA (RV64GC) retires correctly under the parser patch (G11) =="
  exit 0
else
  echo "== FAIL: the parser patch broke a base-ISA instruction (rc=$rc; exit code == failing test id, 0xEE=unexpected trap) ==" >&2
  exit 1
fi
