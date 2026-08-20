/*
 * parser_slice.c — the Phase-0 vertical-slice parser, authored in C with the
 * generated parser intrinsics (Phase 7 Stage 3).
 *
 * This is the exit-criterion deliverable for the Spike leg: the slice that
 * model/libparsermodel/program.c holds as a decoded-instruction table is here
 * written as ordinary C, one PRS_EMIT(prs_*(...)) per instruction, using the
 * drift-checked builders in toolchain/generated/parser_intrinsics.h. Compiled
 * -O2 (so the static-inline builders fold to the `.insn 4` constant the "i"
 * constraint requires) and linked with tests/cva6-parser/cosim_main.S, it runs
 * on the standalone parser Spike (nix run .#parser-spike-slice) over the 22-case
 * corpus, self-checking against the golden model.
 *
 * FIDELITY: `parse_prog` must be BYTE-IDENTICAL to the model-generated ROM
 * (enc.hex) — the parser FU steers the hart PC purely PC-relative
 * (nix/spike-tandem/parser_ext.cc: redirect = pc + ((next_pc - cur) << 2), no
 * base register), so a CAM `target` naming node index N redirects the hart to
 * `parse_prog + N*4`. Therefore the 53 words MUST stay contiguous, in program.c
 * order, with the entry symbol on word 0. The runner's parity guard disassembles
 * this .o and diffs the 53 words against enc.hex — that diff is the convergence
 * oracle for the hand field-mapping below, and it also proves this C authoring
 * encodes exactly what the model does.
 *
 * The CAM table (share/match/target triples) stays model-generated (it is data,
 * not parser logic); cosim_main.S programs it from a cam-only prog.S. Only the
 * instruction stream is authored here.
 */
#include "generated/parser_intrinsics.h"   /* -I $REPO_ROOT/toolchain          */
#include "libparsermodel/parser.h"          /* -I $REPO_ROOT/model : flow_keys  */

/* flow_keys sub-register byte offsets — reuse the model's struct so a layout
 * change can never silently desync this slice from the golden model. */
#define OFF(field) ((unsigned)offsetof(struct flow_keys, field))

/*
 * Raw encoded field values (the intrinsics take BITS, program.c uses enums).
 * Kept in step with model/libparsermodel/{program.c Sz #defines, parser.h}.
 */
#define SZ_B   1u   /* byte   */
#define SZ_H   2u   /* half   */
#define SZ_W   3u   /* word   */
#define SZ_N   0u   /* nibble (sub-register extract, LENCUR)   */
#define SZ_DW  0u   /* 8 bytes (load/store)                    */

#define MISS_STOP 2u   /* parser.h enum miss_action MISS_STOP  */
#define ER_FAIL   3u   /* parser.h enum er_action   ER_FAIL    */

/*
 * Node start indices ("addresses") — MUST match model/libparsermodel/program.c
 * (the CAM targets below reference these as word offsets into parse_prog). Kept
 * here only as documentation of the layout the emit order produces; the byte
 * parity guard vs enc.hex is what actually enforces it.
 *
 *   N_ETHER=0  N_IPV4=3  N_IPV6=14  N_TCP=27  N_UDP=32
 *   N_VLAN=37  N_IP6EXT=41  N_IP6FRAG=47  N_DONE=52
 */

/*
 * parse_prog — the 53-word slice. A NAKED function so the emitted bytes are
 * EXACTLY these 53 `.insn 4` words, in source order, entry on word 0 — no
 * prologue/epilogue (the cross-gcc otherwise emits a stack-protector frame that
 * would prepend bytes) and no trailing `ret`. This is required: the parser FU
 * steers the hart PC PC-relative by node index (parser_ext.cc), so word offset i
 * must equal node index i with nothing before word 0. Naked is safe here because
 * every PRS_EMIT is a pure `.insn 4, <imm>` with an "i" (immediate) operand only —
 * no register operands/clobbers/outputs, so nothing needs a frame. The parse never
 * falls off the end: it exits via OP_STP / a redirect back to `parse_done`
 * (cosim_main.S). `used` pins the symbol; cosim_main.S jumps to it. The runner
 * compiles this with -fno-stack-protector as belt-and-suspenders.
 */
