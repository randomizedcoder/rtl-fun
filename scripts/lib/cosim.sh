# scripts/lib/cosim.sh — shared assembly of the parser cosim test vectors.
#
# The `packet -> flow_keys` corpus is fed to the core the same way regardless of
# whether the reference is the golden model (non-tandem `cva6-parser-cosim`) or Spike
# under lock-step (`cva6-parser-tandem` Stage 1c): the model generator emits enc.hex /
# camprog.hex + per-case packet/expected/params.hex (via common.sh's gen_vectors),
# and these helpers turn them into the shared `prog.S` (the parse block + CAM table)
# and a per-case `case.S` (the packet + its expected flow_keys/code). Both drivers
# then link `cosim_main.S + prog.S + case.S`. Kept here in ONE place so the two apps
# cannot drift. Requires common.sh conventions but no functions from it.

# emit_prog_s <out_dir> <prog_s_path>
#   Build the shared prog.S from <out_dir>/enc.hex (parse block) + camprog.hex (CAM
#   table, one packed Accum word per entry) — identical for every case in a suite.
emit_prog_s() {
  local out="$1" prog_s="$2"
  {
    echo '.section .text'
    echo '.globl parse_prog'
    echo '.align 2'
    echo 'parse_prog:'
    while read -r w; do [ -n "$w" ] && echo "    .word 0x$w"; done < "$out/enc.hex"
    echo
    echo '.section .data'
    echo '.globl cam_table'
    echo '.align 3'
    echo 'cam_table:'
    local ncam=0
    while read -r w; do [ -n "$w" ] && { echo "    .dword 0x$w"; ncam=$((ncam+1)); }; done < "$out/camprog.hex"
    echo '.globl cam_count'
    echo 'cam_count:'
    echo "    .dword $ncam"
  } > "$prog_s"
}

# emit_cam_prog_s <out_dir> <prog_s_path>
#   Like emit_prog_s but WITHOUT the parse_prog block — only the CAM table. Used by
#   the Stage-3 C-slice runner (SLICE=1), where parse_prog comes from the compiled
#   parser_slice.o instead of enc.hex, but the CAM data still rides in from the model
#   (camprog.hex). Kept byte-for-byte identical to emit_prog_s's .data half so the
#   two paths cannot drift.
emit_cam_prog_s() {
  local out="$1" prog_s="$2"
  {
    echo '.section .data'
    echo '.globl cam_table'
    echo '.align 3'
    echo 'cam_table:'
    local ncam=0
    while read -r w; do [ -n "$w" ] && { echo "    .dword 0x$w"; ncam=$((ncam+1)); }; done < "$out/camprog.hex"
    echo '.globl cam_count'
    echo 'cam_count:'
    echo "    .dword $ncam"
  } > "$prog_s"
}

# gen_case_s <case_dir> <case_s_path>
#   Emit a per-case case.S: the packet bytes (padded to a multiple of 8; over-read
#   bytes are ignored — the parse is bounded by ParseLen), packet_len, the model's
#   expected flow_keys bytes, expected_len, and the sign-extended expected_code.
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
