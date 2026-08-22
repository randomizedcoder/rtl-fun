#!/usr/bin/env bash
#
# scripts/parser-qemu.sh — run parser ELFs on the patched qemu-system-riscv64
# and check they self-report SUCCESS (Phase 7 QEMU leg).
#
# The `parser-qemu` app's body; the Nix wrapper (nix/parser-qemu.nix) prepends the
# shared script libs (common.sh + suite.sh + cosim.sh) and exports QEMU_PARSER (the
# built patched QEMU). Preferred entry point:
#
#   nix run .#parser-qemu
#
# This is the QEMU twin of scripts/parser-spike.sh: it runs the SAME self-checking
# ELFs on a `qemu-system-riscv64` (built by nix/qemu-parser.nix) that understands the
# custom-0/custom-3 parser ops (TCG helpers wrapping the golden model) and the
# 0x5000_0000 packet MMIO device. The ELFs self-check in-core against the model-baked
# goldens and encode PASS/FAIL into HTIF tohost; on `-M spike`, tohost=1 => exit(0),
# so a case PASSES iff the process exits 0. Green here == the assembler -> QEMU
# toolpath independently reproduces the golden model, the last item of the Phase 7
# exit criterion (the slice runs on Spike AND QEMU == the model).
#
# Two stages:
#   1. Smoke: parser_tandem.S — packet-independent custom-0/custom-3 ops (isolates
#      "does the parser extension decode/execute + does QEMU run a bare ELF").
#   2. Corpus: the 22-case packet suite (gen_vectors --suite), each built as
#      cosim_main.S + prog.S + case.S and run on QEMU (exercises the MMIO packet
#      load, CAM programming, parse walk, and flow_keys/status readback).
#
set -euo pipefail

# Shared helpers (REPO_ROOT/MODEL/GCC + gen_vectors, rv_assemble; the suite driver;
# the prog.S/case.S emitters). readFile-prepended by the Nix wrapper; sourced here
# when run directly from the dev shell.
if ! declare -F gen_vectors >/dev/null 2>&1; then
  _lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
  # shellcheck source=/dev/null
  . "$_lib/common.sh"
  # shellcheck source=/dev/null
  . "$_lib/suite.sh"
  # shellcheck source=/dev/null
  . "$_lib/cosim.sh"
fi

# The patched QEMU: QEMU_PARSER is the derivation prefix (wrapper-exported); fall
# back to a `qemu-system-riscv64` already on PATH for a dev-shell run.
QEMU="${QEMU:-${QEMU_PARSER:+$QEMU_PARSER/bin/}qemu-system-riscv64}"
TESTDIR="$REPO_ROOT/tests/cva6-parser"

# SLICE=1 drives the parse block from the C-intrinsics slice (parser_slice.c,
# Phase 7 Stage 3) instead of the model-generated prog.S .word stream. Everything
# else — packet MMIO load, CAM programming, self-check — is identical.
SLICE="${SLICE:-0}"
if [ "$SLICE" = "1" ]; then
  STAGE="C-intrinsics slice"
  OUT="${OUT:-$PWD/build/parser-qemu-slice}"
  OBJDUMP="${CV_SW_PREFIX:-riscv64-none-elf-}objdump"
else
  STAGE="asm corpus"
  OUT="${OUT:-$PWD/build/parser-qemu}"
fi

echo "== patched parser QEMU (Phase 7 QEMU leg: $STAGE) =="
if ! command -v "$QEMU" >/dev/null 2>&1; then
  echo "ERROR: parser qemu not found at '$QEMU'" >&2
  echo "       (the Nix wrapper builds + exports it; or put a parser 'qemu-system-riscv64' on PATH)" >&2
  exit 1
fi
echo "== using qemu: $(command -v "$QEMU")"
mkdir -p "$OUT"

# run_qemu <elf> <log> — run an ELF on the patched QEMU, capturing output; sets
# QEMU_RC to the exit code WITHOUT tripping errexit. On -M spike the HTIF device is
# wired (hw/char/riscv_htif.c): a tohost write with bit0 set => exit(payload>>1), so
# tohost=1 => exit 0 (PASS), exactly like run_spike. -bios none boots the ELF
# directly at the spike DRAM base (0x80000000, matching link.ld); -nographic keeps
# it headless. 0x5000_0000 (the packet device) is mapped by nix/qemu-parser.nix.
# `< /dev/null`: -nographic wires the guest console to our stdin, so without this
# QEMU would drain the run_suite `while read … < cases.txt` loop's stdin and only
# the first case would run. Give it an empty stdin of its own.
run_qemu() {
  set +e
  "$QEMU" -M spike -bios none -nographic -kernel "$1" >"$2" 2>&1 </dev/null
  QEMU_RC=$?
  set -e
}

