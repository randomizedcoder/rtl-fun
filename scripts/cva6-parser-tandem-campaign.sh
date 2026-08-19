#!/usr/bin/env bash
#
# scripts/cva6-parser-tandem-campaign.sh — the Phase-7 Stage-2 random-packet
# tandem campaign. Where cva6-parser-tandem lock-steps a fixed 22-case corpus,
# this drives HUNDREDS of packets — seeded constrained-random + the real xdp2
# pcap corpus — through the SAME RVFI-vs-Spike lock-step, each packet its own
# `sd`-into-MMIO + parse-walk + flow_keys/status readback matched per-instruction
# against the parser-taught Spike (nix/spike-tandem). Preferred entry point:
#
#   nix run .#cva6-parser-tandem-campaign
#
# Scope / honesty (see docs/analysis/cva6-verification-design.md §2.6.2):
#   * This randomizes the PACKET axis, not the RV64GC instruction stream. The
#     parse program is a single fixed pm_slice_program; the meaningful random
#     surface for the parser is the packet. Full riscv-dv (random instruction
#     interleaving via corev-dv) stays deferred — it needs a commercial UVM sim.
#   * Both the core's reference model AND Spike's extension are libparsermodel, so
#     the PARSER tandem proves "RTL executor == model" on random input (catching
#     RTL bugs the directed 22 missed); real Spike is the independent oracle for
#     the surrounding RV64GC stream, not for the flow_keys re-derivation.
#
# Reproducibility: the seed is a fixed committed default (so the gate is
# deterministic) and is logged up front; every generated case.S/.elf is kept on
# disk, and each case name encodes its origin (rand-<seed>-<i> or corpus-<pcap>),
# so a failure carries its own exact repro. Re-running with the same CAMPAIGN_SEED
# reproduces the identical case set bit-for-bit.
#
# Bounded + env-configurable (modest gate defaults; scale up for a nightly soak):
#   CAMPAIGN_SEED        PRNG seed for the random packets      (default 0xC0FFEE)
#   CAMPAIGN_RANDOM_N    number of random packets              (default 50)
#   CAMPAIGN_CORPUS_MAX  max real pcaps (0 => all ~306 Eth)    (default 50)
#   MAX_CYCLES           per-case Verilator cycle bound        (default 200000)
# Full soak:  CAMPAIGN_RANDOM_N=2000 CAMPAIGN_CORPUS_MAX=0 nix run .#cva6-parser-tandem-campaign
#
# Inputs (wrapper-provided; dev-shell fallbacks):
#   CVA6_WORK   build dir holding the tandem Variane_testharness (build/parser-tandem
#               — SHARED with cva6-parser-tandem so the ~15-min model build is reused)
#   REPO_ROOT   repo root holding tests/cva6-parser (defaults to $PWD)
#   CORPUS_DIR  the pinned xdp2 pcap_templates dir (injected by the Nix wrapper)
#
set -euo pipefail

# Shared helpers (rv_assemble/gen_vectors from common.sh, run_suite from suite.sh,
# emit_prog_s/gen_case_s from cosim.sh, gate_tandem from tandem.sh). readFile-
# prepended by the Nix wrapper; sourced here when run in the dev shell.
if ! declare -F gate_tandem >/dev/null 2>&1; then
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
OUT="$WORK/parser-tandem-campaign"
MAXCYC="${MAX_CYCLES:-200000}"
CORE_NAME="${CVA6_TARGET:-cv64a6_imafdc_sv39}"

SEED="${CAMPAIGN_SEED:-0xC0FFEE}"
RANDOM_N="${CAMPAIGN_RANDOM_N:-50}"
CORPUS_MAX="${CAMPAIGN_CORPUS_MAX:-50}"

echo "== CVA6 RVFI-vs-Spike random-packet campaign (Phase 7, Stage 2) =="
echo "  model      : $BIN"
echo "  seed       : $SEED   (reproducible; re-run same seed => same cases)"
echo "  random N   : $RANDOM_N"
echo "  corpus max : $CORPUS_MAX   (0 = all Ethernet pcaps)"
echo "  corpus dir : ${CORPUS_DIR:-<unset>}"

