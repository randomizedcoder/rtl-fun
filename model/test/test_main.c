/*
 * test_main.c — golden-model unit + corpus smoke tests.
 *   nix run .#model-test          (CORPUS_DIR set to the pinned xdp2 pcaps)
 * Exit status 0 = all passed, 1 = failures.
 */
#include "../libparsermodel/parser.h"
#include "../libparsermodel/pcap.h"
#include "test.h"
#include <stdlib.h>
#include <string.h>

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

int main(void)
{
    printf("== libparsermodel tests ==\n");
    RUN(t_extract_subreg);
    RUN(t_slice_ipv4_tcp);
    RUN(t_slice_ipv4_options);
    RUN(t_slice_malformed_bad_version);
    RUN(t_slice_malformed_truncated);
    RUN(t_slice_unknown_proto);
    RUN(t_corpus_tcp);
    RUN(t_corpus_udp);
    RUN(t_corpus_ipv6);

    printf("== %d checks, %d failed ==\n", pm_tests_run, pm_tests_failed);
    return pm_tests_failed ? 1 : 0;
}
