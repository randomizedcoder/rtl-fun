/*
 * test_main.c — golden-model unit + corpus smoke tests.
 *   nix run .#model-test          (CORPUS_DIR set to the pinned xdp2 pcaps)
 * Exit status 0 = all passed, 1 = failures.
 */
#include "../libparsermodel/parser.h"
#include "../libparsermodel/pcap.h"
#include "../libparsermodel/encoding.h"
#include "../../toolchain/parser_insn.h"
#include "test.h"
#include <stdlib.h>
#include <string.h>
#include <dirent.h>

int pm_tests_run = 0, pm_tests_failed = 0;
const char *pm_cur_test = "";

/* ---------------- unit tests: primitives ---------------- */

TEST(t_extract_subreg)
{
    /* value placed at MSB: 0x47 as top byte of a 64-bit reg. */
    uint64_t r = (uint64_t)0x47 << 56;
    EXPECT_EQ(pm_extract_subreg(r, 1, 0), 0x47);   /* byte  Pos0 */
    EXPECT_EQ(pm_extract_subreg(r, 0, 0), 0x4);    /* nibble Pos0 = version */
    EXPECT_EQ(pm_extract_subreg(r, 0, 1), 0x7);    /* nibble Pos1 = IHL */
    uint64_t h = (uint64_t)0x0800 << 48;
    EXPECT_EQ(pm_extract_subreg(h, 2, 0), 0x0800); /* half Pos0 = EtherType */
}

/* ---------------- unit tests: instruction semantics via tiny programs ---- */

/* Build a raw Ethernet+IPv4+L4 frame for directed tests. */
static uint32_t build_v4(uint8_t *b, uint8_t ihl, uint8_t proto,
                         uint32_t src, uint32_t dst, uint16_t sp, uint16_t dp)
{
    memset(b, 0, 128);
    /* eth */
    b[0]=0x02;b[5]=0x02; b[6]=0x02;b[11]=0x01; b[12]=0x08;b[13]=0x00;
    /* ipv4 */
    uint8_t *ip = b + 14;
    ip[0] = 0x40 | (ihl & 0x0f);
    ip[9] = proto;
    ip[12]=src>>24; ip[13]=src>>16; ip[14]=src>>8; ip[15]=src;
    ip[16]=dst>>24; ip[17]=dst>>16; ip[18]=dst>>8; ip[19]=dst;
    uint8_t *l4 = ip + ihl*4;
    l4[0]=sp>>8; l4[1]=sp; l4[2]=dp>>8; l4[3]=dp;
    return (uint32_t)(l4 - b) + 8;
}

/* Build eth + `ntag` VLAN tags (tpids[] outer..inner) + IPv4(IHL5) + L4. */
static uint32_t build_vlan_v4(uint8_t *b, const uint16_t *tpids, int ntag,
                              uint8_t proto, uint16_t sp, uint16_t dp)
{
    memset(b, 0, 256);
    b[0]=0x02;b[5]=0x02; b[6]=0x02;b[11]=0x01;
    uint32_t o = 12;
    for (int i = 0; i < ntag; i++) {          /* each tag: TPID(2) + TCI(2) */
        b[o]=tpids[i]>>8; b[o+1]=tpids[i]; b[o+2]=0x00; b[o+3]=0x01; o += 4;
    }
    b[o++]=0x08; b[o++]=0x00;                  /* L3 EtherType = IPv4 */
    uint8_t *ip = b + o;
    ip[0]=0x45; ip[9]=proto;
    ip[12]=10; ip[15]=1; ip[16]=10; ip[19]=2; /* 10.0.0.1 -> 10.0.0.2 */
    uint8_t *l4 = ip + 20;
    l4[0]=sp>>8; l4[1]=sp; l4[2]=dp>>8; l4[3]=dp;
    return (uint32_t)(l4 - b) + 8;
}

