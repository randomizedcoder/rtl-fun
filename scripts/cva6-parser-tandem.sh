#!/usr/bin/env bash
#
# scripts/cva6-parser-tandem.sh — base-ISA RVFI-vs-Spike lock-step (Phase 7, Stage 0).
#
# The *test* half of the `cva6-parser-tandem` app. The Nix wrapper
# (nix/cva6-parser-tandem.nix) prepends the cva6-baseline.sh build body built with
# SPIKE_TANDEM=1 (PATCHED source + CVA6_WORK=build/parser-tandem), so by the time
# this runs the tandem Variane_testharness — the one with the dormant RVFI-vs-Spike
# lock-step compiled in — already exists. Preferred entry point:
#
#   nix run .#cva6-parser-tandem
#
# It assembles tests/cva6-parser/base_isa.S (the parser-op-free RV64GC directed
# slice reused from N6) and runs it with a tandem Spike stepping in lock-step: for
# every instruction the core retires, the harness (corev_apu/tb/common/spike.sv)
# feeds the RVFI record to Spike via DPI, steps Spike one instruction, and
# rvfi_compare() checks insn / rd / pc / mode / CSRs REF-vs-CORE. This is a
# strictly stronger G11 than N6's program self-check: every retired instruction is
# matched against an independent ISA oracle, not just the final program result.
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

echo "== CVA6 base-ISA RVFI-vs-Spike lock-step (Phase 7, Stage 0) =="
echo "  model : $BIN"
echo "  test  : $TESTDIR/base_isa.S"

if [ ! -x "$BIN" ]; then
  echo "ERROR: tandem model not found at $BIN" >&2
  echo "       (the Nix wrapper builds it first with SPIKE_TANDEM=1)" >&2
  exit 1
fi

mkdir -p "$OUT"
echo "== assembling ELF with $GCC =="
RV_INCLUDES=("$TESTDIR")   # so base_isa.S can #include "htif.S"
ELF="$OUT/base_isa.elf"
rv_assemble "$ELF" "$TESTDIR/link.ld" "$TESTDIR/base_isa.S"

echo "== running on the tandem model (max $MAXCYC cycles) =="
LOG="$OUT/base_isa.log"
REPORT="$OUT/tandem_report.yaml"
rm -f "$REPORT"
# Spike's reference model needs several run-time inputs the base run doesn't:
#   +elf_file   — Spike loads the ELF into its own memory (fesvr loads argv[1] too)
#   +core_name  — selects Spike's default-params profile; must start with "cv64a"
#                 (riscv_dpi.cc spike_set_default_params) or it aborts as UNSUPPORTED
#                 and derives isa=RV64GC. Default from the build target.
#   +report_file— where the scoreboard writes its YAML verdict (the pass/fail gate)
CORE_NAME="${CVA6_TARGET:-cv64a6_imafdc_sv39}"
# LD_LIBRARY_PATH: Spike dlopen()s libcustomext.so (the cvxif extension) by bare
# soname; point it at the tandem prefix's lib so the loader finds it.
export LD_LIBRARY_PATH="$SPIKE_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# ulimit -s unlimited: st_rvfi carries csr arrays sized CSR_MAX_SIZE(=4096), so one
# struct is ~196 KB; spike.sv/rvfi_compare pass it BY VALUE, and the generated
# Verilator NBA code puts those copies on the stack — the default 8 MB stack
# overflows (SIGSEGV in _nba_sequent__TOP__0) before the first compare.
set +e
( ulimit -s unlimited
  "$BIN" "$ELF" "+elf_file=$ELF" "+core_name=$CORE_NAME" \
    "+report_file=$REPORT" "+max-cycles=$MAXCYC" ) >"$LOG" 2>&1
rc=$?
set -e

# ---- gate on the scoreboard's YAML report (the authoritative verdict) ----------
# exit_cause: SUCCESS + mismatches_count: 0x0 means Spike agreed with the core on
# every retired instruction. A mismatch flips exit_cause to MISMATCH and/or bumps
# mismatches_count; ≥5 mismatches also uvm_fatal (nonzero rc). We require the report
# to exist AND be clean, plus the program's own fesvr self-check SUCCESS.
tandem_ok=0
if [ -f "$REPORT" ]; then
  cause="$(grep -E '^exit_cause:' "$REPORT" | awk '{print $2}')"
  mmc="$(grep -E '^mismatches_count:' "$REPORT" | awk '{print $2}')"
  icnt_hex="$(grep -E '^instr_count:' "$REPORT" | awk '{print $2}')"
  icnt=$(( icnt_hex + 0 ))   # 0x-prefixed hex -> decimal
  echo "== tandem report: exit_cause=$cause mismatches_count=$mmc instr_count=$icnt =="
  cause_ok=0; [ "$cause" = "SUCCESS" ] && cause_ok=1
  # mismatches_count is printed "0x%h" (e.g. 0x00000000), so compare numerically
  # rather than by exact string — any width of leading zeros must read as clean.
  mmc_ok=0;   [ "$(( mmc + 0 ))" -eq 0 ] && mmc_ok=1
  # Guard against a VACUOUS green: base_isa.S retires ~287 instructions, so a run
  # that compared almost nothing (harness died early, Spike never stepped) must
  # NOT pass as "0 mismatches". Require a healthy floor of compared instructions.
  cnt_ok=0;   [ "$icnt" -ge 200 ] && cnt_ok=1
  [ "$cnt_ok" -eq 0 ] && echo "== FAIL: only $icnt instructions lock-stepped (<200) — vacuous run ==" >&2
  # Guard the config seam that a prior bug lived in: the reference Spike must have
  # been built for the full RV64GC ISA (I M A F D C). A dropped extension letter
  # (e.g. the get_misa D-bit bug) would silently weaken the oracle, so assert the
  # ISA string the harness logged actually carries F and D.
  isa_ok=0
  if grep -qE "isa: 'RV64I.*M.*A.*F.*D.*C" "$LOG"; then isa_ok=1; else
    echo "== FAIL: tandem Spike ISA string missing an expected RV64GC extension ==" >&2
    grep -E "isa:" "$LOG" | sed 's/^/    /' >&2
  fi
  [ "$cause_ok" -eq 1 ] && [ "$mmc_ok" -eq 1 ] && [ "$cnt_ok" -eq 1 ] && [ "$isa_ok" -eq 1 ] && tandem_ok=1
else
  echo "== FAIL: no tandem report at $REPORT (lock-step never reached a verdict) ==" >&2
fi

if [ "$tandem_ok" -eq 1 ] && model_success "$LOG"; then
  echo "== PASS: every retired RV64GC instruction matched Spike in lock-step; program self-check SUCCESS (G11, Stage 0) =="
  exit 0
else
  echo "== FAIL: base-ISA lock-step against Spike did not cleanly pass (rc=$rc) ==" >&2
  echo "-- last 40 log lines --" >&2
  tail -40 "$LOG" | sed 's/^/    /' >&2
  [ -f "$REPORT" ] && { echo "-- report --" >&2; sed 's/^/    /' "$REPORT" >&2; }
  exit 1
fi
