/*
 * gen_parser_rom.c — generate the RTL test vectors from the golden model.
 *
 * The RTL parser unit runs the SAME decoded program the C model runs. Rather
 * than hand-keep a second copy, this tool reuses libparsermodel's slice program
 * (pm_slice_program) and, for the Verilator testbench (parser_smoke_tb.sv),
 * emits the program + CAM once and then, per test packet, the packet bytes, the
 * model's resulting flow_keys, and the expected exit code:
 *
 *   program.hex     one 96-bit micro-op word per instruction (parser_pkg layout)
 *   cam.hex         CAM entries {valid, share, match, target} referenced above
 *   packet.hex      the packet under test, one byte per line
 *   expected.hex    the model's resulting flow_keys, one byte per line
 *   params.hex      three 32-bit words: PKT_LEN, META_LEN, EXP_CODE (read at
 *                   RUNTIME by the testbench, so one build runs every case)
 *
 * Usage:
 *   gen_parser_rom <out_dir>            emit the baseline case (eth/ipv4/tcp)
 *   gen_parser_rom <out_dir> --suite    also emit cases/NN-name/{packet,expected,
 *                                        params}.hex for the whole directed suite,
 *                                        plus cases.txt (manifest for the runner)
 *
 * Bit layout of the micro-op word MUST match parser_pkg::mop_from_word (LSB0):
 *   [15:0] payload | [18:16] miss | [22:19] share | [24:23] er | [26:25] func3 |
 *   [34:27] mask | [50:35] value | [59:51] offset | [60] j | [61] f | [62] s |
 *   [63] d | [64] e | [65] x | [69:66] blen | [72:70] shift | [76:73] pos |
 *   [78:77] sz | [82:79] op
 */
#include "parser.h"
#include "encoding.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>

/* the RTL packet buffer size (rtl/parser_pkg.sv PKT_MAX). The standalone
 * testbench $readmemh's the packet straight into this fixed-size buffer, and
 * Verilator aborts on an over-long file, so its image (pktbuf.hex) is capped
 * here. ParseLen (params PKT_LEN) still carries the true length, so a
 * "packet > buffer" case is modelled as bytes >= PKT_MAX reading back 0 — the
 * same bound the cosim gets from the hardware dropping MMIO writes past PKT_MAX. */
#define PKT_BUF_MAX  256

/* EtherTypes (mirrors the anonymous enum in program.c, which isn't exported). */
#define ETH_P_IP     0x0800
#define ETH_P_IPV6   0x86DD
#define ETH_P_8021Q  0x8100
#define ETH_P_8021AD 0x88A8

/* place `val` (width bits) at bit `lopos` of the 96-bit word {hi[31:0], lo[63:0]}.
 * No slice-program field straddles bit 63/64 (checked by construction). */
static void put(uint64_t *lo, uint64_t *hi, uint32_t val, int lopos, int width)
{
    uint64_t m = (width >= 64) ? ~0ULL : ((1ULL << width) - 1ULL);
    uint64_t v = (uint64_t)val & m;
    if (lopos + width <= 64) {
        *lo |= v << lopos;
    } else if (lopos >= 64) {
        *hi |= v << (lopos - 64);
    } else {
        fprintf(stderr, "gen: field straddles word boundary (lopos=%d w=%d)\n", lopos, width);
        exit(2);
    }
}

static void emit_word(FILE *f, const instr *in)
{
    uint64_t lo = 0, hi = 0;
    put(&lo, &hi, (uint32_t)in->payload & 0xFFFF, 0, 16);
    put(&lo, &hi, in->miss,   16, 3);
    put(&lo, &hi, in->share,  19, 4);
    put(&lo, &hi, in->er,     23, 2);
    put(&lo, &hi, in->func3,  25, 2);
    put(&lo, &hi, in->mask,   27, 8);
    put(&lo, &hi, in->value,  35, 16);
    put(&lo, &hi, in->offset, 51, 9);
    put(&lo, &hi, (uint32_t)(in->j != 0), 60, 1);
    put(&lo, &hi, (uint32_t)(in->f != 0), 61, 1);
    put(&lo, &hi, (uint32_t)(in->s != 0), 62, 1);
    put(&lo, &hi, (uint32_t)(in->d != 0), 63, 1);
    put(&lo, &hi, (uint32_t)(in->e != 0), 64, 1);
    put(&lo, &hi, (uint32_t)(in->x != 0), 65, 1);
    put(&lo, &hi, in->blen,  66, 4);
    put(&lo, &hi, in->shift, 70, 3);
    put(&lo, &hi, in->pos,   73, 4);
    put(&lo, &hi, in->sz,    77, 2);
    put(&lo, &hi, (uint32_t)in->op, 79, 4);
    /* 96-bit word: high 32 bits then low 64 bits => 24 hex chars */
    fprintf(f, "%08llx%016llx\n", (unsigned long long)(hi & 0xFFFFFFFFULL),
                                  (unsigned long long)lo);
}

