#!/usr/bin/env bash
#
# scripts/cva6-parser-nic-cosim.sh — in-core NIC ring driver over the WHOLE packet
# corpus in ONE booted process (D6).
#
# The `cva6-parser-nic-cosim` app's body; the Nix wrapper (nix/cva6-parser-nic-cosim.nix)
# prepends the shared script libs (common.sh + suite.sh + cosim.sh) and exports the
# built standalone Spike (SPIKE_PARSER) + patched QEMU (QEMU_PARSER) and the pinned
# xdp2 corpus (CORPUS_DIR). Preferred entry point:
#
#   nix run .#cva6-parser-nic-cosim
#
# Where cva6-parser-cosim / parser-spike / parser-qemu boot ONE ELF per packet (each
# a fresh, one-shot parse), this builds a SINGLE ELF that parses the entire corpus by
# re-arming the FU between packets — the multi-packet capability D6 adds:
#   * parser_shared.rearm (nix/{spike-tandem,qemu-parser}/parser_shared.h) is set on
#     every ParseLen (0x100) store and consumed by the extension's arm gate, so a new
#     ParseLen re-binds the model to the next packet (pm_init: done=0, meta zeroed;
#     the CAM, programmed once, persists).
#   * gen_parser_rom --corpus-blob bakes the whole corpus + per-packet golden
#     flow_keys/exit-code into one C header (corpus_blob.h).
#   * tests/cva6-parser/nic_ring.c (+ nic_ring_asm.S) is a NIC RX descriptor-ring
#     driver: DMA frame -> arm (ParseLen) -> parse -> compare vs golden, per packet;
#     tohost=1 iff every packet matched (fesvr exit 0 => PASS), else 3/5/7.
#
# Run on BOTH functional sims: Spike primary, QEMU secondary. Green on both proves the
# software/logic parses the real corpus == the golden model across a re-arming,
# multi-packet run — with no board and no per-packet reboot (Phase 8 D6).
#
# Inputs (wrapper-provided; dev-shell fallbacks):
#   SPIKE_PARSER  standalone parser Spike prefix     (nix/spike-parser.nix)
#   QEMU_PARSER   patched parser QEMU prefix         (nix/qemu-parser.nix)
#   CORPUS_DIR    pinned xdp2 pcap_templates dir     (nix/xdp2.nix)
#   REPO_ROOT     repo root (defaults to $PWD)
# Knobs:
#   NIC_CORPUS_MAX  max Ethernet pcaps in the blob (0 = all)   (default 0)
#
set -euo pipefail

# Shared helpers (REPO_ROOT/MODEL/GCC + gen_vectors, and cosim.sh's emit_prog_s).
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

SPIKE="${SPIKE:-${SPIKE_PARSER:+$SPIKE_PARSER/bin/}spike}"
QEMU="${QEMU:-${QEMU_PARSER:+$QEMU_PARSER/bin/}qemu-system-riscv64}"
ISA="${PARSER_SPIKE_ISA:-rv64gc}"
TESTDIR="$REPO_ROOT/tests/cva6-parser"
OUT="${OUT:-$PWD/build/parser-nic-cosim}"
CORPUS_MAX="${NIC_CORPUS_MAX:-0}"

echo "== CVA6 parser in-core NIC ring cosim (D6: multi-packet re-arm) =="
if [ -z "${CORPUS_DIR:-}" ] || [ ! -d "${CORPUS_DIR:-/nonexistent}" ]; then
  echo "ERROR: CORPUS_DIR unset or missing ('${CORPUS_DIR:-}')" >&2
  echo "       (the Nix wrapper injects the pinned xdp2 pcap_templates)" >&2
  exit 1
fi
mkdir -p "$OUT"