/* Build eth + IPv6 + one extension header + L4.
 * ipv6_nh = IPv6 Next Header (ext-header type); ext_nh = the ext header's own
 * Next Header (the L4 proto). Ext header is 8 bytes (min HBH/routing/frag). */
static uint32_t build_v6_ext(uint8_t *b, uint8_t ipv6_nh, uint8_t ext_nh,
                             uint16_t sp, uint16_t dp)
{
    memset(b, 0, 256);
    b[0]=0x02;b[5]=0x02; b[6]=0x02;b[11]=0x01; b[12]=0x86;b[13]=0xdd;
    uint8_t *ip6 = b + 14;
    ip6[0]=0x60;              /* version 6 */
    ip6[6]=ipv6_nh;          /* Next Header */
    ip6[7]=0x40;             /* hop limit */
    ip6[8]=0x20; ip6[23]=0x01;   /* src ...:0001 (marker in src[0], src[15]) */
    ip6[24]=0x20; ip6[39]=0x02;  /* dst ...:0002 */
    uint8_t *ext = ip6 + 40;     /* @54 */
    ext[0]=ext_nh;               /* ext Next Header = L4 proto */
    ext[1]=0x00;                 /* Hdr Ext Len = 0 -> 8 bytes */
    uint8_t *l4 = ext + 8;       /* @62 */
    l4[0]=sp>>8; l4[1]=sp; l4[2]=dp>>8; l4[3]=dp;
    return (uint32_t)(l4 - b) + 8;
}

TEST(t_slice_ipv4_tcp)
{
    uint8_t pkt[128];
    uint32_t len = build_v4(pkt, 5, 6, 0x0A000001, 0x0A000002, 0x1234, 0x0050);
    struct flow_keys fk; pstate ps;
    pm_init(&ps, pkt, len, &fk);
    size_t n; const instr *prog = pm_slice_program(&n);
    int32_t code = pm_run(&ps, prog, n);

    EXPECT_EQ(code, P_STOP_OKAY);
    EXPECT_EQ(fk.n_proto, 0x0800);
    EXPECT_EQ(fk.addr_type, 4);
    EXPECT_EQ(fk.ip_proto, 6);
    EXPECT_EQ(fk.ipv4_src, 0x0A000001);
    EXPECT_EQ(fk.ipv4_dst, 0x0A000002);
    EXPECT_EQ(fk.sport, 0x1234);
    EXPECT_EQ(fk.dport, 0x0050);
    /* CurHdr advanced eth(14)+ip(20) = 34 before TCP node */
    EXPECT_EQ(ps.cur.off, 34);
}

TEST(t_slice_ipv4_options)  /* IHL=7 -> patent worked-example header geometry */
{
    uint8_t pkt[128];
    uint32_t len = build_v4(pkt, 7, 17, 0x0A000001, 0x0A000002, 1, 2);
    struct flow_keys fk; pstate ps;
    pm_init(&ps, pkt, len, &fk);
    size_t n; const instr *prog = pm_slice_program(&n);
    int32_t code = pm_run(&ps, prog, n);
    EXPECT_EQ(code, P_STOP_OKAY);
    EXPECT_EQ(fk.ip_proto, 17);
    /* IHL=7 => IP header 28 bytes; CurHdr.Offset at L4 = 14 + 28 = 42 */
    EXPECT_EQ(ps.cur.off, 42);
}

TEST(t_slice_malformed_bad_version)
{
    uint8_t pkt[128];
    uint32_t len = build_v4(pkt, 5, 6, 1, 2, 1, 2);
    pkt[14] = 0x65;                 /* version nibble = 6 (not 4), IHL=5 */
    struct flow_keys fk; pstate ps;
    pm_init(&ps, pkt, len, &fk);
    size_t n; const instr *prog = pm_slice_program(&n);
    int32_t code = pm_run(&ps, prog, n);
    EXPECT_EQ(code, P_STOP_FAIL);   /* cmpi .fail on version guard */
}