/* collect the unique CAM entries the program references, in first-seen order. */
struct cam_row { unsigned share; uint32_t match; int32_t target; };

static int cam_seen(const struct cam_row *r, int n, unsigned share, uint32_t match)
{
    for (int i = 0; i < n; i++)
        if (r[i].share == share && r[i].match == match) return 1;
    return 0;
}

static char *path(const char *dir, const char *name, char *buf, size_t bufsz)
{
    snprintf(buf, bufsz, "%s/%s", dir, name);
    return buf;
}

/* ---------------------------------------------------------------------------
 * packet builder — a growable byte buffer with protocol-field helpers
 * ------------------------------------------------------------------------- */
typedef struct { uint8_t b[512]; unsigned n; } pkt;

static void p8(pkt *p, unsigned v)  { p->b[p->n++] = (uint8_t)v; }
static void p16(pkt *p, unsigned v) { p8(p, v >> 8); p8(p, v & 0xFF); }
static void pn(pkt *p, unsigned v, unsigned n) { while (n--) p8(p, 0); (void)v; }
static void eth(pkt *p, unsigned ethertype)
{
    for (int i = 0; i < 6; i++) p8(p, 0x00 + i);   /* dst */
    for (int i = 0; i < 6; i++) p8(p, 0x10 + i);   /* src */
    p16(p, ethertype);
}
static void vlan(pkt *p, unsigned inner_ethertype) { p16(p, 0x0000); p16(p, inner_ethertype); }
/* IPv4 header; verhl lets a case inject a bad version/IHL. proto/total_len set. */
static void ipv4(pkt *p, unsigned verhl, unsigned proto, unsigned total_len)
{
    p8(p, verhl); p8(p, 0x00); p16(p, total_len); p16(p, 0x0000);   /* ver/ihl,tos,len,id */
    p16(p, 0x4000); p8(p, 0x40); p8(p, proto); p16(p, 0x0000);      /* flags,ttl,proto,csum */
    p8(p,10); p8(p,0); p8(p,0); p8(p,1);                            /* src 10.0.0.1 */
    p8(p,10); p8(p,0); p8(p,0); p8(p,2);                            /* dst 10.0.0.2 */
}
static void ipv6(pkt *p, unsigned next_hdr)
{
    p8(p, 0x60); p8(p, 0); p16(p, 0);   /* ver/tc/flow */
    p16(p, 0);                          /* payload len (unused by slice) */
    p8(p, next_hdr); p8(p, 64);         /* next header, hop limit */
    for (int i = 0; i < 16; i++) p8(p, 0x20 + i);   /* src */
    for (int i = 0; i < 16; i++) p8(p, 0x40 + i);   /* dst */
}
static void ip6ext(pkt *p, unsigned next_hdr, unsigned ext_len_units)
{
    /* option header: NH, Hdr-Ext-Len (in 8-byte units, first 8 not counted),
     * then (ext_len_units+1)*8 - 2 padding bytes. */
    unsigned total = (ext_len_units + 1) * 8;
    p8(p, next_hdr); p8(p, ext_len_units);
    for (unsigned i = 2; i < total; i++) p8(p, 0x00);
}
static void ip6frag(pkt *p, unsigned next_hdr)
{
    p8(p, next_hdr); p8(p, 0);   /* NH, reserved */
    p16(p, 0);                   /* frag offset/flags */
    p8(p,0); p8(p,0); p8(p,0); p8(p,0);  /* identification */
}
static void l4ports(pkt *p) { p16(p, 0x1234); p16(p, 0x5678); }
static void tcp(pkt *p)
{
    l4ports(p);
    pn(p, 0, 8);                 /* seq, ack */
    p8(p, 0x50); p8(p, 0x02); p16(p, 0x2000); p16(p, 0); p16(p, 0);  /* off/flags,win,csum,urg */
}
static void udp(pkt *p) { l4ports(p); p16(p, 8); p16(p, 0); }   /* len, csum */

