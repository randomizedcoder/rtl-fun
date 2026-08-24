#!/usr/bin/env bash
#
# scripts/parser-spike.sh — run parser ELFs on the STANDALONE parser Spike and
# check they self-report SUCCESS (Phase 7 Stage 2).
#
# The `parser-spike` app's body; the Nix wrapper (nix/parser-spike.nix) prepends the
# shared script libs (common.sh + suite.sh + cosim.sh) and exports SPIKE_PARSER (the
# built standalone spike). Preferred entry point:
#
#   nix run .#parser-spike
#
# Unlike cva6-parser-cosim (which runs the same ELFs on the CVA6 Verilator model),
# this runs them on the reference ISA simulator built by nix/spike-parser.nix — a
# real `spike` binary that understands the custom-0/custom-3 parser ops (customext
# `parser_ext.cc`, wrapping the golden model) and the 0x5000_0000 packet MMIO window.
# The ELFs self-check in-core against the model-baked goldens and encode PASS/FAIL
# into HTIF tohost, so on Spike a case PASSES iff the process exits 0 (tohost=1).
# That makes the assembler -> ISA-sim toolpath an independent check of the model.
#
# Two stages:
#   1. Smoke: parser_tandem.S — packet-independent custom-0/custom-3 ops (isolates
#      "does the parser extension decode/execute + does spike run a bare ELF").
#   2. Corpus: the 22-case packet suite (gen_vectors --suite), each built as
#      cosim_main.S + prog.S + case.S and run on spike (exercises the MMIO packet
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

# The standalone spike: SPIKE_PARSER is the derivation prefix (wrapper-exported);
# fall back to a `spike` already on PATH for a dev-shell run.
SPIKE="${SPIKE:-${SPIKE_PARSER:+$SPIKE_PARSER/bin/}spike}"
ISA="${PARSER_SPIKE_ISA:-rv64gc}"
TESTDIR="$REPO_ROOT/tests/cva6-parser"

# SLICE=1 drives the parse block from the C-intrinsics slice (parser_slice.c,
# Phase 7 Stage 3) instead of the model-generated prog.S .word stream (Stage 2).
# Everything else — packet MMIO load, CAM programming, self-check — is identical.
#
# The slice compiler is a hook so the SAME runner drives two authoring paths with
# one body (no drift): the default GNU cross-gcc over the inline-asm intrinsics
# (parser-spike-slice, Stage 3), or the parser-patched Clang over the mnemonic-form
# __builtin_riscv_prs_* builtins (parser-clang-slice, Phase 7 C2) — the wrapper sets
#   SLICE_CC       the compiler (default: the cross gcc from common.sh)
#   SLICE_CC_EXTRA extra flags, e.g. "--target=riscv64-unknown-elf -DPRS_USE_BUILTINS"
#   SLICE_STAGE    the banner label
# Either way the compiled parse_prog must be 53-word byte-identical to the model ROM
# (enc.hex), so the byte-parity guard is the convergence oracle for both lowerings.
SLICE="${SLICE:-0}"
SLICE_CC="${SLICE_CC:-$GCC}"
SLICE_CC_EXTRA="${SLICE_CC_EXTRA:-}"
if [ "$SLICE" = "1" ]; then
  STAGE="${SLICE_STAGE:-Stage 3 (C-intrinsics slice)}"
  OUT="${OUT:-$PWD/build/parser-spike-slice}"
  OBJDUMP="${CV_SW_PREFIX:-riscv64-none-elf-}objdump"
else
  STAGE="Stage 2"
  OUT="${OUT:-$PWD/build/parser-spike}"
fi

echo "== standalone parser Spike (Phase 7 $STAGE) =="
if ! command -v "$SPIKE" >/dev/null 2>&1; then
  echo "ERROR: parser spike not found at '$SPIKE'" >&2
  echo "       (the Nix wrapper builds + exports it; or put a parser 'spike' on PATH)" >&2
  exit 1
fi
echo "== using spike: $(command -v "$SPIKE")"
mkdir -p "$OUT"