# ---- 1. smoke: packet-independent parser ops -------------------------------
echo "== smoke: parser ops (parser_tandem.S) =="
RV_INCLUDES=("$TESTDIR" "$REPO_ROOT/toolchain")
rv_assemble "$OUT/smoke.elf" "$TESTDIR/link.ld" "$TESTDIR/parser_tandem.S"
run_qemu "$OUT/smoke.elf" "$OUT/smoke.log"
if [ "$QEMU_RC" -ne 0 ]; then
  echo "  FAIL: parser_tandem.S did not self-report SUCCESS on the parser qemu" >&2
  sed 's/^/      /' "$OUT/smoke.log" | tail -8 >&2
  exit 1
fi
echo "  ok: parser ops execute + self-check on the patched qemu"

# ---- 2. the 22-case packet corpus ------------------------------------------
echo "== generating the directed suite from the golden model =="
gen_vectors "$OUT" --suite >/dev/null

# The parse block: either the C-intrinsics slice (SLICE=1) or the generated .word
# stream (default). SLICE_OBJ, when set, is added to every per-case link.
PROG_S="$OUT/prog.S"
SLICE_OBJ=""
if [ "$SLICE" = "1" ]; then
  # Compile the slice at -O2: PRS_EMIT's `.insn 4, %0` uses an "i" (constant)
  # constraint, satisfied only when the static-inline builders inline+fold — which
  # needs -O1+ (rv_assemble's -O0 default would give "impossible constraint").
  echo "== compiling the C-intrinsics slice (parser_slice.c, -O2) =="
  SLICE_OBJ="$OUT/parser_slice.o"
  # -fno-stack-protector: parse_prog is naked, but also keep the toolchain default
  # canary out so nothing prepends bytes / references __stack_chk_fail.
  "$GCC" -march=rv64gc -mabi=lp64d -O2 -Wall -Wextra -Werror -nostdlib \
    -fno-stack-protector \
    -I "$REPO_ROOT/toolchain" -I "$REPO_ROOT/model" \
    -c "$TESTDIR/parser_slice.c" -o "$SLICE_OBJ"

  # Byte-parity guard (the centerpiece): the 53 words the C slice compiles to MUST
  # equal the model-generated ROM (enc.hex), word-for-word. This proves the C
  # authoring encodes exactly what the golden model does — and de-risks the run,
  # since a byte-identical drop-in for prog.S's parse block must reproduce 22/0.
  echo "== byte-parity: parser_slice.o parse_prog == model enc.hex =="
  "$OBJDUMP" --disassemble=parse_prog "$SLICE_OBJ" \
    | awk -F'\t' '/^[[:space:]]+[0-9a-f]+:/{gsub(/[[:space:]]/,"",$2); print $2}' \
    | head -n "$(wc -l < "$OUT/enc.hex")" > "$OUT/slice.words"
  if ! diff -u "$OUT/enc.hex" "$OUT/slice.words"; then
    echo "parser-qemu-slice: the C slice does not encode == the model ROM" >&2
    echo "  (left = model enc.hex, right = parser_slice.o parse_prog)" >&2
    exit 1
  fi
  echo "  ok: $(wc -l < "$OUT/enc.hex") slice words == the golden model ROM"

  # parse_prog is the C .o; the CAM table still comes from the model (data, not logic).
  emit_cam_prog_s "$OUT" "$PROG_S"
else
  emit_prog_s "$OUT" "$PROG_S"
fi

# Per case: emit case.S, link cosim_main.S + [slice.o] + prog.S + case.S, run on
# qemu; PASS iff qemu exits 0 (in-core self-check vs the model goldens -> tohost=1).
qemu_case() {
  local name="$1" cdir="$4"
  local case_s="$OUT/case_$name.S" elf="$OUT/cosim_$name.elf" log="$OUT/run_$name.log"
  gen_case_s "$cdir" "$case_s"
  RV_INCLUDES=("$TESTDIR" "$REPO_ROOT/toolchain")
  # shellcheck disable=SC2086  # $SLICE_OBJ is one optional path, intentional word-split
  rv_assemble "$elf" "$TESTDIR/link.ld" "$TESTDIR/cosim_main.S" $SLICE_OBJ "$PROG_S" "$case_s"
  run_qemu "$elf" "$log"
  [ "$QEMU_RC" -eq 0 ] && return 0
  mapfile -t CASE_TRIAGE < <(tail -4 "$log" | sed 's/^/      /')
  return 1
}

if [ "$SLICE" = "1" ]; then
  SUITE_DESC="parser-qemu-slice: C-intrinsics slice -> flow_keys on the patched parser QEMU"
  SUITE_TAG="parser-qemu-slice"
  PASS_MSG="== PASS: the C-intrinsics slice runs on QEMU == the golden model (Phase 7 exit criterion: Spike AND QEMU) =="
else
  SUITE_DESC="parser-qemu: packet -> flow_keys on the patched parser QEMU"
  SUITE_TAG="parser-qemu"
  PASS_MSG="== PASS: parser ELFs run on QEMU == the golden model (QEMU leg) =="
fi

if run_suite "$OUT/cases.txt" "$OUT/cases" "$SUITE_DESC" "$SUITE_TAG" qemu_case; then
  echo "$PASS_MSG"
  exit 0
else
  exit 1
fi