TEST(t_slice_malformed_truncated)
{
    uint8_t pkt[128];
    uint32_t len = build_v4(pkt, 5, 6, 1, 2, 1, 2);
    struct flow_keys fk; pstate ps;
    pm_init(&ps, pkt, 20, &fk);     /* only 20 bytes present: eth + 6 of IP */
    (void)len;
    size_t n; const instr *prog = pm_slice_program(&n);
    int32_t code = pm_run(&ps, prog, n);
    EXPECT_EQ(code, P_STOP_LENGTH); /* a load or length check runs off the buffer */
}

TEST(t_slice_unknown_proto)
{
    uint8_t pkt[128];
    uint32_t len = build_v4(pkt, 5, 0, 1, 2, 0, 0);  /* proto 0: not in table */
    struct flow_keys fk; pstate ps;
    pm_init(&ps, pkt, len, &fk);
    size_t n; const instr *prog = pm_slice_program(&n);
    int32_t code = pm_run(&ps, prog, n);
    EXPECT_EQ(code, P_STOP_UNKNOWN_PROTO);
    EXPECT_EQ(fk.addr_type, 4);     /* L3 keys still extracted */
    EXPECT_EQ(fk.ipv4_src, 0x00000001);
}

/* ---------------- VLAN (802.1Q / 802.1ad, incl. stacked) ---------------- */

TEST(t_slice_vlan_ipv4_tcp)
{
    uint8_t pkt[256];
    const uint16_t tags[] = { 0x8100 };
    uint32_t len = build_vlan_v4(pkt, tags, 1, 6, 0x1234, 0x0050);
    struct flow_keys fk; pstate ps;
    pm_init(&ps, pkt, len, &fk);
    size_t n; const instr *prog = pm_slice_program(&n);
    int32_t code = pm_run(&ps, prog, n);
    EXPECT_EQ(code, P_STOP_OKAY);
    EXPECT_EQ(fk.n_proto, 0x0800);   /* inner EtherType after unwrapping the tag */
    EXPECT_EQ(fk.ip_proto, 6);
    EXPECT_EQ(fk.sport, 0x1234);
    EXPECT_EQ(fk.dport, 0x0050);
    /* eth(14) + vlan(4) + ip(20) = 38 before TCP */
    EXPECT_EQ(ps.cur.off, 38);
}

TEST(t_slice_qinq_ipv4_udp)  /* stacked S-VLAN + C-VLAN */
{
    uint8_t pkt[256];
    const uint16_t tags[] = { 0x88A8, 0x8100 };
    uint32_t len = build_vlan_v4(pkt, tags, 2, 17, 1, 2);
    struct flow_keys fk; pstate ps;
    pm_init(&ps, pkt, len, &fk);
    size_t n; const instr *prog = pm_slice_program(&n);
    int32_t code = pm_run(&ps, prog, n);
    EXPECT_EQ(code, P_STOP_OKAY);
    EXPECT_EQ(fk.ip_proto, 17);
    /* eth(14) + 2*vlan(8) + ip(20) = 42 before L4 */
    EXPECT_EQ(ps.cur.off, 42);
}

/* ---------------- IPv6 extension headers ---------------- */

TEST(t_slice_ipv6_hbh_tcp)   /* hop-by-hop -> TCP */
{
    uint8_t pkt[256];
    uint32_t len = build_v6_ext(pkt, 0 /*HBH*/, 6 /*TCP*/, 0xABCD, 0x0016);
    struct flow_keys fk; pstate ps;
    pm_init(&ps, pkt, len, &fk);
    size_t n; const instr *prog = pm_slice_program(&n);
    int32_t code = pm_run(&ps, prog, n);
    EXPECT_EQ(code, P_STOP_OKAY);
    EXPECT_EQ(fk.addr_type, 6);
    EXPECT_EQ(fk.ip_proto, 6);        /* ext header chain updated it to L4 */
    EXPECT_EQ(fk.sport, 0xABCD);
    EXPECT_EQ(fk.dport, 0x0016);
    /* eth(14) + ipv6(40) + hbh(8) = 62 before TCP */
    EXPECT_EQ(ps.cur.off, 62);
}

