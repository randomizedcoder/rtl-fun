#!/usr/bin/env bash
#
# scripts/cva6-parser-rearm.sh — in-core MULTI-PACKET re-arm test on the patched CVA6
# RTL model (Verilator). The RTL half of D6 Increment 2: proves the parser FU itself
# (not just the Spike/QEMU functional models) parses several packets in ONE boot by
# re-arming between them.
#
# The `cva6-parser-rearm` app's test half; the Nix wrapper (nix/cva6-parser-rearm.nix)
# prepends the cva6-baseline.sh build body (PATCHED source, CVA6_WORK=build/parser-core)
# so the patched Variane_testharness already exists, then the pinned xdp2 corpus
# (CORPUS_DIR). Preferred entry point:
#
#   nix run .#cva6-parser-rearm
#
# Where cva6-parser-cosim boots ONE ELF per packet (each a fresh, one-shot parse on the
# RTL model), this boots ONCE and parses the first REARM_CORPUS_MAX corpus packets by
# re-arming the FU between them — the RTL capability D6 Increment 2 adds:
#   * cva6_parser_wrap gets a parse_rearm_i input; a ParseLen (0x100) MMIO store pulses
#     it (ariane_testharness parser_wr_plen, threaded ariane->cva6->ex_stage), and the
#     FU re-inits its parse cursor + latched exit status and zeroes the metadata frame,
#     matching pm_init — while the CAM (programmed once) PERSISTS. (See mmio.patch +
#     rtl/cva6_parser_wrap.sv "RE-ARM (D6)".)
#   * the SAME driver as the Spike/QEMU leg — tests/cva6-parser/nic_ring.c (+ _asm.S) —
#     rides on the RTL model unchanged (it was written RTL-ready: a post-exit drain
#     margin covers the metadata-commit settle).
#
# A green run proves the WHOLE in-core chain re-arms correctly on real packets:
# fetch->decode->issue->EX(parse walk + CAM + redirect + metadata commit)->retire, then
# ParseLen store -> re-arm -> next packet, with every packet's flow_keys + exit code
# matching the golden model BYTE-FOR-BYTE across a single multi-packet run.
#
# Kept SMALL by default (REARM_CORPUS_MAX=8): the cycle-accurate RTL model is orders of
# magnitude slower than the ISA sims, and >=2 packets already exercises re-arm. The full
# 306-packet corpus is the Spike+QEMU leg's job (nix run .#cva6-parser-nic-cosim).
#
# Inputs (wrapper-provided; dev-shell fallbacks):
#   CVA6_WORK   build dir holding cva6/work-ver/Variane_testharness (build/parser-core)
#   CORPUS_DIR  pinned xdp2 pcap_templates dir     (nix/xdp2.nix)
#   REPO_ROOT   repo root (defaults to $PWD)
# Knobs:
#   REARM_CORPUS_MAX  packets parsed in the one run (default 8; 0 = all — slow!)
#   MAX_CYCLES        model cycle bound (default 2000000; scales with packet count)
#
set -euo pipefail

# Shared helpers (REPO_ROOT/MODEL/GCC + gen_vectors, run_model, emit_prog_s).
# readFile-prepended by the Nix wrapper; sourced here when run directly.
if ! declare -F gen_vectors >/dev/null 2>&1; then
  _lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
  # shellcheck source=/dev/null
  . "$_lib/common.sh"
  # shellcheck source=/dev/null
  . "$_lib/suite.sh"
  # shellcheck source=/dev/null
  . "$_lib/cosim.sh"
fi

WORK="${CVA6_WORK:-$PWD/build/parser-core}"
# shellcheck disable=SC2034  # BIN is read by run_model (scripts/lib/common.sh)
BIN="$WORK/cva6/work-ver/Variane_testharness"
TESTDIR="$REPO_ROOT/tests/cva6-parser"
OUT="$WORK/parser-rearm"
CORPUS_MAX="${REARM_CORPUS_MAX:-8}"
# shellcheck disable=SC2034  # MAXCYC is read by run_model (scripts/lib/common.sh)
MAXCYC="${MAX_CYCLES:-2000000}"

echo "== CVA6 parser in-core MULTI-PACKET re-arm test (D6 Increment 2) =="
if [ ! -x "$BIN" ]; then
  echo "ERROR: patched model not found at $BIN" >&2
  echo "       (the Nix wrapper builds it first; in the dev shell run 'nix run .#cva6-parser')" >&2
  exit 1
fi
if [ -z "${CORPUS_DIR:-}" ] || [ ! -d "${CORPUS_DIR:-/nonexistent}" ]; then
  echo "ERROR: CORPUS_DIR unset or missing ('${CORPUS_DIR:-}')" >&2
  echo "       (the Nix wrapper injects the pinned xdp2 pcap_templates)" >&2
  exit 1
fi
mkdir -p "$OUT"

# ---- 1. bake the first CORPUS_MAX packets + goldens into one C header --------------
echo "== generating the corpus blob from the golden model (max $CORPUS_MAX; 0 = all) =="
gen_vectors "$OUT" --corpus-blob "$CORPUS_DIR" "$CORPUS_MAX" >/dev/null
NPKT=$(sed -n 's/^#define CORPUS_N *\([0-9]*\).*/\1/p' "$OUT/corpus_blob.h")
echo "  corpus_blob.h: $NPKT packets"

# ---- 2. the shared parse block + CAM table (from the model) ------------------------
PROG_S="$OUT/prog.S"
emit_prog_s "$OUT" "$PROG_S"

# ---- 3. link the single ring ELF (same driver as the Spike/QEMU leg) ---------------
# -mcmodel=medany: the C driver takes the addresses of the blob arrays (.data at the
# 0x8000_0000 DRAM base), out of medlow's +-2GiB-of-0 reach. This is the identical link
# as cva6-parser-nic-cosim; the only difference is the runner (RTL model vs ISA sims).
ELF="$OUT/nic_ring.elf"
echo "== linking the NIC ring ELF (nic_ring.c + nic_ring_asm.S + prog.S) =="
"$GCC" -march=rv64gc -mabi=lp64d -mcmodel=medany -O2 -Wall -Wextra -nostdlib -nostartfiles \
  -fno-stack-protector \
  -I "$OUT" -I "$TESTDIR" -I "$REPO_ROOT/toolchain" \
  -T "$TESTDIR/link.ld" \
  "$TESTDIR/nic_ring_asm.S" "$TESTDIR/nic_ring.c" "$PROG_S" \
  -o "$ELF"
echo "  ok: $ELF"

# ---- 4. run the ONE multi-packet ELF on the patched RTL model ----------------------
LOG="$OUT/run_rearm.log"
echo "== [model] $BIN  (+max-cycles=$MAXCYC) =="
run_model "$ELF" "$LOG"
if model_success "$LOG" && [ "$MODEL_RC" -eq 0 ]; then
  echo "== PASS: the parser FU re-armed across $NPKT packets in ONE boot == the golden model (D6 Increment 2) =="
  exit 0
else
  echo "== FAIL: rc=$MODEL_RC (tohost fail code 3=keys 5=code 7=no-exit) — see $LOG ==" >&2
  grep -E "tohost|SUCCESS|FAIL|max-cycles" "$LOG" | sed 's/^/      /' | tail -6 >&2 || true
  exit 1
fi
