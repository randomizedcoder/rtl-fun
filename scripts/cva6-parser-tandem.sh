#!/usr/bin/env bash
#
# scripts/cva6-parser-tandem.sh — RVFI-vs-Spike lock-step (Phase 7, Stages 0 + 1b).
#
# The *test* half of the `cva6-parser-tandem` app. The Nix wrapper
# (nix/cva6-parser-tandem.nix) prepends the cva6-baseline.sh build body built with
# SPIKE_TANDEM=1 (PATCHED source + CVA6_WORK=build/parser-tandem), so by the time
# this runs the tandem Variane_testharness — the one with the dormant RVFI-vs-Spike
# lock-step compiled in — already exists. Preferred entry point:
#
#   nix run .#cva6-parser-tandem
#
# It runs TWO directed tests on the one model, each stepped against Spike in
# lock-step (for every retired instruction the harness feeds the RVFI record to
# Spike via DPI, steps Spike one instruction, and rvfi_compare() checks
# insn / rd / pc / mode / CSRs REF-vs-CORE):
#   * base_isa.S     (Stage 0, G11) — the parser-op-free RV64GC directed slice,
#                    matched against the base reference Spike.
#   * parser_tandem.S (Stage 1b)    — packet-independent PARSER ops (custom-0 /
#                    custom-3), matched against the parser-extended Spike
#                    (nix/spike-tandem/parser_ext.cc), so the oracle now covers the
#                    parser ISA, not just the base ISA.
# Both are a strictly stronger check than a program self-check: every retired
# instruction is matched against an independent ISA oracle, not just the result.
#
# Spike needs two plusargs the base run doesn't: +elf_file (it loads the ELF into
# its own memory) and +report_file (the scoreboard writes a YAML verdict there —
# the authoritative pass/fail, since a 1-4 instruction mismatch only uvm_errors and
# may not flip the process exit code). PASS iff that report says exit_cause SUCCESS
# with mismatches_count 0 AND fesvr reports the program's own self-check SUCCESS.
#
# Inputs (wrapper-provided; dev-shell fallbacks):
#   CVA6_WORK   build dir holding cva6/work-ver/Variane_testharness (build/parser-tandem)
#   REPO_ROOT   repo root holding tests/cva6-parser (defaults to $PWD)
#
set -euo pipefail

# Shared helpers (rv_assemble, model_success). readFile-prepended by the Nix
# wrapper; sourced here when run directly in the dev shell.
if ! declare -F rv_assemble >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
fi

WORK="${CVA6_WORK:-$PWD/build/parser-tandem}"
BIN="$WORK/cva6/work-ver/Variane_testharness"
TESTDIR="$REPO_ROOT/tests/cva6-parser"
OUT="$WORK/parser-tandem"
MAXCYC="${MAX_CYCLES:-200000}"

echo "== CVA6 RVFI-vs-Spike tandem lock-step (Phase 7) =="
echo "  model : $BIN"

if [ ! -x "$BIN" ]; then
  echo "ERROR: tandem model not found at $BIN" >&2
  echo "       (the Nix wrapper builds it first with SPIKE_TANDEM=1)" >&2
  exit 1
fi