TEST(t_slice_ipv6_fragment_udp)   /* fragment header (fixed 8) -> UDP */
{
    uint8_t pkt[256];
    uint32_t len = build_v6_ext(pkt, 44 /*fragment*/, 17 /*UDP*/, 0x1111, 0x2222);
    struct flow_keys fk; pstate ps;
    pm_init(&ps, pkt, len, &fk);
    size_t n; const instr *prog = pm_slice_program(&n);
    int32_t code = pm_run(&ps, prog, n);
    EXPECT_EQ(code, P_STOP_OKAY);
    EXPECT_EQ(fk.addr_type, 6);
    EXPECT_EQ(fk.ip_proto, 17);
    EXPECT_EQ(fk.sport, 0x1111);
    EXPECT_EQ(fk.dport, 0x2222);
    EXPECT_EQ(ps.cur.off, 62);
}

/* ---------------- malformed / adversarial (§2.3): no crash, no hang ------- */

TEST(t_mal_ipv4_ihl0)             /* IHL below minimum */
{
    uint8_t pkt[128];
    uint32_t len = build_v4(pkt, 5, 6, 1, 2, 1, 2);
    pkt[14] = 0x40;                /* version 4, IHL 0 */
    struct flow_keys fk; pstate ps;
    pm_init(&ps, pkt, len, &fk);
    size_t n; const instr *prog = pm_slice_program(&n);
    EXPECT_EQ(pm_run(&ps, prog, n), P_STOP_LENGTH);  /* lensetmin min guard */
}

TEST(t_mal_ipv4_ihl15_truncated)  /* header claims 60B, packet is short */
{
    uint8_t pkt[128];
    (void)build_v4(pkt, 5, 6, 1, 2, 1, 2);
    pkt[14] = 0x4F;               /* version 4, IHL 15 -> 60-byte header */
    struct flow_keys fk; pstate ps;
    pm_init(&ps, pkt, 30, &fk);   /* only 30 bytes present */
    size_t n; const instr *prog = pm_slice_program(&n);
    EXPECT_EQ(pm_run(&ps, prog, n), P_STOP_LENGTH);
}

TEST(t_mal_ipv6_ext_past_eof)     /* ext header length runs off the buffer */
{
    uint8_t pkt[256];
    uint32_t len = build_v6_ext(pkt, 0 /*HBH*/, 6, 0, 0);
    pkt[55] = 0xFF;               /* Hdr Ext Len = 255 -> claims 2048 bytes */
    struct flow_keys fk; pstate ps;
    pm_init(&ps, pkt, len, &fk);
    size_t n; const instr *prog = pm_slice_program(&n);
    EXPECT_EQ(pm_run(&ps, prog, n), P_STOP_LENGTH);
    EXPECT_EQ(fk.addr_type, 6);   /* L3 still extracted before the bad ext hdr */
}

TEST(t_mal_vlan_stack_overflow)   /* absurd VLAN nesting -> node-count guard */
{
    uint8_t pkt[512];
    memset(pkt, 0, sizeof(pkt));
    pkt[0]=0x02;pkt[5]=0x02;pkt[6]=0x02;pkt[11]=0x01;
    uint32_t o = 12;
    for (int i = 0; i < 40; i++) {           /* 40 stacked 0x8100 tags */
        pkt[o]=0x81; pkt[o+1]=0x00; pkt[o+2]=0x00; pkt[o+3]=0x01; o += 4;
    }
    pkt[o]=0x08; pkt[o+1]=0x00;              /* finally IPv4 (never reached) */
    struct flow_keys fk; pstate ps;
    pm_init(&ps, pkt, o + 2 + 20, &fk);
    size_t n; const instr *prog = pm_slice_program(&n);
    EXPECT_EQ(pm_run(&ps, prog, n), P_STOP_MAX_NODES);
}