# run_spike <elf> <log> — run an ELF on the parser spike, capturing output; sets
# SPIKE_RC to the exit code WITHOUT tripping errexit. tohost=1 => exit 0 (PASS).
# The parser extension is auto-activated by the build (Proc.cc registered_extensions_v),
# so NO --extension flag is passed — adding it would double-register the extension.
run_spike() {
  set +e
  "$SPIKE" "--isa=$ISA" "$1" >"$2" 2>&1
  SPIKE_RC=$?
  set -e
}

# ---- 1. smoke: packet-independent parser ops -------------------------------
echo "== smoke: parser ops (parser_tandem.S) =="
RV_INCLUDES=("$TESTDIR" "$REPO_ROOT/toolchain")
rv_assemble "$OUT/smoke.elf" "$TESTDIR/link.ld" "$TESTDIR/parser_tandem.S"
run_spike "$OUT/smoke.elf" "$OUT/smoke.log"
if [ "$SPIKE_RC" -ne 0 ]; then
  echo "  FAIL: parser_tandem.S did not self-report SUCCESS on the parser spike" >&2
  sed 's/^/      /' "$OUT/smoke.log" | tail -8 >&2
  exit 1
fi
echo "  ok: parser ops execute + self-check on the standalone spike"

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
  echo "== compiling the slice (parser_slice.c, -O2) with: $SLICE_CC $SLICE_CC_EXTRA =="
  SLICE_OBJ="$OUT/parser_slice.o"
  # -fno-stack-protector: the intrinsics path is naked, but also keep the toolchain
  # default canary out so nothing prepends bytes / references __stack_chk_fail. The
  # builtins path (-DPRS_USE_BUILTINS) is non-naked but at -O2 emits no prologue.
  # SLICE_CC_EXTRA is intentionally word-split (a flag list, e.g. clang's --target).
  # shellcheck disable=SC2086
  "$SLICE_CC" $SLICE_CC_EXTRA -march=rv64gc -mabi=lp64d -O2 -Wall -Wextra -Werror -nostdlib \
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
    echo "parser-spike-slice: the C slice does not encode == the model ROM" >&2
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
# spike; PASS iff spike exits 0 (in-core self-check vs the model goldens -> tohost=1).
spike_case() {
  local name="$1" cdir="$4"
  local case_s="$OUT/case_$name.S" elf="$OUT/cosim_$name.elf" log="$OUT/run_$name.log"
  gen_case_s "$cdir" "$case_s"
  RV_INCLUDES=("$TESTDIR" "$REPO_ROOT/toolchain")
  # shellcheck disable=SC2086  # $SLICE_OBJ is one optional path, intentional word-split
  rv_assemble "$elf" "$TESTDIR/link.ld" "$TESTDIR/cosim_main.S" $SLICE_OBJ "$PROG_S" "$case_s"
  run_spike "$elf" "$log"
  [ "$SPIKE_RC" -eq 0 ] && return 0
  mapfile -t CASE_TRIAGE < <(tail -4 "$log" | sed 's/^/      /')
  return 1
}

if [ "$SLICE" = "1" ]; then
  # Overridable so parser-clang-slice (C2) reports its own identity while reusing
  # this body; defaults describe the intrinsics slice (Stage 3).
  SUITE_DESC="${SLICE_SUITE_DESC:-parser-spike-slice: C-intrinsics slice -> flow_keys on the standalone parser Spike}"
  SUITE_TAG="${SLICE_SUITE_TAG:-parser-spike-slice}"
  PASS_MSG="${SLICE_PASS_MSG:-== PASS: the C-intrinsics slice runs on the standalone Spike == the golden model (Stage 3) ==}"
else
  SUITE_DESC="parser-spike: packet -> flow_keys on the standalone parser Spike"
  SUITE_TAG="parser-spike"
  PASS_MSG="== PASS: parser ELFs run on the standalone Spike == the golden model (Stage 2) =="
fi

if run_suite "$OUT/cases.txt" "$OUT/cases" "$SUITE_DESC" "$SUITE_TAG" spike_case; then
  echo "$PASS_MSG"
  exit 0
else
  exit 1
fi