mkdir -p "$OUT"
RV_INCLUDES=("$TESTDIR")   # so the tests can #include "htif.S"
CORE_NAME="${CVA6_TARGET:-cv64a6_imafdc_sv39}"
# LD_LIBRARY_PATH: Spike dlopen()s libcustomext.so (cvxif + our parser extension) by
# bare soname; point it at the tandem prefix's lib so the loader finds it.
export LD_LIBRARY_PATH="$SPIKE_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# run_tandem <label> <test.S> <min_instr> <check_isa 0|1>
# Assemble the directed test, run it on the tandem model, and gate on the
# scoreboard's YAML report (the authoritative verdict): exit_cause SUCCESS AND
# mismatches_count 0 (numeric — printed 0x%h, any width of leading zeros is clean)
# AND at least <min_instr> instructions lock-stepped (anti-vacuous) AND the program's
# own fesvr self-check SUCCESS. Returns 0 on PASS, 1 on FAIL.
run_tandem() {
  local label="$1" src="$2" min_instr="$3" check_isa="$4"
  local elf="$OUT/$label.elf" log="$OUT/$label.log" report="$OUT/$label.report.yaml"
  echo "== [$label] assembling $src with $GCC =="
  rv_assemble "$elf" "$TESTDIR/link.ld" "$TESTDIR/$src"
  rm -f "$report"
  echo "== [$label] running on the tandem model (max $MAXCYC cycles) =="
  # Spike's reference model needs +elf_file (it loads the ELF into its own memory),
  # +core_name (its default-params profile; must start with cv64a), and +report_file
  # (where the scoreboard writes its verdict). ulimit -s unlimited: the ~196 KB
  # st_rvfi is passed by value onto the Verilator NBA stack (default 8 MB SIGSEGVs).
  local rc=0
  set +e
  ( ulimit -s unlimited
    "$BIN" "$elf" "+elf_file=$elf" "+core_name=$CORE_NAME" \
      "+report_file=$report" "+max-cycles=$MAXCYC" ) >"$log" 2>&1
  rc=$?
  set -e

  local ok=1
  if [ -f "$report" ]; then
    local cause mmc icnt_hex icnt
    cause="$(grep -E '^exit_cause:' "$report" | awk '{print $2}')"
    mmc="$(grep -E '^mismatches_count:' "$report" | awk '{print $2}')"
    icnt_hex="$(grep -E '^instr_count:' "$report" | awk '{print $2}')"
    icnt=$(( icnt_hex + 0 ))
    echo "== [$label] report: exit_cause=$cause mismatches_count=$mmc instr_count=$icnt =="
    [ "$cause" = "SUCCESS" ] || { ok=0; echo "== [$label] FAIL: exit_cause=$cause (not SUCCESS) ==" >&2; }
    [ "$(( mmc + 0 ))" -eq 0 ] || { ok=0; echo "== [$label] FAIL: mismatches_count=$mmc (nonzero) ==" >&2; }
    [ "$icnt" -ge "$min_instr" ] || { ok=0; echo "== [$label] FAIL: only $icnt instructions lock-stepped (<$min_instr) — vacuous ==" >&2; }
  else
    ok=0; echo "== [$label] FAIL: no report at $report (lock-step never reached a verdict) ==" >&2
  fi
  # Guard the config seam a prior bug lived in: the reference Spike must be the full
  # RV64GC ISA (I M A F D C) — a dropped extension letter silently weakens the oracle.
  if [ "$check_isa" -eq 1 ]; then
    if ! grep -qE "isa: 'RV64I.*M.*A.*F.*D.*C" "$log"; then
      ok=0; echo "== [$label] FAIL: tandem Spike ISA string missing an expected RV64GC extension ==" >&2
      grep -E "isa:" "$log" | sed 's/^/    /' >&2
    fi
  fi
  model_success "$log" || { ok=0; echo "== [$label] FAIL: program fesvr self-check did not SUCCEED ==" >&2; }

  if [ "$ok" -eq 1 ]; then
    echo "== [$label] PASS: every retired instruction matched Spike in lock-step; self-check SUCCESS =="
    return 0
  fi
  echo "== [$label] FAIL: lock-step against Spike did not cleanly pass (rc=$rc) ==" >&2
  echo "-- [$label] last 40 log lines --" >&2
  tail -40 "$log" | sed 's/^/    /' >&2
  [ -f "$report" ] && { echo "-- [$label] report --" >&2; sed 's/^/    /' "$report" >&2; }
  return 1
}

overall=0
# Stage 0 (G11): the base-ISA slice — every retired RV64GC instruction vs Spike.
run_tandem base_isa    base_isa.S    200 1 || overall=1
# Stage 1b: parser ops — custom-0/custom-3 lock-stepped against the parser extension.
run_tandem parser_ops  parser_tandem.S 20 0 || overall=1

if [ "$overall" -eq 0 ]; then
  echo "== PASS: base-ISA (Stage 0) + parser-op (Stage 1b) lock-step clean vs Spike (G11) =="
  exit 0
fi
echo "== FAIL: one or more tandem lock-step runs did not cleanly pass ==" >&2
exit 1