/* ---------------- instruction encoding (Phase 3) ---------------- */

TEST(t_enc_framing)   /* opcode + Fnc4 land in the right bits for each group */
{
    EXPECT_EQ(prs_opcode(prs_load_b(0)),  PRS_OP_C0);
    EXPECT_EQ(prs_fnc4(prs_load_b(0)),    FNC4_LOAD);
    EXPECT_EQ(prs_fnc4(prs_lencur_const(20)), FNC4_LEN);
    EXPECT_EQ(prs_fnc4(prs_store(2, 0, 0)),   FNC4_STORE);
    EXPECT_EQ(prs_fnc4(prs_storeimm(1, 4, 3)),FNC4_STOREIMM);
    EXPECT_EQ(prs_fnc4(prs_camnext(1, 0, 1, 2)), FNC4_CAM);
    EXPECT_EQ(prs_fnc4(prs_cmpib(0, 0x40, 0xF0, 3)), FNC4_CMPIB);
    EXPECT_EQ(prs_fnc4(prs_nextnode(0)),  FNC4_NEXT);
    EXPECT_EQ(prs_opcode(prs_mv_x_p(5, 1)), PRS_OP_C3);
}

TEST(t_enc_golden)    /* hand-derived words from the recovered bit ranges */
{
    /* PLOAD .h off=12: Sz=2[29:28], E=1[20], Offset=12[19:11], Fnc4=0, Op=0x0b.
     * 0x20000000 | 0x00100000 | (12<<11) | 0x0b = 0x2010600b */
    EXPECT_EQ(prs_load_h(12), 0x2010600bu);
    /* PLOAD .b off=0: Sz=1[29:28] -> 0x10000000 | 0x0b */
    EXPECT_EQ(prs_load_b(0), 0x1000000bu);
    /* PSTOREIMM addr_type: Sz=1, Value=4[27:20], Offset=3[19:11]
     * 0x10000000 | (4<<20) | (3<<11) | Fnc4(6)<<7 | 0x0b */
    EXPECT_EQ(prs_storeimm(1, 4, 3),
              0x10000000u | (4u<<20) | (3u<<11) | (6u<<7) | 0x0bu);
}

TEST(t_enc_roundtrip)  /* pack -> extract each field -> compare (every group) */
{
    uint32_t w;

    w = prs_enc_load(1, 0, 3, 5, 6, 1, 0x1AB);
    EXPECT_EQ(prs_get(w,31,31),1); EXPECT_EQ(prs_get(w,29,28),3);
    EXPECT_EQ(prs_get(w,27,24),5); EXPECT_EQ(prs_get(w,23,21),6);
    EXPECT_EQ(prs_get(w,20,20),1); EXPECT_EQ(prs_get(w,19,11),0x1AB);

    w = prs_enc_len(1, 1, 2, 9, 3, 2, 0x7E);
    EXPECT_EQ(prs_get(w,31,31),1); EXPECT_EQ(prs_get(w,30,30),1);
    EXPECT_EQ(prs_get(w,29,28),2); EXPECT_EQ(prs_get(w,27,24),9);
    EXPECT_EQ(prs_get(w,23,21),3); EXPECT_EQ(prs_get(w,20,19),2);
    EXPECT_EQ(prs_get(w,18,11),0x7E);

    w = prs_enc_store(1, 1, 2, 6, 1, 5, 0x1CD);
    EXPECT_EQ(prs_get(w,30,30),1); EXPECT_EQ(prs_get(w,27,24),6);
    EXPECT_EQ(prs_get(w,23,23),1); EXPECT_EQ(prs_get(w,22,20),5);
    EXPECT_EQ(prs_get(w,19,11),0x1CD);

    w = prs_enc_cam(1, 1, 1, 0, 0, 1, 3, 2);
    EXPECT_EQ(prs_get(w,30,30),1); EXPECT_EQ(prs_get(w,20,20),1);
    EXPECT_EQ(prs_get(w,19,16),3); EXPECT_EQ(prs_get(w,15,11),2);

    w = prs_enc_cmpord(1, 0, 1, 2, 3, 2, 0x55);
    EXPECT_EQ(prs_get(w,23,21),3); EXPECT_EQ(prs_get(w,20,19),2);
    EXPECT_EQ(prs_get(w,18,11),0x55);

    w = prs_enc_cmpib(3, 5, 0xA5, 0x0F);
    EXPECT_EQ(prs_get(w,31,30),3); EXPECT_EQ(prs_get(w,29,27),5);
    EXPECT_EQ(prs_get(w,26,19),0xA5); EXPECT_EQ(prs_get(w,18,11),0x0F);

    w = prs_enc_cop(17, 0, 0, 1, 0, 9, 1, 0);   /* CPPRSWRCAM-ish */
    EXPECT_EQ(prs_opcode(w), PRS_OP_C3);
    EXPECT_EQ(prs_get(w,31,29),0); EXPECT_EQ(prs_get(w,28,24),17);
    EXPECT_EQ(prs_get(w,19,15),9); EXPECT_EQ(prs_get(w,14,12),1);
}

