/*
 * parser_asm_vectors.c — single source for the Phase 7 L2 assembler test.
 *
 * Emits, from ONE vector table, both a `.s` of every parser mnemonic and the
 * expected 32-bit word for each line, computed by the GENERATED intrinsics
 * (toolchain/generated/parser_intrinsics.h). scripts/parser-asm-test.sh then
 * assembles the `.s` with the patched `riscv64-none-elf-as` and checks that
 * objdump's words match these expectations — so gas == generator == model
 * (the last tie via `nix run .#parser-gen-check`). Keeping the asm text and the
 * golden word in one row makes drift between them impossible.
 *
 * Vectors cover BOTH operand syntaxes the binutils patch accepts: the Stage-1
 * Hybrid form (positional immediates) and the Stage-1.5 prose sugar
 * (`pcurptr+N`, `paccum[i]`, `value:mask`). Both assemble to the same encoding,
 * proving the prose rows are additive; the script additionally round-trips the
 * disassembly (objdump prints prose) back through the assembler.
 *
 * Build/run:  cc -I toolchain/generated parser_asm_vectors.c -o gen && ./gen <out.s> <out.words>
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "parser_intrinsics.h"

struct vec {
    const char *asmline;   /* one assembler statement, Hybrid syntax */
    uint32_t    word;      /* expected encoding, from the generated intrinsics */
};

int main(int argc, char **argv)
{
    /* asm operands and intrinsic args correspond field-for-field; the dotted size
       suffix folds Sz (loadstore: b=1,h=2,w=3,d=0; general: n=0,b=1,h=2,w=3). */
    const struct vec v[] = {
        /* Dotted suffixes fold a field into the mnemonic (Phase-7 prose-freeze):
           load E -> .be (bare = E=0); cam/length S -> .stp; cmp Er ->
           .stop/.stopnode/.stopsub/.fail. The intrinsic still takes the folded field
           as a parameter, so the expected word is unchanged (bits identical). */
        { "prs.load.h.be 12",             prs_load(2, 1, 12) },   /* E=1 via .be */
        { "prs.load.h 12",                prs_load(2, 0, 12) },   /* E=0 bare */
        { "prs.load.b 0",                 prs_load(1, 0, 0) },
        { "prs.load.w.be 4",              prs_load(3, 1, 4) },
        { "prs.load.d 8",                 prs_load(0, 0, 8) },
        { "prs.lencur.n 1, 1, 2, 20",     prs_lencur(1, 0, 1, 2, 20) },
        { "prs.lencur.n.stp 1, 1, 2, 20", prs_lencur(1, 0, 1, 2, 20) | (1u << 31) }, /* S=1 via .stp (bit 31) */
        { "prs.store.b 0, 8",             prs_store(1, 0, 8) },
        { "prs.store.h 0, 8",             prs_store(2, 0, 8) },
        { "prs.storeimm.b 4, 3",          prs_storeimm(1, 4, 3) },
        /* Destination decoration: the leading paccum/pnext pseudo-register selects the
           CAM D bit (paccum ⇒ D=0 Accum, pnext ⇒ D=1 Next) — a single prs.cam mnemonic
           (no prs.camnext). prs_cam's first parameter is D. */
        { "prs.cam.h.stp paccum, 0, 0, 1, 5", prs_cam(0, 1, 2, 0, 0, 1, 5) }, /* D=0; S=1 via .stp */
        { "prs.cam.h paccum, 0, 0, 1, 5",     prs_cam(0, 0, 2, 0, 0, 1, 5) }, /* D=0; S=0 bare */
        { "prs.cam.h.stp pnext, 0, 0, 1, 5",  prs_cam(1, 1, 2, 0, 0, 1, 5) }, /* D=1 (was prs.camnext) */
        { "prs.cmpib.stopnode 0, 0x40, 0xF0", prs_cmpib(1, 0, 0x40, 0xF0) },
        { "prs.cmpib.fail 0, 0x40, 0xF0",     prs_cmpib(3, 0, 0x40, 0xF0) },
        { "prs.cmpneib.stop 3, 0x11, 0xFF",   prs_cmpneib(0, 3, 0x11, 0xFF) },
        { "prs.cmpneib.stopsub 3, 0x11, 0xFF", prs_cmpneib(2, 3, 0x11, 0xFF) },
        { "prs.nextnode 0x1234",          prs_nextnode(0x1234) },
        { "prs.setcode 0xF4",             prs_setcode(0xF4) },
        { "prs.stp",                      prs_stp() },
        { "prs.mv.x.p a1, paccum",        prs_mv_x_p(15, 0, 11) },
        { "prs.mv.p.x pnext, a0",         prs_mv_p_x(11, 10, 0) },
        { "prs.ld.immed p13, 6, 3",       prs_ld_immed(13, 6, 3) },
        { "prs.cam.read a5, a4, p0",      prs_cam_read(0, 14, 15) },
        { "prs.array.read a5, a4, p0",    prs_array_read(0, 14, 15) },

        /* Stage-1.5 prose sugar, now combined with the freeze suffixes. Same
           encodings as the Hybrid forms above: pcurptr+N -> load Offset; paccum[i]
           -> Pos; value:mask -> cmp Value/Mask. `pcurptr` bare == Offset 0. */
        { "prs.load.h.be pcurptr+12",           prs_load(2, 1, 12) },
        { "prs.load.b pcurptr",                 prs_load(1, 0, 0) },
        { "prs.store.b paccum[0], 8",           prs_store(1, 0, 8) },
        { "prs.lencur.n 1, paccum[1], 2, 20",   prs_lencur(1, 0, 1, 2, 20) },
        { "prs.cam.h.stp pnext, paccum[0], 0, 1, 5",   prs_cam(1, 1, 2, 0, 0, 1, 5) },
        { "prs.cmpib.stopnode paccum[0], 0x40:0xF0",  prs_cmpib(1, 0, 0x40, 0xF0) },
        { "prs.cmpneib.stop paccum[3], 0x11:0xFF",    prs_cmpneib(0, 3, 0x11, 0xFF) },
    };
    const size_t n = sizeof v / sizeof v[0];

    if (argc != 3) {
        fprintf(stderr, "usage: %s <out.s> <out.words>\n", argv[0]);
        return 2;
    }
    FILE *s = fopen(argv[1], "w");
    FILE *w = fopen(argv[2], "w");
    if (!s || !w) {
        perror("fopen");
        return 2;
    }
    fprintf(s, "\t.text\n\t.globl _start\n_start:\n");
    for (size_t i = 0; i < n; i++) {
        fprintf(s, "\t%s\n", v[i].asmline);
        fprintf(w, "%08x\n", v[i].word);
    }
    fclose(s);
    fclose(w);
    printf("parser_asm_vectors: emitted %zu mnemonics\n", n);
    return 0;
}