/* ---------------------------------------------------------------------------
 * the directed test suite
 * ------------------------------------------------------------------------- */
enum cat { POS, NEG, BND, COR };
static const char *cat_name[] = { "positive", "negative", "boundary", "corner" };

struct testcase {
    const char *name;
    enum cat    cat;
    int         expect_ok;   /* 1 => model must exit P_STOP_OKAY; 0 => must fail */
    void      (*build)(pkt *);
};

static void c_ipv4_tcp(pkt *p)  { eth(p, ETH_P_IP);   ipv4(p, 0x45, 6,  40); tcp(p); }
static void c_ipv4_udp(pkt *p)  { eth(p, ETH_P_IP);   ipv4(p, 0x45, 17, 28); udp(p); }
static void c_ipv6_tcp(pkt *p)  { eth(p, ETH_P_IPV6); ipv6(p, 6);  tcp(p); }
static void c_ipv6_udp(pkt *p)  { eth(p, ETH_P_IPV6); ipv6(p, 17); udp(p); }
static void c_vlan(pkt *p)      { eth(p, ETH_P_8021Q); vlan(p, ETH_P_IP); ipv4(p, 0x45, 6, 40); tcp(p); }
static void c_qinq(pkt *p)      { eth(p, ETH_P_8021AD); vlan(p, ETH_P_8021Q); vlan(p, ETH_P_IP); ipv4(p, 0x45, 6, 40); tcp(p); }
static void c_ipv6_hbh(pkt *p)  { eth(p, ETH_P_IPV6); ipv6(p, 0 /*HBH*/); ip6ext(p, 6 /*TCP*/, 0); tcp(p); }
static void c_ipv6_frag(pkt *p) { eth(p, ETH_P_IPV6); ipv6(p, 44 /*frag*/); ip6frag(p, 17 /*UDP*/); udp(p); }
static void c_min_ipv4(pkt *p)  { eth(p, ETH_P_IP);   ipv4(p, 0x45, 6, 40); tcp(p); }   /* ihl=5 exactly */

static void c_unknown_ethertype(pkt *p) { eth(p, 0x9999); p16(p, 0); }
static void c_bad_version(pkt *p)       { eth(p, ETH_P_IP); ipv4(p, 0x65 /*ver 6*/, 6, 40); tcp(p); }
static void c_unknown_ipproto(pkt *p)   { eth(p, ETH_P_IP); ipv4(p, 0x45, 200 /*unknown*/, 40); pn(p, 0, 8); }
static void c_trunc_ipv4(pkt *p)        { eth(p, ETH_P_IP); p8(p, 0x45); p8(p, 0); p16(p, 40); } /* IPv4 hdr cut short */
static void c_empty(pkt *p)             { (void)p; }
static void c_eth_only(pkt *p)          { eth(p, ETH_P_IP); }   /* ethertype IPv4 but no L3 */

/* IPv4 header with an explicit IHL nibble. When ihl>5 the options area is zero-
 * padded so the on-wire header length matches the field (ihl*4 bytes); when ihl<5
 * the fixed 20 bytes are emitted but the (illegal) small IHL stays in the field so
 * the LENCUR min-length trap fires. */
static void ipv4_ihl(pkt *p, unsigned ihl, unsigned proto, unsigned total_len)
{
    unsigned start = p->n;
    p8(p, 0x40 | (ihl & 0xF)); p8(p, 0x00); p16(p, total_len); p16(p, 0x0000);
    p16(p, 0x4000); p8(p, 0x40); p8(p, proto); p16(p, 0x0000);
    p8(p,10); p8(p,0); p8(p,0); p8(p,1);                            /* src 10.0.0.1 */
    p8(p,10); p8(p,0); p8(p,0); p8(p,2);                            /* dst 10.0.0.2 */
    while (p->n - start < ihl * 4u) p8(p, 0x00);                    /* IPv4 options */
}
/* pad `p` with zero bytes up to `target` total length (after the parsed headers). */
static void pad_to(pkt *p, unsigned target) { while (p->n < target) p8(p, 0x00); }