TEST(t_enc_model_program)  /* every 32-bit instr in the slice encodes + decodes */
{
    size_t n; const instr *prog = pm_slice_program(&n);
    int encoded = 0;
    for (size_t i = 0; i < n; i++) {
        uint32_t w;
        if (pm_encode(&prog[i], &w) != 0) continue;   /* no 32-bit form (none here) */
        encoded++;
        EXPECT_EQ(prs_opcode(w), PRS_OP_C0);
        enum opcode back = pm_decode_opcode(w);
        /* Every slice op round-trips exactly, including PSTP (Pos=10, V=1,
         * distinct from PSETCODE V=0) — so a decoded program executes like the
         * model's decoded-instruction table (rtl/parser_decode.sv relies on this). */
        EXPECT_EQ(back, prog[i].op);
        /* Loads must round-trip their Sz + Offset through the bit field. */
        if (prog[i].op == OP_LOAD) {
            EXPECT_EQ(prs_get(w, 29, 28), prog[i].sz);
            EXPECT_EQ(prs_get(w, 19, 11), prog[i].offset);
        }
    }
    EXPECT(encoded > 30);   /* the slice has 40+ encodable instructions */
}

/* ---------------- corpus smoke tests: pinned xdp2 pcap_templates ---------- */

static int run_pcap(const char *dir, const char *name, struct flow_keys *fk, int32_t *code)
{
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    uint8_t pkt[2048]; uint32_t lt = 0;
    int len = pcap_read_first(path, pkt, sizeof(pkt), &lt);
    if (len <= 0) return len;
    if (lt != 1) return -100;        /* expect Ethernet framing */
    pstate ps;
    pm_init(&ps, pkt, (uint32_t)len, fk);
    size_t n; const instr *prog = pm_slice_program(&n);
    *code = pm_run(&ps, prog, n);
    return len;
}

TEST(t_corpus_tcp)
{
    const char *dir = getenv("CORPUS_DIR");
    if (!dir) { printf("  SKIP [t_corpus_tcp] CORPUS_DIR unset\n"); return; }
    struct flow_keys fk; int32_t code;
    int len = run_pcap(dir, "tcp.pcap", &fk, &code);
    EXPECT(len > 0);
    if (len <= 0) return;
    EXPECT_EQ(code, P_STOP_OKAY);
    EXPECT_EQ(fk.n_proto, 0x0800);
    EXPECT_EQ(fk.ip_proto, 6);
    EXPECT_EQ(fk.addr_type, 4);
    EXPECT_EQ(fk.ipv4_src, 0x0A000001);  /* 10.0.0.1 */
    EXPECT_EQ(fk.ipv4_dst, 0x0A000002);  /* 10.0.0.2 */
}

