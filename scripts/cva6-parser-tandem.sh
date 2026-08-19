#!/usr/bin/env bash
#
# scripts/cva6-parser-tandem.sh — RVFI-vs-Spike lock-step (Phase 7, Stages 0 + 1b + 1c).
#
# The *test* half of the `cva6-parser-tandem` app. The Nix wrapper
# (nix/cva6-parser-tandem.nix) prepends the cva6-baseline.sh build body built with
# SPIKE_TANDEM=1 (PATCHED source + CVA6_WORK=build/parser-tandem), so by the time
# this runs the tandem Variane_testharness — the one with the dormant RVFI-vs-Spike
# lock-step compiled in — already exists. Preferred entry point:
#
#   nix run .#cva6-parser-tandem
#
# It runs THREE stages on the one model, each stepped against Spike in lock-step (for
# every retired instruction the harness feeds the RVFI record to Spike via DPI, steps
# Spike one instruction, and rvfi_compare() checks insn / rd / pc / mode / CSRs
# REF-vs-CORE):
#   * base_isa.S     (Stage 0, G11) — the parser-op-free RV64GC directed slice,
#                    matched against the base reference Spike.
#   * parser_tandem.S (Stage 1b)    — packet-independent PARSER ops (custom-0 /
#                    custom-3), matched against the parser-extended Spike
#                    (nix/spike-tandem/parser_ext.cc), so the oracle covers the
#                    parser ISA, not just the base ISA.
#   * the 22-case packet corpus (Stage 1c) — the SAME vectors as cva6-parser-cosim,
#                    but now the packet is `sd`'d into a Spike-modelled MMIO buffer
#                    (parser_mmio.h) so PLOAD/PLENCUR + the flow_keys/status readback
#                    lock-step too — the full packet->flow_keys chain vs Spike.
# All are a strictly stronger check than a program self-check: every retired
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

# Shared helpers (rv_assemble/gen_vectors from common.sh, run_suite from suite.sh,
# emit_prog_s/gen_case_s from cosim.sh, gate_tandem from tandem.sh). readFile-
# prepended by the Nix wrapper; sourced here when run directly in the dev shell.
if ! declare -F rv_assemble >/dev/null 2>&1; then
  _lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
  # shellcheck source=/dev/null
  . "$_lib/common.sh"
  # shellcheck source=/dev/null
  . "$_lib/suite.sh"
  # shellcheck source=/dev/null
  . "$_lib/cosim.sh"
  # shellcheck source=/dev/null
  . "$_lib/tandem.sh"
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
# Assemble a single directed .S and gate it (base_isa, parser_ops).
run_tandem() {
  local label="$1" src="$2" min_instr="$3" check_isa="$4"
  local elf="$OUT/$label.elf"
  echo "== [$label] assembling $src with $GCC =="
  rv_assemble "$elf" "$TESTDIR/link.ld" "$TESTDIR/$src"
  echo "== [$label] running on the tandem model (max $MAXCYC cycles) =="
  if gate_tandem "$label" "$elf" "$min_instr" "$check_isa"; then
    echo "== [$label] report: $GATE_SUMMARY =="
    echo "== [$label] PASS: every retired instruction matched Spike in lock-step; self-check SUCCESS =="
    return 0
  fi
  echo "== [$label] report: $GATE_SUMMARY ==" >&2
  echo "== [$label] FAIL: lock-step against Spike did not cleanly pass ==" >&2
  printf '%s\n' "${GATE_TRIAGE[@]}" >&2
  return 1
}

overall=0
# Stage 0 (G11): the base-ISA slice — every retired RV64GC instruction vs Spike.
run_tandem base_isa    base_isa.S    200 1 || overall=1
# Stage 1b: parser ops — custom-0/custom-3 lock-stepped against the parser extension.
run_tandem parser_ops  parser_tandem.S 20 0 || overall=1

# Stage 1c: the whole packet corpus lock-stepped against the parser-taught Spike —
# real PLOAD/PLENCUR reading the MMIO packet buffer (parser_mmio.h) + the flow_keys/
# status readback, every retired instruction (packet stores, parse walk, meta/status
# loads) matched against Spike. Same vectors as cva6-parser-cosim, but the oracle is
# per-instruction Spike rather than the golden model's committed bytes.
COSIM_OUT="$OUT/cosim"
mkdir -p "$COSIM_OUT"
echo "== [cosim] generating the packet corpus from the model =="
gen_vectors "$COSIM_OUT" --suite >/dev/null
COSIM_PROG_S="$COSIM_OUT/prog.S"
emit_prog_s "$COSIM_OUT" "$COSIM_PROG_S"

# run_suite callback: build the 3-file cosim ELF for a case and gate it on the tandem
# model. The driver `sd`s the packet + ParseLen + exit-PC over MMIO, programs the CAM,
# runs the parse block, then `ld`s flow_keys/status back — all lock-stepped vs Spike.
cosim_tandem_case() {
  local name="$1" cdir="$4"
  local case_s="$COSIM_OUT/case_$name.S" elf="$COSIM_OUT/cosim_$name.elf"
  gen_case_s "$cdir" "$case_s"
  RV_INCLUDES=("$TESTDIR" "$REPO_ROOT/toolchain")   # cosim_main.S #includes parser_mmio.h + htif.S
  rv_assemble "$elf" "$TESTDIR/link.ld" "$TESTDIR/cosim_main.S" "$COSIM_PROG_S" "$case_s"
  if gate_tandem "cosim-$name" "$elf" 20 0; then
    CASE_TRIAGE=("      report: $GATE_SUMMARY")
    return 0
  fi
  CASE_TRIAGE=("      report: $GATE_SUMMARY" "${GATE_TRIAGE[@]}")
  return 1
}

if ! run_suite "$COSIM_OUT/cases.txt" "$COSIM_OUT/cases" \
    "parser packet corpus under RVFI-vs-Spike lock-step (Stage 1c)" \
    "parser tandem cosim" cosim_tandem_case; then
  overall=1
fi

if [ "$overall" -eq 0 ]; then
  echo "== PASS: base-ISA (Stage 0) + parser-op (Stage 1b) + 22-case packet cosim (Stage 1c) lock-step clean vs Spike (G11) =="
  exit 0
fi
echo "== FAIL: one or more tandem lock-step runs did not cleanly pass ==" >&2
exit 1