# ---- 1. bake the whole corpus + goldens into one C header --------------------
echo "== generating the corpus blob from the golden model (max $CORPUS_MAX; 0 = all) =="
gen_vectors "$OUT" --corpus-blob "$CORPUS_DIR" "$CORPUS_MAX" >/dev/null
NPKT=$(sed -n 's/^#define CORPUS_N *\([0-9]*\).*/\1/p' "$OUT/corpus_blob.h")
echo "  corpus_blob.h: $NPKT packets"

# ---- 2. the shared parse block + CAM table (from the model) ------------------
PROG_S="$OUT/prog.S"
emit_prog_s "$OUT" "$PROG_S"

# ---- 3. link the single ring ELF --------------------------------------------
# -mcmodel=medany: the C driver takes the addresses of the blob arrays (.data at the
# 0x8000_0000 DRAM base), out of medlow's +-2GiB-of-0 reach; medany materializes them
# pc-relative. -O2 keeps the driver compact. The asm shim + prog.S ride in the same
# link (their `la`/absolute refs are model-agnostic).
ELF="$OUT/nic_ring.elf"
echo "== linking the NIC ring ELF (nic_ring.c + nic_ring_asm.S + prog.S) =="
"$GCC" -march=rv64gc -mabi=lp64d -mcmodel=medany -O2 -Wall -Wextra -nostdlib -nostartfiles \
  -fno-stack-protector \
  -I "$OUT" -I "$TESTDIR" -I "$REPO_ROOT/toolchain" \
  -T "$TESTDIR/link.ld" \
  "$TESTDIR/nic_ring_asm.S" "$TESTDIR/nic_ring.c" "$PROG_S" \
  -o "$ELF"
echo "  ok: $ELF"

# ---- 4. run on both functional sims -----------------------------------------
# (no cycle cap passed: like parser-spike/parser-qemu we let the ISA sims run the
# bare ELF to its HTIF exit; the driver's ring loop terminates on its own.)
rc_all=0

run_one() {
  # <label> <log> <cmd...>  -> sets LAST_RC; prints PASS/FAIL + triage on fail
  local label="$1" log="$2"; shift 2
  set +e
  "$@" >"$log" 2>&1 </dev/null
  LAST_RC=$?
  set -e
  if [ "$LAST_RC" -eq 0 ]; then
    echo "  PASS ($label): all $NPKT packets == the golden model across a re-arming run"
  else
    echo "  FAIL ($label): rc=$LAST_RC (tohost fail code 3=keys 5=code 7=no-exit)" >&2
    grep -E "tohost|SUCCESS|FAIL|max-cycles" "$log" | sed 's/^/      /' | tail -4 >&2 || true
    rc_all=1
  fi
}

# Spike (primary): the parser extension auto-registers (no --extension flag).
echo "== [spike] $(command -v "$SPIKE" 2>/dev/null || echo "$SPIKE") =="
if ! command -v "$SPIKE" >/dev/null 2>&1; then
  echo "ERROR: parser spike not found at '$SPIKE'" >&2; exit 1
fi
run_one spike "$OUT/run_spike.log" "$SPIKE" "--isa=$ISA" "$ELF"

# QEMU (secondary): -M spike wires HTIF (tohost=1 => exit 0); 0x5000_0000 mapped by
# nix/qemu-parser.nix; -bios none boots the ELF at 0x8000_0000 (matches link.ld).
echo "== [qemu] $(command -v "$QEMU" 2>/dev/null || echo "$QEMU") =="
if ! command -v "$QEMU" >/dev/null 2>&1; then
  echo "ERROR: parser qemu not found at '$QEMU'" >&2; exit 1
fi
run_one qemu "$OUT/run_qemu.log" "$QEMU" -M spike -bios none -nographic -kernel "$ELF"

if [ "$rc_all" -eq 0 ]; then
  echo "== PASS: the NIC ring driver parses the whole corpus ($NPKT pkts) == the golden model on Spike AND QEMU (D6) =="
  exit 0
else
  echo "== FAIL: see logs in $OUT =="
  exit 1
fi