/* Row 16: ipv4 IHL=15 (60-byte header, max options) — the full header is walked. */
static void c_ipv4_ihl15(pkt *p)  { eth(p, ETH_P_IP); ipv4_ihl(p, 15, 6, 80); tcp(p); }
/* Row 17: ipv4 IHL=0 (illegal) — the LENCUR min-length trap fails the parse. */
static void c_ipv4_ihl0(pkt *p)   { eth(p, ETH_P_IP); ipv4_ihl(p, 0,  6, 40); tcp(p); }
/* Row 18: a deep VLAN stack — 40 stacked C-VLAN tags exceed MAX_NODES (32) and
 * trip the node-count guard, all within the 256-byte buffer (deep-loop bound). */
static void c_vlan_deep(pkt *p)
{
    eth(p, ETH_P_8021AD);
    for (int i = 0; i < 40; i++) vlan(p, ETH_P_8021Q);
    vlan(p, ETH_P_IP); ipv4(p, 0x45, 6, 40); tcp(p);
}
/* Row 19: a chain of len=0 IPv6 hop-by-hop ext headers — each ExtLen=0 advances
 * the minimum 8 bytes and the chain terminates cleanly (liveness, Risk R4). */
static void c_ip6ext_len0(pkt *p)
{
    eth(p, ETH_P_IPV6); ipv6(p, 0 /*HBH*/);
    for (int i = 0; i < 3; i++) ip6ext(p, 0 /*HBH*/, 0);   /* len=0 ext headers */
    ip6ext(p, 6 /*TCP*/, 0); tcp(p);
}
/* Row 20: a valid frame padded to exactly PKT_MAX (256 B) — buffer-exact boundary. */
static void c_pkt_256(pkt *p)  { eth(p, ETH_P_IP); ipv4(p, 0x45, 6, 40); tcp(p); pad_to(p, 256); }
/* Row 21: a valid frame padded past the 256-byte buffer — bytes >=256 are never
 * parsed, so the parse stays bounded and still matches the model (fail-safe). */
static void c_pkt_over(pkt *p)  { eth(p, ETH_P_IP); ipv4(p, 0x45, 6, 40); tcp(p); pad_to(p, 264); }
/* Row 22: a 1-byte packet — the first header load runs off ParseLen and fails
 * (length trap); exercises the short-packet / aligner corner. */
static void c_pkt_1byte(pkt *p) { p8(p, 0x00); }

static const struct testcase suite[] = {
    { "01-eth-ipv4-tcp",       POS, 1, c_ipv4_tcp        },
    { "02-eth-ipv4-udp",       POS, 1, c_ipv4_udp        },
    { "03-eth-ipv6-tcp",       POS, 1, c_ipv6_tcp        },
    { "04-eth-ipv6-udp",       POS, 1, c_ipv6_udp        },
    { "05-eth-vlan-ipv4-tcp",  POS, 1, c_vlan            },
    { "06-eth-qinq-ipv4-tcp",  POS, 1, c_qinq            },
    { "07-eth-ipv6-hbh-tcp",   POS, 1, c_ipv6_hbh        },
    { "08-eth-ipv6-frag-udp",  POS, 1, c_ipv6_frag       },
    { "09-unknown-ethertype",  NEG, 0, c_unknown_ethertype },
    { "10-ipv4-bad-version",   NEG, 0, c_bad_version     },
    { "11-ipv4-unknown-proto", NEG, 0, c_unknown_ipproto },
    { "12-ipv4-tcp-minimal",   BND, 1, c_min_ipv4        },
    { "13-ipv4-truncated",     BND, 0, c_trunc_ipv4      },
    { "14-empty-packet",       COR, 0, c_empty           },
    { "15-eth-only-no-l3",     COR, 0, c_eth_only        },
    { "16-ipv4-ihl15",         BND, 1, c_ipv4_ihl15      },
    { "17-ipv4-ihl0",          NEG, 0, c_ipv4_ihl0       },
    { "18-vlan-deep",          COR, 0, c_vlan_deep       },
    { "19-ip6ext-len0",        COR, 1, c_ip6ext_len0     },
    { "20-pkt-256",            BND, 1, c_pkt_256         },
    { "21-pkt-over-buffer",    BND, 1, c_pkt_over        },
    { "22-pkt-1byte",          COR, 0, c_pkt_1byte       },
};
#define NSUITE ((int)(sizeof(suite)/sizeof(suite[0])))

