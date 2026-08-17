/*
 * parser_insn.h — pre-toolchain instruction emitters (Phase 3 §3.7).
 *
 * Until binutils/LLVM learn the parser opcodes (Phase 7), code emits raw parser
 * instruction words. This header builds those words from the exact patent fields
 * (via libparsermodel/encoding.h) and provides a `.insn` emit macro for planting
 * a constant word into the instruction stream.
 *
 * Two ways to use it:
 *   1. Compute a word (host or target), e.g. to fill a program image or a test:
 *        uint32_t w = prs_load_h(12);
 *   2. Emit a constant word inline once a core executes it (Phase 5+):
 *        PRS_EMIT(prs_load_h(12));      // requires a constant-foldable argument
 *
 * The field math lives in ONE place (encoding.c / parser-opcodes.yaml); these are
 * thin, self-documenting wrappers so call sites read like assembly.
 */
#ifndef PARSER_INSN_H
#define PARSER_INSN_H

#include "encoding.h"   /* prs_enc_* + PRS_OP_C0/C3 + Fnc4 map */

/* Sz codes (load/store: 0=dword). */
#define PRS_SZ_DW 0
#define PRS_SZ_B  1
#define PRS_SZ_H  2
#define PRS_SZ_W  3

/* --- custom-0 word builders (return the 32-bit encoding) --- */

/* PLOAD from pcurptr+off (X=0). endian E keeps big-endian value. */
static inline uint32_t prs_load(unsigned sz, unsigned off, int e)
{ return prs_enc_load(/*x*/0, /*d*/0, sz, /*blen*/0, /*shift*/0, e, off); }
static inline uint32_t prs_load_b(unsigned off) { return prs_load(PRS_SZ_B, off, 0); }
static inline uint32_t prs_load_h(unsigned off) { return prs_load(PRS_SZ_H, off, 1); }
static inline uint32_t prs_load_w(unsigned off) { return prs_load(PRS_SZ_W, off, 1); }

/* PLENCUR: set CurHdr.Length. shift==7 => constant length = len. */
static inline uint32_t prs_lencur(int d, unsigned sz, unsigned pos, unsigned shift, unsigned len)
{ return prs_enc_len(/*s*/0, d, sz, pos, shift, /*f2*/0, len); }
static inline uint32_t prs_lencur_const(unsigned len) { return prs_lencur(0, 0, 0, 7, len); }

/* PSTORE Accum sub-register -> metadata at off. */
static inline uint32_t prs_store(unsigned sz, unsigned pos, unsigned off)
{ return prs_enc_store(/*s*/0, /*f*/0, sz, pos, /*j*/0, /*sind*/0, off); }
/* PSTOREIMM immediate -> metadata at off. */
static inline uint32_t prs_storeimm(unsigned sz, unsigned value, unsigned off)
{ return prs_enc_storeimm(/*s*/0, /*f*/0, sz, value, off); }

/* PCAM (-> Accum) / PCAMNEXT (-> Next). */
static inline uint32_t prs_cam(unsigned sz, unsigned pos, unsigned share, unsigned miss)
{ return prs_enc_cam(/*s*/1, /*d*/0, sz, pos, /*func3*/0, /*f*/0, share, miss); }
static inline uint32_t prs_camnext(unsigned sz, unsigned pos, unsigned share, unsigned miss)
{ return prs_enc_cam(/*s*/1, /*d*/1, sz, pos, /*func3*/0, /*f*/0, share, miss); }

/* PCMPIB / PCMPNEIB (masked byte compare) and ordered byte compares. */
static inline uint32_t prs_cmpib(unsigned pos, unsigned value, unsigned mask, unsigned er)
{ return prs_enc_cmpib(er, pos, value, mask); }
static inline uint32_t prs_cmpneib(unsigned pos, unsigned value, unsigned mask, unsigned er)
{ return prs_enc_cmpneib(er, pos, value, mask); }

/* PNEXTNODE / PSTP. */
static inline uint32_t prs_nextnode(unsigned payload) { return prs_enc_next(/*s*/1, 0, /*pos*/0, 0, payload); }
static inline uint32_t prs_stp(void) { return prs_enc_next(/*s*/1, 0, /*pos*/2, 0, /*STOP_OKAY*/0xFC); }

/* --- custom-3 coprocessor moves --- */
static inline uint32_t prs_mv_x_p(unsigned rd, unsigned cpreg)   /* read p -> int */
{ return prs_enc_cop(cpreg, 0, 0, 0, 0, /*rs*/0, /*func3*/0, rd); }
static inline uint32_t prs_mv_p_x(unsigned cpreg, unsigned rs)   /* write int -> p */
{ return prs_enc_cop(cpreg, 0, 0, 0, 0, rs, /*func3*/1, /*rd*/0); }
/* CPPRSWRIMM: write p[cpreg] from an 11-bit immediate (no integer operand). The
 * split immediate reuses the R/Rs and Rd fields — imm = {Imm2[20:15], Imm1[11:7]} —
 * so drop imm[10] into R, imm[9:5] into Rs, imm[4:0] into Rd (see bitgen.py CP32). */
static inline uint32_t prs_ld_immed(unsigned cpreg, unsigned imm11)
{ return prs_enc_cop(cpreg, 0, 0, /*i*/1, /*r*/(imm11 >> 10) & 1u,
                     /*rs*/(imm11 >> 5) & 0x1fu, /*func3*/1, /*rd*/imm11 & 0x1fu); }

/* --- emit a constant word into the instruction stream (Phase 5+) --- *
 * GNU as `.insn <len>, <value>`; value must be a constant expression. */
#define PRS_EMIT(word) __asm__ __volatile__(".insn 4, %0" :: "i"(word))

#endif /* PARSER_INSN_H */
