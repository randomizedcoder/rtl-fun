/*
 * parser_gen_check.c — Phase 7 §7.6 drift guard.
 *
 * Asserts the generated builders (toolchain/generated/parser_intrinsics.h, emitted
 * by tools/parser-gen from isa/parser-opcodes.yaml) produce byte-identical words to
 * the model's hand-written encoders (model/libparsermodel/encoding.c) for a
 * representative vector per instruction, plus the golden constants. This is the
 * check the round-trip tests can't do today: it ties the yaml directly to the C.
 *
 * Build: cc -I <generated-dir> -I model/libparsermodel parser_gen_check.c encoding.c
 */
#include <stdint.h>
#include <stdio.h>

#include "parser_intrinsics.h"   /* generated: prs_load, prs_store, ... */
#include "encoding.h"            /* model: prs_enc_*                     */

static int fails;

static void chk(const char *what, uint32_t got, uint32_t want)
{
    if (got != want) {
        fprintf(stderr, "  MISMATCH %-16s gen=0x%08x model=0x%08x\n", what, got, want);
        fails++;
    }
}

int main(void)
{
    /* generated builder  vs  model encoder (same field values) */
    chk("prs.load",     prs_load(2, 1, 12),          prs_enc_load(0, 0, 2, 0, 0, 1, 12));
    chk("prs.load.b",   prs_load(1, 0, 0),           prs_enc_load(0, 0, 1, 0, 0, 0, 0));
    chk("prs.lencur",   prs_lencur(1, 0, 1, 2, 20),  prs_enc_len(0, 1, 0, 1, 2, 0, 20));
    chk("prs.store",    prs_store(3, 0, 8),          prs_enc_store(0, 0, 3, 0, 0, 0, 8));
    chk("prs.storeimm", prs_storeimm(1, 4, 16),      prs_enc_storeimm(0, 0, 1, 4, 16));
    chk("prs.cam",      prs_cam(1, 2, 0, 0, 1, 5),   prs_enc_cam(1, 0, 2, 0, 0, 0, 1, 5));
    chk("prs.camnext",  prs_camnext(1, 1, 0, 0, 2, 5), prs_enc_cam(1, 1, 1, 0, 0, 0, 2, 5));
    chk("prs.cmpib",    prs_cmpib(1, 0, 0x40, 0xF0), prs_enc_cmpib(1, 0, 0x40, 0xF0));
    chk("prs.cmpneib",  prs_cmpneib(0, 3, 0x11, 0xFF), prs_enc_cmpneib(0, 3, 0x11, 0xFF));
    chk("prs.nextnode", prs_nextnode(0x1234),        prs_enc_next(0, 0, 0, 0, 0x1234));
    chk("prs.setcode",  prs_setcode(0xF4),           prs_enc_next(0, 0, 2, 0, 0xF4 & 0xFF));
    chk("prs.stp",      prs_stp(),                   prs_enc_next(0, 1, 2, 0, 0));
    chk("prs.mv.x.p",   prs_mv_x_p(11, 0, 7),        prs_enc_cop(11, 0, 0, 0, 0, 0, 0, 7));
    chk("prs.mv.p.x",   prs_mv_p_x(11, 5, 0),        prs_enc_cop(11, 0, 0, 0, 0, 5, 1, 0));
    chk("prs.ld.immed", prs_ld_immed(13, 6, 3),      prs_enc_cop(13, 0, 0, 1, 0, 6, 1, 3));
    chk("prs.cam.read", prs_cam_read(0, 4, 8),       prs_enc_cop(0, 0, 0, 0, 1, 4, 0, 8));
    chk("prs.array.read", prs_array_read(0, 4, 8),   prs_enc_cop(0, 0, 1, 0, 1, 4, 0, 8));

    /* golden constants (must stay stable across regenerations) */
    chk("golden.load.h", prs_load(2, 1, 12), 0x2010600bu);
    chk("golden.load.b", prs_load(1, 0, 0),  0x1000000bu);

    if (fails) {
        fprintf(stderr, "parser_gen_check: %d mismatch(es) — yaml/generator has drifted from encoding.c\n", fails);
        return 1;
    }
    printf("parser_gen_check: all generated encodings match the model + goldens\n");
    return 0;
}