TEST(t_corpus_udp)
{
    const char *dir = getenv("CORPUS_DIR");
    if (!dir) { printf("  SKIP [t_corpus_udp] CORPUS_DIR unset\n"); return; }
    struct flow_keys fk; int32_t code;
    int len = run_pcap(dir, "udp.pcap", &fk, &code);
    EXPECT(len > 0);
    if (len <= 0) return;
    EXPECT_EQ(code, P_STOP_OKAY);
    EXPECT_EQ(fk.ip_proto, 17);
    EXPECT_EQ(fk.addr_type, 4);
}

TEST(t_corpus_ipv6)
{
    const char *dir = getenv("CORPUS_DIR");
    if (!dir) { printf("  SKIP [t_corpus_ipv6] CORPUS_DIR unset\n"); return; }
    struct flow_keys fk; int32_t code;
    int len = run_pcap(dir, "ipv6.pcap", &fk, &code);
    EXPECT(len > 0);
    if (len <= 0) return;
    EXPECT_EQ(fk.n_proto, 0x86DD);
    EXPECT_EQ(fk.addr_type, 6);
    /* upper proto may or may not be in our table; L3 must be extracted */
}

TEST(t_corpus_vlan)   /* eth + 802.1Q tag, inner EtherType 0x0000 (unknown) */
{
    const char *dir = getenv("CORPUS_DIR");
    if (!dir) { printf("  SKIP [t_corpus_vlan] CORPUS_DIR unset\n"); return; }
    struct flow_keys fk; int32_t code;
    int len = run_pcap(dir, "vlan.pcap", &fk, &code);
    EXPECT(len > 0);
    if (len <= 0) return;
    EXPECT_EQ(code, P_STOP_UNKNOWN_PROTO);  /* recognised the tag, inner unknown */
}

TEST(t_corpus_qinq)   /* eth + 802.1ad tag */
{
    const char *dir = getenv("CORPUS_DIR");
    if (!dir) { printf("  SKIP [t_corpus_qinq] CORPUS_DIR unset\n"); return; }
    struct flow_keys fk; int32_t code;
    int len = run_pcap(dir, "qinq.pcap", &fk, &code);
    EXPECT(len > 0);
    if (len <= 0) return;
    EXPECT_EQ(code, P_STOP_UNKNOWN_PROTO);
}

TEST(t_corpus_ipv6_fragment)   /* IPv6 -> fragment header -> no-next -> OKAY */
{
    const char *dir = getenv("CORPUS_DIR");
    if (!dir) { printf("  SKIP [t_corpus_ipv6_fragment] CORPUS_DIR unset\n"); return; }
    struct flow_keys fk; int32_t code;
    int len = run_pcap(dir, "ipv6_fragment.pcap", &fk, &code);
    EXPECT(len > 0);
    if (len <= 0) return;
    EXPECT_EQ(code, P_STOP_OKAY);
    EXPECT_EQ(fk.addr_type, 6);
}

TEST(t_corpus_ipv6_routing)    /* IPv6 -> routing header -> no-next -> OKAY */
{
    const char *dir = getenv("CORPUS_DIR");
    if (!dir) { printf("  SKIP [t_corpus_ipv6_routing] CORPUS_DIR unset\n"); return; }
    struct flow_keys fk; int32_t code;
    int len = run_pcap(dir, "ipv6_routing.pcap", &fk, &code);
    EXPECT(len > 0);
    if (len <= 0) return;
    EXPECT_EQ(code, P_STOP_OKAY);
    EXPECT_EQ(fk.addr_type, 6);
}

