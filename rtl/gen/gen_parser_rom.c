/*
 * gen_parser_rom.c — generate the RTL smoke-test vectors from the golden model.
 *
 * The RTL parser unit runs the SAME decoded program the C model runs. Rather
 * than hand-keep a second copy, this tool reuses libparsermodel's slice program
 * (pm_slice_program) and emits, for the Verilator smoke test (parser_smoke_tb.sv):
 *
 *   program.hex     one 96-bit micro-op word per instruction (parser_pkg layout)
 *   cam.hex         CAM entries {valid, share, match, target} referenced by the program
 *   packet.hex      a canned Ethernet/IPv4/TCP frame, one byte per line
 *   expected.hex    the model's resulting flow_keys, one byte per line
 *   smoke_params.svh  localparam PKT_LEN / META_LEN / EXP_CODE
 *
 * Usage: gen_parser_rom [out_dir]   (default ".")
 *
 * Bit layout of the micro-op word MUST match parser_pkg::mop_from_word (LSB0):
 *   [15:0] payload | [18:16] miss | [22:19] share | [24:23] er | [26:25] func3 |
 *   [34:27] mask | [50:35] value | [59:51] offset | [60] j | [61] f | [62] s |
 *   [63] d | [64] e | [65] x | [69:66] blen | [72:70] shift | [76:73] pos |
 *   [78:77] sz | [82:79] op
 */
#include "parser.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

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

int main(int argc, char **argv)
{
    const char *dir = (argc > 1) ? argv[1] : ".";
    char buf[512];

    /* ---- the program ---- */
    size_t n;
    const instr *prog = pm_slice_program(&n);

    FILE *fp = fopen(path(dir, "program.hex", buf, sizeof buf), "w");
    if (!fp) { perror("program.hex"); return 1; }
    for (size_t i = 0; i < n; i++) emit_word(fp, &prog[i]);
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

    /* ---- canned Ethernet / IPv4 / TCP frame ---- */
    static const uint8_t pkt[] = {
        0x00,0x11,0x22,0x33,0x44,0x55,           /* eth dst */
        0x66,0x77,0x88,0x99,0xaa,0xbb,           /* eth src */
        0x08,0x00,                               /* ethertype IPv4 */
        0x45,0x00, 0x00,0x28, 0x00,0x00,         /* ver/ihl, tos, total_len=40, id */
        0x40,0x00, 0x40,0x06, 0x00,0x00,         /* flags/frag, ttl, proto=TCP, csum */
        0x0a,0x00,0x00,0x01,                     /* src 10.0.0.1 */
        0x0a,0x00,0x00,0x02,                     /* dst 10.0.0.2 */
        0x12,0x34, 0x56,0x78,                    /* tcp sport=0x1234 dport=0x5678 */
        0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,/* seq, ack */
        0x50,0x02, 0x20,0x00, 0x00,0x00, 0x00,0x00 /* off/flags, win, csum, urg */
    };
    unsigned pkt_len = (unsigned)sizeof(pkt);

    fp = fopen(path(dir, "packet.hex", buf, sizeof buf), "w");
    if (!fp) { perror("packet.hex"); return 1; }
    for (unsigned i = 0; i < pkt_len; i++) fprintf(fp, "%02x\n", pkt[i]);
    fclose(fp);

    /* ---- run the model to get the expected flow_keys + exit code ---- */
    pstate ps;
    struct flow_keys fk;
    pm_init(&ps, pkt, pkt_len, &fk);
    int32_t code = pm_run(&ps, prog, n);

    fp = fopen(path(dir, "expected.hex", buf, sizeof buf), "w");
    if (!fp) { perror("expected.hex"); return 1; }
    const uint8_t *mb = (const uint8_t *)&fk;
    for (unsigned i = 0; i < sizeof(fk); i++) fprintf(fp, "%02x\n", mb[i]);
    fclose(fp);

    /* ---- params for the testbench ---- */
    fp = fopen(path(dir, "smoke_params.svh", buf, sizeof buf), "w");
    if (!fp) { perror("smoke_params.svh"); return 1; }
    fprintf(fp, "// generated by gen_parser_rom.c — do not edit\n");
    fprintf(fp, "localparam int PKT_LEN  = %u;\n", pkt_len);
    fprintf(fp, "localparam int META_LEN = %u;\n", (unsigned)sizeof(fk));
    fprintf(fp, "localparam logic signed [31:0] EXP_CODE = %d;\n", code);
    fclose(fp);

    fprintf(stderr,
        "gen: %zu instrs, %d CAM entries, pkt=%u bytes, meta=%u bytes, model code=%d\n",
        n, nrows, pkt_len, (unsigned)sizeof(fk), code);
    return 0;
}