/* write packet.hex, expected.hex, params.hex for one packet into `dir`; returns
 * the model's exit code via *out_code. */
static int emit_case(const char *dir, const instr *prog, size_t nprog,
                     const pkt *p, int32_t *out_code)
{
    char buf[512];
    FILE *fp;

    fp = fopen(path(dir, "packet.hex", buf, sizeof buf), "w");
    if (!fp) { perror(buf); return -1; }
    for (unsigned i = 0; i < p->n; i++) fprintf(fp, "%02x\n", p->b[i]);
    fclose(fp);

    /* buffer-sized image for the standalone TB, which $readmemh's it straight into
     * the PKT_MAX-byte pktbuf (Verilator aborts on an over-long file). The cosim
     * feeds the full packet.hex over MMIO instead, with writes past the buffer
     * dropped in hardware — so both see the same bounded buffer. */
    fp = fopen(path(dir, "pktbuf.hex", buf, sizeof buf), "w");
    if (!fp) { perror(buf); return -1; }
    unsigned cap = (p->n < PKT_BUF_MAX) ? p->n : PKT_BUF_MAX;
    for (unsigned i = 0; i < cap; i++) fprintf(fp, "%02x\n", p->b[i]);
    fclose(fp);

    pstate ps;
    struct flow_keys fk;
    pm_init(&ps, p->b, p->n, &fk);
    int32_t code = pm_run(&ps, prog, nprog);
    *out_code = code;

    fp = fopen(path(dir, "expected.hex", buf, sizeof buf), "w");
    if (!fp) { perror(buf); return -1; }
    const uint8_t *mb = (const uint8_t *)&fk;
    for (unsigned i = 0; i < sizeof(fk); i++) fprintf(fp, "%02x\n", mb[i]);
    fclose(fp);

    /* runtime params: PKT_LEN, META_LEN, EXP_CODE (32-bit two's complement) */
    fp = fopen(path(dir, "params.hex", buf, sizeof buf), "w");
    if (!fp) { perror(buf); return -1; }
    fprintf(fp, "%08x\n", (unsigned)p->n);
    fprintf(fp, "%08x\n", (unsigned)sizeof(fk));
    fprintf(fp, "%08x\n", (unsigned)(uint32_t)code);
    fclose(fp);
    return 0;
}

