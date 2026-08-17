#!/usr/bin/env bash
#
# scripts/cva6-parser-cosim.sh — table-driven in-core co-simulation of the parser FU
# against the golden model, over REAL MMIO (increment I5; gaps G5/G9).
#
# The `cva6-parser-cosim` app's test half; the Nix wrapper (nix/cva6-parser-cosim.nix)
# prepends the cva6-baseline.sh build body (PATCHED source, CVA6_WORK=build/parser-core)
# so the patched Variane_testharness already exists. Preferred entry point:
#
#   nix run .#cva6-parser-cosim
#
# For every packet in the directed suite it:
#   1. generates the vectors from the model (gen_parser_rom --suite): the slice
#      PROGRAM (enc.hex, one custom-0 word per node), the CAM (camprog.hex, packed
#      Accum words), and per-case packet/expected/params.hex + cases.txt
#   2. builds a bare-metal ELF = cosim_main.S (fixed driver) + prog.S (parse_prog +
#      cam_table, shared) + case.S (this packet + its expected flow_keys/code)
#   3. runs it on the patched model: the driver `sd`s the packet in over MMIO, sets
#      ParseLen + the exit-landing PC, programs the CAM, jumps into the parse block;
#      the FU walks the graph via end-of-node redirects and returns on exit; the
#      driver `ld`s the committed flow_keys + exit status back and compares to the
#      model, encoding PASS/FAIL into tohost.
#
# A green run proves the WHOLE in-core chain end to end on real packets:
# fetch->decode->issue->EX(parse walk + CAM + redirect + metadata commit)->retire,
# with flow_keys matching the model BYTE-FOR-BYTE — the first true in-core cosim.
#
# Inputs (wrapper-provided; dev-shell fallbacks):
#   CVA6_WORK   build dir holding cva6/work-ver/Variane_testharness (build/parser-core)
#   REPO_ROOT   repo root (defaults to $PWD)
#
set -euo pipefail

# Shared helpers (REPO_ROOT/MODEL/GCC + gen_vectors, rv_assemble, run_model, and
# the suite driver). readFile-prepended by the Nix wrapper; sourced here when run
# directly.
if ! declare -F gen_vectors >/dev/null 2>&1; then
  _lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
  # shellcheck source=/dev/null
  . "$_lib/common.sh"
  # shellcheck source=/dev/null
  . "$_lib/suite.sh"
fi

WORK="${CVA6_WORK:-$PWD/build/parser-core}"
BIN="$WORK/cva6/work-ver/Variane_testharness"
TESTDIR="$REPO_ROOT/tests/cva6-parser"
OUT="$WORK/parser-cosim"
MAXCYC="${MAX_CYCLES:-200000}"

echo "== CVA6 parser in-core co-simulation (I5) =="
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

# emit a per-case case.S (packet + expected flow_keys + expected code) into $1
gen_case_s() {
  local cdir="$1" out="$2"
  local pkt_len meta_len code_hex code
  pkt_len=$(sed -n '1p' "$cdir/params.hex");  pkt_len=$((16#$pkt_len))
  meta_len=$(sed -n '2p' "$cdir/params.hex"); meta_len=$((16#$meta_len))
  code_hex=$(sed -n '3p' "$cdir/params.hex"); code=$((16#$code_hex))
  [ "$code" -ge 2147483648 ] && code=$((code - 4294967296))   # sign-extend 32-bit
  {
    echo '.section .data'
    echo '.globl packet'
    echo '.align 3'
    echo 'packet:'
    # packet bytes, padded up to a multiple of 8 (over-read bytes are ignored: the
    # parse is bounded by ParseLen). An empty packet still gets one zero word.
    awk 'BEGIN{n=0} {printf "    .byte 0x%s\n",$0; n++}
         END{pad=(8-n%8)%8; if(n==0)pad=8; for(i=0;i<pad;i++)print "    .byte 0x00"}' "$cdir/packet.hex"
    echo '.globl packet_len'
    echo 'packet_len:'
    echo "    .dword $pkt_len"
    echo '.globl expected'
    echo '.align 3'
    echo 'expected:'
    awk '{printf "    .byte 0x%s\n",$0}' "$cdir/expected.hex"
    echo '.globl expected_len'
    echo 'expected_len:'
    echo "    .dword $meta_len"
    echo '.globl expected_code'
    echo 'expected_code:'
    echo "    .dword $code"
  } > "$out"
}

# ---- 3. per-case: build the ELF, run it, check tohost (via run_suite) ----
# For each case: emit case.S, link cosim_main.S + prog.S + case.S, run on the
# model; PASS iff SUCCESS banner AND rc0. On FAIL surface the tohost/last lines.
cosim_case() {
  local name="$1" cdir="$4"
  local case_s="$OUT/case_$name.S" elf="$OUT/cosim_$name.elf" log="$OUT/run_$name.log"
  gen_case_s "$cdir" "$case_s"
  RV_INCLUDES=("$TESTDIR" "$REPO_ROOT/toolchain")
  rv_assemble "$elf" "$TESTDIR/link.ld" "$TESTDIR/cosim_main.S" "$PROG_S" "$case_s"
  run_model "$elf" "$log"
  if model_success "$log" && [ "$MODEL_RC" -eq 0 ]; then
    return 0
  fi
  # surface the tohost value (fail code) + last lines for triage
  mapfile -t CASE_TRIAGE < <(grep -E "tohost|SUCCESS|FAIL|max-cycles" "$log" | sed 's/^/      /' | tail -4)
  return 1
}

if run_suite "$OUT/cases.txt" "$OUT/cases" \
    "parser in-core cosim (MMIO packet feed -> flow_keys readback)" \
    "parser cosim" cosim_case; then
  echo "== PASS: in-core packet->flow_keys equivalence vs the golden model (I5) =="
  exit 0
else
  exit 1
fi