TEST(t_corpus_ipv6_hopbyhop)   /* chain walks; ends off-buffer -> clean STOP_LENGTH */
{
    const char *dir = getenv("CORPUS_DIR");
    if (!dir) { printf("  SKIP [t_corpus_ipv6_hopbyhop] CORPUS_DIR unset\n"); return; }
    struct flow_keys fk; int32_t code;
    int len = run_pcap(dir, "ipv6_hopbyhop.pcap", &fk, &code);
    EXPECT(len > 0);
    if (len <= 0) return;
    EXPECT(code < 0);              /* terminated cleanly with a parser code */
    EXPECT_EQ(fk.addr_type, 6);    /* L3 extracted before the chain ran out */
}

/* Robustness sweep: run EVERY Ethernet pcap in the corpus and require each to
 * terminate with a valid parser code — no crash, no hang (the loop guard bounds
 * runtime). This is the §2.3 "entire corpus, no crashes/hangs" exit criterion;
 * it does not assert per-protocol flow_keys (most of the 378 aren't modelled). */
TEST(t_corpus_all_terminate)
{
    const char *dir = getenv("CORPUS_DIR");
    if (!dir) { printf("  SKIP [t_corpus_all_terminate] CORPUS_DIR unset\n"); return; }
    DIR *d = opendir(dir);
    EXPECT(d != NULL);
    if (!d) return;

    int files = 0, eth = 0, okay = 0, unknown = 0, length = 0, other = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        size_t l = strlen(e->d_name);
        if (l < 6 || strcmp(e->d_name + l - 5, ".pcap") != 0) continue;
        files++;
        struct flow_keys fk; int32_t code;
        int len = run_pcap(dir, e->d_name, &fk, &code);
        if (len == -100) continue;      /* not Ethernet-framed: out of scope */
        if (len <= 0) continue;         /* unreadable capture: skip */
        eth++;
        EXPECT(code < 0);               /* MUST terminate with a parser code */
        if      (code == P_STOP_OKAY)          okay++;
        else if (code == P_STOP_UNKNOWN_PROTO) unknown++;
        else if (code == P_STOP_LENGTH)        length++;
        else                                   other++;
    }
    closedir(d);
    printf("  corpus sweep: %d pcaps, %d ethernet -> okay=%d unknown=%d length=%d other=%d\n",
           files, eth, okay, unknown, length, other);
    EXPECT(eth > 100);                  /* sanity: we actually swept the corpus */
}

int main(void)
{
    printf("== libparsermodel tests ==\n");
    RUN(t_extract_subreg);
    RUN(t_slice_ipv4_tcp);
    RUN(t_slice_ipv4_options);
    RUN(t_slice_malformed_bad_version);
    RUN(t_slice_malformed_truncated);
    RUN(t_slice_unknown_proto);
    RUN(t_slice_vlan_ipv4_tcp);
    RUN(t_slice_qinq_ipv4_udp);
    RUN(t_slice_ipv6_hbh_tcp);
    RUN(t_slice_ipv6_fragment_udp);
    RUN(t_mal_ipv4_ihl0);
    RUN(t_mal_ipv4_ihl15_truncated);
    RUN(t_mal_ipv6_ext_past_eof);
    RUN(t_mal_vlan_stack_overflow);
    RUN(t_enc_framing);
    RUN(t_enc_golden);
    RUN(t_enc_roundtrip);
    RUN(t_enc_model_program);
    RUN(t_corpus_tcp);
    RUN(t_corpus_udp);
    RUN(t_corpus_ipv6);
    RUN(t_corpus_vlan);
    RUN(t_corpus_qinq);
    RUN(t_corpus_ipv6_fragment);
    RUN(t_corpus_ipv6_routing);
    RUN(t_corpus_ipv6_hopbyhop);
    RUN(t_corpus_all_terminate);

    printf("== %d checks, %d failed ==\n", pm_tests_run, pm_tests_failed);
    return pm_tests_failed ? 1 : 0;
}