int main(int argc, char **argv)
{
    const char *dir = (argc > 1) ? argv[1] : ".";
    int do_suite = (argc > 2) && strcmp(argv[2], "--suite") == 0;
    char buf[512];

    /* ---- the program (shared by every case) ---- */
    size_t n;
    const instr *prog = pm_slice_program(&n);

    FILE *fp = fopen(path(dir, "program.hex", buf, sizeof buf), "w");
    if (!fp) { perror("program.hex"); return 1; }
    for (size_t i = 0; i < n; i++) emit_word(fp, &prog[i]);
    fclose(fp);

    /* ---- 32-bit encoded words (the Phase-3 encoding) for the CVA6 decode path.
     * parser_decode.sv turns these back into micro-ops; parser_top's decode mode
     * runs the program from THESE words, so RTL-decoded == model-decoded. Every
     * slice instr must have a 32-bit form (pm_encode) — error out if one doesn't,
     * since decode mode needs full coverage. ---- */
    fp = fopen(path(dir, "enc.hex", buf, sizeof buf), "w");
    if (!fp) { perror("enc.hex"); return 1; }
    for (size_t i = 0; i < n; i++) {
        uint32_t w;
        if (pm_encode(&prog[i], &w) != 0) {
            fprintf(stderr, "gen: instr %zu (op=%d) has no 32-bit form — decode "
                            "mode cannot cover it\n", i, (int)prog[i].op);
            fclose(fp);
            return 1;
        }
        fprintf(fp, "%08x\n", (unsigned)w);
    }
    fclose(fp);

    /* ---- CAM entries referenced by the program ---- */
    struct cam_row rows[256];
    int nrows = 0;
    for (size_t i = 0; i < n; i++) {
        const struct cam_table *t = prog[i].cam;
        if (!t) continue;
        for (size_t e = 0; e < t->n; e++) {
            unsigned sh = t->ents[e].share;
            uint32_t mt = t->ents[e].match;
            if (!cam_seen(rows, nrows, sh, mt)) {
                rows[nrows].share  = sh;
                rows[nrows].match  = mt;
                rows[nrows].target = t->ents[e].target;
                nrows++;
            }
        }
    }
    fp = fopen(path(dir, "cam.hex", buf, sizeof buf), "w");
    if (!fp) { perror("cam.hex"); return 1; }
    for (int i = 0; i < nrows; i++) {
        /* {valid[52], share[51:48], match[47:32], target[31:0]} */
        uint64_t w = (1ULL << 52)
                   | ((uint64_t)(rows[i].share & 0xF) << 48)
                   | ((uint64_t)(rows[i].match & 0xFFFF) << 32)
                   | ((uint64_t)(uint32_t)rows[i].target);
        fprintf(fp, "%016llx\n", (unsigned long long)w);
    }
    fclose(fp);

    /* ---- camprog.hex: the same entries as Accum words for runtime CAM programming
     * via custom-3 (CPPRSWR then CPPRSWRCAM) in the in-core cosim. The FU takes
     * key = Accum>>32 (= {share<<16 | match}) and target = Accum[31:0], so the word
     * is (share<<48)|(match<<32)|target. Index = line number (0..nrows-1). ---- */
    fp = fopen(path(dir, "camprog.hex", buf, sizeof buf), "w");
    if (!fp) { perror("camprog.hex"); return 1; }
    for (int i = 0; i < nrows; i++) {
        uint64_t w = ((uint64_t)(rows[i].share & 0xF) << 48)
                   | ((uint64_t)(rows[i].match & 0xFFFF) << 32)
                   | ((uint64_t)(uint32_t)rows[i].target);
        fprintf(fp, "%016llx\n", (unsigned long long)w);
    }
    fclose(fp);

    /* ---- baseline case (eth/ipv4/tcp) into out_dir for the default smoke run ---- */
    pkt base = {0};
    c_ipv4_tcp(&base);
    int32_t base_code;
    if (emit_case(dir, prog, n, &base, &base_code) != 0) return 1;
    fprintf(stderr, "gen: %zu instrs, %d CAM entries, baseline pkt=%u bytes, model code=%d\n",
            n, nrows, base.n, base_code);

    if (!do_suite) return 0;

    /* ---- the directed suite: one dir per case + a manifest for the runner ---- */
    char cases_dir[512];
    snprintf(cases_dir, sizeof cases_dir, "%s/cases", dir);
    mkdir(cases_dir, 0777);

    char manifest[512];
    FILE *mf = fopen(path(dir, "cases.txt", manifest, sizeof manifest), "w");
    if (!mf) { perror("cases.txt"); return 1; }

    int mism = 0;
    for (int i = 0; i < NSUITE; i++) {
        char cdir[600];
        snprintf(cdir, sizeof cdir, "%s/%s", cases_dir, suite[i].name);
        mkdir(cdir, 0777);

        pkt p = {0};
        suite[i].build(&p);
        int32_t code;
        if (emit_case(cdir, prog, n, &p, &code) != 0) { fclose(mf); return 1; }

        int got_ok = (code == P_STOP_OKAY);
        const char *verdict = (got_ok == suite[i].expect_ok) ? "ok" : "MISMATCH";
        if (got_ok != suite[i].expect_ok) mism++;

        /* manifest line: name category expect_ok exp_code len */
        fprintf(mf, "%s %s %d %d %u\n", suite[i].name, cat_name[suite[i].cat],
                suite[i].expect_ok, code, p.n);
        fprintf(stderr, "  %-22s %-9s len=%-3u code=%-4d %s\n",
                suite[i].name, cat_name[suite[i].cat], p.n, code, verdict);
    }
    fclose(mf);

    if (mism) {
        fprintf(stderr, "gen: %d case(s) disagree with expected OK/FAIL — fix the vectors\n", mism);
        return 3;
    }
    fprintf(stderr, "gen: suite = %d cases, all match expected OK/FAIL\n", NSUITE);
    return 0;
}