if [ ! -x "$BIN" ]; then
  echo "ERROR: tandem model not found at $BIN" >&2
  echo "       (the Nix wrapper builds it first with SPIKE_TANDEM=1)" >&2
  exit 1
fi

mkdir -p "$OUT"
# LD_LIBRARY_PATH: Spike dlopen()s libcustomext.so (parser extension) by soname.
export LD_LIBRARY_PATH="$SPIKE_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# The parse program (parser block + CAM) is fixed across every packet — generate
# it once (any mode emits enc.hex/camprog.hex) and build the shared prog.S from it.
gen_vectors "$OUT" --random 1 "$SEED" >/dev/null
PROG_S="$OUT/prog.S"
emit_prog_s "$OUT" "$PROG_S"

# campaign_case: build the 3-file cosim ELF for one generated packet case and gate
# it on the tandem model (identical to Stage 1c's cosim_tandem_case, generalized
# to the random/corpus case dirs). On FAIL, the case name (which encodes the seed+
# index or the pcap basename) plus the exact replay line make the repro explicit.
campaign_case() {
  local name="$1" cdir="$4"
  local case_s="$CASES_SRC/case_$name.S" elf="$CASES_SRC/cosim_$name.elf"
  gen_case_s "$cdir" "$case_s"
  RV_INCLUDES=("$TESTDIR" "$REPO_ROOT/toolchain")   # cosim_main.S #includes parser_mmio.h + htif.S
  rv_assemble "$elf" "$TESTDIR/link.ld" "$TESTDIR/cosim_main.S" "$PROG_S" "$case_s"
  if gate_tandem "camp-$name" "$elf" 20 0; then
    CASE_TRIAGE=("      report: $GATE_SUMMARY")
    return 0
  fi
  CASE_TRIAGE=(
    "      report: $GATE_SUMMARY"
    "      repro : CAMPAIGN_SEED=$SEED regenerate '$name', relink, rerun on \$BIN"
    "${GATE_TRIAGE[@]}"
  )
  return 1
}

overall=0

# --- leg 1: constrained-random packets --------------------------------------
RAND_DIR="$OUT/rand"
mkdir -p "$RAND_DIR"
echo "== [random] generating $RANDOM_N constrained-random packets (seed $SEED) =="
gen_vectors "$RAND_DIR" --random "$RANDOM_N" "$SEED" >/dev/null
CASES_SRC="$RAND_DIR"
if ! run_suite "$RAND_DIR/cases.txt" "$RAND_DIR/cases" \
    "random packets under RVFI-vs-Spike lock-step (seed $SEED, N=$RANDOM_N)" \
    "random campaign" campaign_case; then
  overall=1
fi

# --- leg 2: real xdp2 pcap corpus -------------------------------------------
if [ -n "${CORPUS_DIR:-}" ] && [ -d "${CORPUS_DIR:-/nonexistent}" ]; then
  CORPUS_OUT="$OUT/corpus"
  mkdir -p "$CORPUS_OUT"
  echo "== [corpus] generating from $CORPUS_DIR (max $CORPUS_MAX; non-Ethernet skipped) =="
  gen_vectors "$CORPUS_OUT" --corpus "$CORPUS_DIR" "$CORPUS_MAX" >/dev/null
  CASES_SRC="$CORPUS_OUT"
  if ! run_suite "$CORPUS_OUT/cases.txt" "$CORPUS_OUT/cases" \
      "real xdp2 pcap corpus under RVFI-vs-Spike lock-step (max $CORPUS_MAX)" \
      "corpus campaign" campaign_case; then
    overall=1
  fi
else
  echo "== [corpus] SKIP: CORPUS_DIR unset or missing (random leg still ran) =="
fi

if [ "$overall" -eq 0 ]; then
  echo "== PASS: every random + corpus packet lock-stepped clean vs Spike (Stage 2) =="
  echo "         seed=$SEED random_n=$RANDOM_N corpus_max=$CORPUS_MAX — reproducible with the same seed"
  exit 0
fi
echo "== FAIL: one or more campaign packets did not cleanly lock-step vs Spike ==" >&2
echo "         re-run with CAMPAIGN_SEED=$SEED to reproduce the identical case set ==" >&2
exit 1
