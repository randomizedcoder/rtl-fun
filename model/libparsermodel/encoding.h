/*
 * encoding.h — bit-accurate instruction encode/decode (Phase 3).
 *
 * Encodes the parser ISA exactly as the patent draws it (US 12,461,885,
 * FIG 43-47) — see docs/analysis/patent-encodings-recovered.md and the
 * machine-readable table isa/parser-opcodes.yaml, which this file mirrors.
 *
 * Numbering here is normal C (bit 0 = LSB). The recovered doc draws bit 31 on
 * the LEFT (patent order); a field the doc lists as [hi:lo] occupies the same
 * hi..lo bits here.
 *
 * Scope: the 32-bit custom-0 forms plus the custom-3 coprocessor R-form. The
 * 64-bit variant is deferred (Phase-3 open question: 32-bit first).
 */
#ifndef LIBPARSERMODEL_ENCODING_H
#define LIBPARSERMODEL_ENCODING_H

#include <stdint.h>
#include "parser.h"

/* Primary opcodes (FIG 46 framing). */
#define PRS_OP_C0 0x0Bu   /* custom-0: 32-bit parser instructions */
#define PRS_OP_C3 0x7Bu   /* custom-3: coprocessor moves / CAM+array programming */

/* Fnc4 group map (FIG 46, p.49). Occupies bits [10:7] of a custom-0 word. */
enum prs_fnc4 {
    FNC4_LOAD      = 0x0,  /* PLOAD, PLOADTLVLOOP, PTLVFASTLOOP */
    FNC4_FLAGSLOOP = 0x1,  /* PFLAGSLOOP */
    FNC4_LEN       = 0x2,  /* PLENCUR, PLENDATA, PLENDATABND */
    FNC4_LENTLV    = 0x3,  /* PLENDATATLV, PLENDATAPAD, PLENDATAEOL */
    FNC4_STORE     = 0x4,  /* PSTORE */
    FNC4_STOREREG  = 0x5,  /* PSTOREREG */
    FNC4_STOREIMM  = 0x6,  /* PSTOREIMM */
    FNC4_EXTRACT   = 0x7,  /* PEXTRACT, PLOOP, PINCCNTR, PSETCNTRBIT, PRESETCNTR */
    FNC4_CAM       = 0x8,  /* PCAM, PCAMNEXT, PCAMJUMP*, ... */
    FNC4_ARR       = 0x9,  /* PARR, PARRNEXT, PARRJUMP* */
    FNC4_NEXT      = 0xA,  /* PNEXTNODE, PSETIMM, PSETCODE, PSTP, PVARINT, PANDMASK */
    FNC4_CMPORD    = 0xB,  /* PCMPILTB, PCMPILTEB, PCMPIGTB, PCMPIGTEB */
    FNC4_CMPIH     = 0xC,  /* PCMPIH */
    FNC4_CMPIB     = 0xD,  /* PCMPIB */
    FNC4_CMPNEIB   = 0xE,  /* PCMPNEIB */
    FNC4_LIFECYCLE = 0xF,  /* PRUNTHREAD, PINITPARSER, PEVENTLOOP*, PDATAEXTRACT */
};

/* --- generic bit-field helpers (bit 0 = LSB) --- */
static inline uint32_t prs_get(uint32_t w, unsigned hi, unsigned lo)
{
    return (w >> lo) & ((hi - lo) >= 31 ? 0xFFFFFFFFu : ((1u << (hi - lo + 1)) - 1));
}
static inline uint32_t prs_put(uint32_t v, unsigned hi, unsigned lo)
{
    uint32_t m = ((hi - lo) >= 31 ? 0xFFFFFFFFu : ((1u << (hi - lo + 1)) - 1));
    return (v & m) << lo;
}

unsigned prs_opcode(uint32_t w);   /* bits [6:0]  */
unsigned prs_fnc4(uint32_t w);     /* bits [10:7] */

/* --- per-group encoders (custom-0). Field names/positions match §2/§3.5. --- */
uint32_t prs_enc_load(int x, int d, unsigned sz, unsigned blen, unsigned shift, int e, unsigned off);
uint32_t prs_enc_len(int s, int d, unsigned sz, unsigned pos, unsigned shift, unsigned f2, unsigned len);
uint32_t prs_enc_store(int s, int f, unsigned sz, unsigned pos, int j, unsigned sind, unsigned off);
uint32_t prs_enc_storeimm(int s, int f, unsigned sz, unsigned value, unsigned off);
uint32_t prs_enc_cam(int s, int d, unsigned sz, unsigned pos, unsigned func3, int f, unsigned share, unsigned miss);
uint32_t prs_enc_next(int s, int v, unsigned pos, int a, unsigned payload);
uint32_t prs_enc_cmpord(int s, int d, unsigned sz, unsigned pos, unsigned func3, unsigned er, unsigned value);
uint32_t prs_enc_cmpib(unsigned er, unsigned pos, unsigned value, unsigned mask);   /* Fnc4=1101 */
uint32_t prs_enc_cmpneib(unsigned er, unsigned pos, unsigned value, unsigned mask); /* Fnc4=1110 */

/* --- custom-3 coprocessor R-form (FIG 43/44, §2.2) --- */
uint32_t prs_enc_cop(unsigned cpreg, int c, int s, int i, int r, unsigned rs, unsigned func3, unsigned rd);

/* --- model bridge --- *
 * Encode a decoded model instr (the opcodes libparsermodel executes) to its
 * 32-bit word. Returns 0 on success, -1 if the opcode has no 32-bit form here.
 * CAM/next TARGETS live in the CAM table / are resolved at run time, so they are
 * NOT part of the instruction word (only Sz/Pos/Share/Miss/… are). */
int pm_encode(const instr *in, uint32_t *out);

/* Decode the group of a word back to a model opcode (best-effort inverse of
 * pm_encode's group selection). Returns OP__COUNT if unrecognised. */
enum opcode pm_decode_opcode(uint32_t w);

#endif /* LIBPARSERMODEL_ENCODING_H */