__attribute__((used, naked))
void parse_prog(void)
{
    /* ---- ether_node @0 ---- */
    PRS_EMIT(prs_load(SZ_H, 1, 12));                  /* [0]  EtherType -> Accum        */
    PRS_EMIT(prs_store(SZ_H, 0, OFF(n_proto)));       /* [1]  -> flow_keys.n_proto      */
    PRS_EMIT(prs_camnext(1, SZ_H, 0, 0, 1, MISS_STOP)); /* [2] eth_tbl (share 1)        */

    /* ---- ipv4_node @3 ---- */
    PRS_EMIT(prs_load(SZ_B, 0, 0));                   /* [3]  version+IHL byte          */
    PRS_EMIT(prs_lencur(1, SZ_N, 1, 2, 20));          /* [4]  CurHdr.Length = IHL*4,>=20 */
    PRS_EMIT(prs_cmpib(ER_FAIL, 0, 0x40, 0xF0));      /* [5]  version == 4              */
    PRS_EMIT(prs_load(SZ_W, 1, 12));                  /* [6]  src addr                  */
    PRS_EMIT(prs_store(SZ_W, 0, OFF(ipv4_src)));      /* [7]                            */
    PRS_EMIT(prs_load(SZ_W, 1, 16));                  /* [8]  dst addr                  */
    PRS_EMIT(prs_store(SZ_W, 0, OFF(ipv4_dst)));      /* [9]                            */
    PRS_EMIT(prs_storeimm(SZ_B, 4, OFF(addr_type)));  /* [10] addr_type = 4             */
    PRS_EMIT(prs_load(SZ_B, 0, 9));                   /* [11] IP protocol               */
    PRS_EMIT(prs_store(SZ_B, 0, OFF(ip_proto)));      /* [12]                           */
    PRS_EMIT(prs_camnext(1, SZ_B, 0, 0, 2, MISS_STOP)); /* [13] proto_tbl (share 2)     */

    /* ---- ipv6_node @14 (fixed 40-byte header; ext headers via ip6nh_tbl) ---- */
    PRS_EMIT(prs_lencur(0, 0, 0, 7, 40));             /* [14] constant length 40        */
    PRS_EMIT(prs_storeimm(SZ_B, 6, OFF(addr_type)));  /* [15] addr_type = 6             */
    PRS_EMIT(prs_load(SZ_DW, 0, 8));                  /* [16] src[0..7]                 */
    PRS_EMIT(prs_store(SZ_DW, 0, OFF(ipv6_src)));     /* [17]                           */
    PRS_EMIT(prs_load(SZ_DW, 0, 16));                 /* [18] src[8..15]                */
    PRS_EMIT(prs_store(SZ_DW, 0, OFF(ipv6_src) + 8)); /* [19]                           */
    PRS_EMIT(prs_load(SZ_DW, 0, 24));                 /* [20] dst[0..7]                 */
    PRS_EMIT(prs_store(SZ_DW, 0, OFF(ipv6_dst)));     /* [21]                           */
    PRS_EMIT(prs_load(SZ_DW, 0, 32));                 /* [22] dst[8..15]                */
    PRS_EMIT(prs_store(SZ_DW, 0, OFF(ipv6_dst) + 8)); /* [23]                           */
    PRS_EMIT(prs_load(SZ_B, 0, 6));                   /* [24] Next Header               */
    PRS_EMIT(prs_store(SZ_B, 0, OFF(ip_proto)));      /* [25]                           */
    PRS_EMIT(prs_camnext(1, SZ_B, 0, 0, 3, MISS_STOP)); /* [26] ip6nh_tbl (share 3)     */

    /* ---- tcp_node @27 ---- */
    PRS_EMIT(prs_load(SZ_H, 1, 0));                   /* [27] sport                     */
    PRS_EMIT(prs_store(SZ_H, 0, OFF(sport)));         /* [28]                           */
    PRS_EMIT(prs_load(SZ_H, 1, 2));                   /* [29] dport                     */
    PRS_EMIT(prs_store(SZ_H, 0, OFF(dport)));         /* [30]                           */
    PRS_EMIT(prs_stp());                              /* [31] no Next -> STOP_OKAY      */

    /* ---- udp_node @32 ---- */
    PRS_EMIT(prs_load(SZ_H, 1, 0));                   /* [32] sport                     */
    PRS_EMIT(prs_store(SZ_H, 0, OFF(sport)));         /* [33]                           */
    PRS_EMIT(prs_load(SZ_H, 1, 2));                   /* [34] dport                     */
    PRS_EMIT(prs_store(SZ_H, 0, OFF(dport)));         /* [35]                           */
    PRS_EMIT(prs_stp());                              /* [36]                           */

    /* ---- vlan_node @37 (802.1Q/802.1ad; loops back through eth_tbl) ---- */
    PRS_EMIT(prs_load(SZ_H, 1, 2));                   /* [37] inner EtherType           */
    PRS_EMIT(prs_store(SZ_H, 0, OFF(n_proto)));       /* [38]                           */
    PRS_EMIT(prs_lencur(0, 0, 0, 7, 4));              /* [39] tag remainder = 4 bytes   */
    PRS_EMIT(prs_camnext(1, SZ_H, 0, 0, 1, MISS_STOP)); /* [40] eth_tbl (share 1)       */

    /* ---- ip6ext_node @41 (HBH / routing / dest-opts: len = (ExtLen+1)*8) ---- */
    PRS_EMIT(prs_load(SZ_B, 0, 0));                   /* [41] Next Header               */
    PRS_EMIT(prs_store(SZ_B, 0, OFF(ip_proto)));      /* [42] track final proto         */
    PRS_EMIT(prs_load(SZ_B, 0, 1));                   /* [43] Hdr Ext Len               */
    PRS_EMIT(prs_lencur(0, SZ_B, 0, 3, 8));           /* [44] (ExtLen<<3)+8             */
    PRS_EMIT(prs_load(SZ_B, 0, 0));                   /* [45] reload NH for CAM key     */
    PRS_EMIT(prs_camnext(1, SZ_B, 0, 0, 3, MISS_STOP)); /* [46] ip6nh_tbl (share 3)     */

    /* ---- ip6frag_node @47 (fragment header: fixed 8 bytes) ---- */
    PRS_EMIT(prs_load(SZ_B, 0, 0));                   /* [47] Next Header               */
    PRS_EMIT(prs_store(SZ_B, 0, OFF(ip_proto)));      /* [48]                           */
    PRS_EMIT(prs_lencur(0, 0, 0, 7, 8));              /* [49] constant length 8         */
    PRS_EMIT(prs_load(SZ_B, 0, 0));                   /* [50] reload NH for CAM key     */
    PRS_EMIT(prs_camnext(1, SZ_B, 0, 0, 3, MISS_STOP)); /* [51] ip6nh_tbl (share 3)     */

    /* ---- done_node @52 ("no next header") ---- */
    PRS_EMIT(prs_stp());                              /* [52] clean STOP_OKAY           */
}
