#!/usr/bin/env bash
#
# scripts/parser-ctxsw-mid.sh — M1 in-core MID-parse context switch of the parser
# register state (Table C; §3.1 item 4, register half). The genuine mid-parse companion
# to V10's between-parse switch: an async interrupt preempts an in-flight parse, the ISR
# saves / clobbers / restores the resumable position+data registers over the custom-3 ABI,
# and the parse resumes to the model's byte-exact flow_keys.
#
# The *test* half of the `cva6-parser-ctxsw-mid` app; the Nix wrapper
# (nix/parser-ctxsw-mid.nix) prepends the cva6-baseline.sh build body (PATCHED source +
# CVA6_WORK=build/parser-core), so the patched Variane_testharness already exists.
# Preferred entry point:
#
#   nix run .#cva6-parser-ctxsw-mid
#
# It reuses the cosim vector generator (gen_parser_rom --suite): the shared parse block
# (prog.S = parse_prog + cam_table) and one MULTI-node case (case.S = packet/expected/
# expected_code, model-computed). It links tests/cva6-parser/parser_ctxsw_mid.S (MMIO
# driver + bespoke mid-parse ISR) with those and runs on the patched model. A green run
# proves an interrupt-preempted parse, whose parser register context was clobbered then
# restored through the ABI, resumes to the SAME flow_keys as an uninterrupted run — with
# the ISR having actually observed a mid-parse (done==0) preemption.
#
# Inputs (wrapper-provided; dev-shell fallbacks):
#   CVA6_WORK   build dir holding cva6/work-ver/Variane_testharness (build/parser-core)
#   REPO_ROOT   repo root (defaults to $PWD)
#   MID_CASE    which generated case to run (default 01-eth-ipv4-tcp: eth->ipv4->tcp,
#               a multi-node positive parse long enough for a reliable mid-parse landing)
set -euo pipefail

# Shared helpers (gen_vectors, rv_assemble, run_model, model_success). readFile-prepended
# by the Nix wrapper; sourced here when run directly in the dev shell.
if ! declare -F gen_vectors >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
fi

WORK="${CVA6_WORK:-$PWD/build/parser-core}"
BIN="$WORK/cva6/work-ver/Variane_testharness"
TESTDIR="$REPO_ROOT/tests/cva6-parser"
OUT="$WORK/parser-ctxsw-mid"
CASE="${MID_CASE:-01-eth-ipv4-tcp}"
MAXCYC="${MAX_CYCLES:-200000}"

echo "== CVA6 parser M1: a MID-parse context switch must round-trip parser state and resume =="
echo "  model : $BIN"
echo "  test  : $TESTDIR/parser_ctxsw_mid.S   (case $CASE)"

if [ ! -x "$BIN" ]; then
  echo "ERROR: patched model not found at $BIN" >&2
  echo "       (the Nix wrapper builds it first; in the dev shell run 'nix run .#cva6-parser')" >&2
  exit 1
fi
mkdir -p "$OUT"

# ---- 1. generate the vectors from the golden model (whole directed suite) ----
echo "== generating vectors from the model =="
gen_vectors "$OUT" --suite >/dev/null

# ---- 2. shared prog.S: the parse block (executable) + the CAM table (data) ----
PROG_S="$OUT/prog.S"
{
  echo '.section .text'
  echo '.globl parse_prog'
  echo '.align 2'
  echo 'parse_prog:'
  while read -r w; do [ -n "$w" ] && echo "    .word 0x$w"; done < "$OUT/enc.hex"
  echo
  echo '.section .data'
  echo '.globl cam_table'
  echo '.align 3'
  echo 'cam_table:'
  ncam=0
  while read -r w; do [ -n "$w" ] && { echo "    .dword 0x$w"; ncam=$((ncam+1)); }; done < "$OUT/camprog.hex"
  echo '.globl cam_count'
  echo 'cam_count:'
  echo "    .dword $ncam"
} > "$PROG_S"

# ---- 3. case.S for the chosen multi-node packet (same layout cosim uses) ----
CDIR="$OUT/cases/$CASE"
if [ ! -d "$CDIR" ]; then
  echo "ERROR: generated case '$CASE' not found under $OUT/cases" >&2
  exit 1
fi
CASE_S="$OUT/case_$CASE.S"
{
  pkt_len=$(sed -n '1p' "$CDIR/params.hex");  pkt_len=$((16#$pkt_len))
  meta_len=$(sed -n '2p' "$CDIR/params.hex"); meta_len=$((16#$meta_len))
  code_hex=$(sed -n '3p' "$CDIR/params.hex"); code=$((16#$code_hex))
  [ "$code" -ge 2147483648 ] && code=$((code - 4294967296))   # sign-extend 32-bit
  echo '.section .data'
  echo '.globl packet'
  echo '.align 3'
  echo 'packet:'
  awk 'BEGIN{n=0} {printf "    .byte 0x%s\n",$0; n++}
       END{pad=(8-n%8)%8; if(n==0)pad=8; for(i=0;i<pad;i++)print "    .byte 0x00"}' "$CDIR/packet.hex"
  echo '.globl packet_len'
  echo 'packet_len:'
  echo "    .dword $pkt_len"
  echo '.globl expected'
  echo '.align 3'
  echo 'expected:'
  awk '{printf "    .byte 0x%s\n",$0}' "$CDIR/expected.hex"
  echo '.globl expected_len'
  echo 'expected_len:'
  echo "    .dword $meta_len"
  echo '.globl expected_code'
  echo 'expected_code:'
  echo "    .dword $code"
} > "$CASE_S"

# ---- 4. link the driver + shared prog + case, run on the patched model ----
echo "== assembling ELF with $GCC =="
RV_INCLUDES=("$TESTDIR" "$REPO_ROOT/toolchain")   # parser_mmio.h + htif.S
rv_assemble "$OUT/parser_ctxsw_mid.elf" "$TESTDIR/link.ld" \
  "$TESTDIR/parser_ctxsw_mid.S" "$PROG_S" "$CASE_S"

echo "== running on the patched model (max $MAXCYC cycles) =="
LOG="$OUT/parser_ctxsw_mid.log"
run_model "$OUT/parser_ctxsw_mid.elf" "$LOG"
rc=$MODEL_RC
cat "$LOG"

# PASS iff fesvr SUCCESS + rc0: tohost=1 requires flow_keys == model expected AND the
# exit code matched AND an exit was seen AND the interrupt fired AND it landed mid-parse
# (done==0). Fail codes: 3 keys, 5 code, 7 no-exit, 9 no-trap, 11 never-saw-mid-parse.
if model_success "$LOG" && [ "$rc" -eq 0 ]; then
  echo "== PASS: M1 — a mid-parse-preempted parser thread saved/restored its register"
  echo "         context via the custom-3 ABI and resumed to the model's flow_keys =="
  exit 0
else
  echo "== FAIL: M1 — mid-parse save/restore did not resume to the model result (rc=$rc) ==" >&2
  exit 1
fi
