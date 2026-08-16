/*
 * encoding.c — bit-accurate encode/decode, mirroring
 * docs/analysis/patent-encodings-recovered.md §2/§3 and isa/parser-opcodes.yaml.
 *
 * Every custom-0 word is:  Opcode[6:0]=0x0b | Fnc4[10:7] | group-specific fields.
 * The custom-3 coprocessor word is a standard RISC-V R-form on Opcode=0x7b.
 */
#include "encoding.h"

#define OP0(fnc4) (PRS_OP_C0 | prs_put((fnc4), 10, 7))

unsigned prs_opcode(uint32_t w) { return prs_get(w, 6, 0); }
unsigned prs_fnc4(uint32_t w)   { return prs_get(w, 10, 7); }

/* PLOAD (Fnc4=0000): X[31] D[30] Sz[29:28] Blen[27:24] Shift[23:21] E[20] Offset[19:11]. */
uint32_t prs_enc_load(int x, int d, unsigned sz, unsigned blen, unsigned shift, int e, unsigned off)
{
    return OP0(FNC4_LOAD)
         | prs_put((unsigned)!!x, 31, 31) | prs_put((unsigned)!!d, 30, 30)
         | prs_put(sz, 29, 28) | prs_put(blen, 27, 24) | prs_put(shift, 23, 21)
         | prs_put((unsigned)!!e, 20, 20) | prs_put(off, 19, 11);
}

/* Length (Fnc4=0010): S[31] D[30] Sz[29:28] Pos[27:24] Shift[23:21] F2[20:19] Len[18:11]. */
uint32_t prs_enc_len(int s, int d, unsigned sz, unsigned pos, unsigned shift, unsigned f2, unsigned len)
{
    return OP0(FNC4_LEN)
         | prs_put((unsigned)!!s, 31, 31) | prs_put((unsigned)!!d, 30, 30)
         | prs_put(sz, 29, 28) | prs_put(pos, 27, 24) | prs_put(shift, 23, 21)
         | prs_put(f2, 20, 19) | prs_put(len, 18, 11);
}

/* PSTORE (Fnc4=0100): S[31] F[30] Sz[29:28] Pos[27:24] J[23] Sind[22:20] Offset[19:11]. */
uint32_t prs_enc_store(int s, int f, unsigned sz, unsigned pos, int j, unsigned sind, unsigned off)
{
    return OP0(FNC4_STORE)
         | prs_put((unsigned)!!s, 31, 31) | prs_put((unsigned)!!f, 30, 30)
         | prs_put(sz, 29, 28) | prs_put(pos, 27, 24) | prs_put((unsigned)!!j, 23, 23)
         | prs_put(sind, 22, 20) | prs_put(off, 19, 11);
}

/* PSTOREIMM (Fnc4=0110): S[31] F[30] Sz[29:28] Value[27:20] Offset[19:11]. */
uint32_t prs_enc_storeimm(int s, int f, unsigned sz, unsigned value, unsigned off)
{
    return OP0(FNC4_STOREIMM)
         | prs_put((unsigned)!!s, 31, 31) | prs_put((unsigned)!!f, 30, 30)
         | prs_put(sz, 29, 28) | prs_put(value, 27, 20) | prs_put(off, 19, 11);
}

/* CAM (Fnc4=1000): S[31] D[30] Sz[29:28] Pos[27:24] Func3[23:21] F[20] Share[19:16] Miss[15:11]. */
uint32_t prs_enc_cam(int s, int d, unsigned sz, unsigned pos, unsigned func3, int f, unsigned share, unsigned miss)
{
    return OP0(FNC4_CAM)
         | prs_put((unsigned)!!s, 31, 31) | prs_put((unsigned)!!d, 30, 30)
         | prs_put(sz, 29, 28) | prs_put(pos, 27, 24) | prs_put(func3, 23, 21)
         | prs_put((unsigned)!!f, 20, 20) | prs_put(share, 19, 16) | prs_put(miss, 15, 11);
}

/* Next/set (Fnc4=1010): S[31] V[30] Pos[29:28] A[27] Payload[26:11]. */
uint32_t prs_enc_next(int s, int v, unsigned pos, int a, unsigned payload)
{
    return OP0(FNC4_NEXT)
         | prs_put((unsigned)!!s, 31, 31) | prs_put((unsigned)!!v, 30, 30)
         | prs_put(pos, 29, 28) | prs_put((unsigned)!!a, 27, 27) | prs_put(payload, 26, 11);
}

/* PCMP* ordered byte (Fnc4=1011): S[31] D[30] Sz[29:28] Pos[27:24] Func3[23:21] Er[20:19] Value[18:11]. */
uint32_t prs_enc_cmpord(int s, int d, unsigned sz, unsigned pos, unsigned func3, unsigned er, unsigned value)
{
    return OP0(FNC4_CMPORD)
         | prs_put((unsigned)!!s, 31, 31) | prs_put((unsigned)!!d, 30, 30)
         | prs_put(sz, 29, 28) | prs_put(pos, 27, 24) | prs_put(func3, 23, 21)
         | prs_put(er, 20, 19) | prs_put(value, 18, 11);
}

/* PCMPIB (1101) / PCMPNEIB (1110): Er[31:30] Pos[29:27] Value[26:19] Mask[18:11]. */
static uint32_t enc_cmp_masked(unsigned fnc4, unsigned er, unsigned pos, unsigned value, unsigned mask)
{
    return OP0(fnc4)
         | prs_put(er, 31, 30) | prs_put(pos, 29, 27)
         | prs_put(value, 26, 19) | prs_put(mask, 18, 11);
}
uint32_t prs_enc_cmpib(unsigned er, unsigned pos, unsigned value, unsigned mask)
{ return enc_cmp_masked(FNC4_CMPIB, er, pos, value, mask); }
uint32_t prs_enc_cmpneib(unsigned er, unsigned pos, unsigned value, unsigned mask)
{ return enc_cmp_masked(FNC4_CMPNEIB, er, pos, value, mask); }

/* Custom-3 coprocessor R-form: CoP[31:29]=000 Cpreg[28:24] C[23] S[22] I[21] R[20]
 * Rs[19:15] Func3[14:12] Rd[11:7] Opcode[6:0]=0x7b. */
uint32_t prs_enc_cop(unsigned cpreg, int c, int s, int i, int r, unsigned rs, unsigned func3, unsigned rd)
{
    return PRS_OP_C3
         | prs_put(0u, 31, 29)                 /* CoP = 000 (parser coprocessor) */
         | prs_put(cpreg, 28, 24)
         | prs_put((unsigned)!!c, 23, 23) | prs_put((unsigned)!!s, 22, 22)
         | prs_put((unsigned)!!i, 21, 21) | prs_put((unsigned)!!r, 20, 20)
         | prs_put(rs, 19, 15) | prs_put(func3, 14, 12) | prs_put(rd, 11, 7);
}

/* --- model bridge --- */

/* Map the model's ordered-compare func3 to the patent PCMP* Func3 slot. The
 * model uses 0=LT,1=LE,2=GT,3=GE, matching PCMPILTB/LTEB/GTB/GTEB (000..011). */
int pm_encode(const instr *in, uint32_t *out)
{
    switch (in->op) {
    case OP_LOAD:
        *out = prs_enc_load(in->x, in->d, in->sz, in->blen, in->shift, in->e, in->offset);
        return 0;
    case OP_LENCUR: /* PLENCUR: F2=00; model `value` is the min/const Len */
        *out = prs_enc_len(in->s, in->d, in->sz, in->pos, in->shift, 0, in->value);
        return 0;
    case OP_STORE:
        *out = prs_enc_store(in->s, in->f, in->sz, in->pos, in->j, 0, in->offset);
        return 0;
    case OP_STOREIMM:
        *out = prs_enc_storeimm(in->s, in->f, in->sz, in->value, in->offset);
        return 0;
    case OP_CAM:      /* PCAM: D=0 */
        *out = prs_enc_cam(in->s, 0, in->sz, in->pos, 0, in->f, in->share, in->miss);
        return 0;
    case OP_CAMNEXT:  /* PCAMNEXT: D=1 */
        *out = prs_enc_cam(in->s, 1, in->sz, in->pos, 0, in->f, in->share, in->miss);
        return 0;
    case OP_CMPIB:
        *out = prs_enc_cmpib(in->er, in->pos, in->value, in->mask);
        return 0;
    case OP_CMPINEB:
        *out = prs_enc_cmpneib(in->er, in->pos, in->value, in->mask);
        return 0;
    case OP_CMPORD:
        *out = prs_enc_cmpord(in->s, in->d, in->sz, in->pos, in->func3, in->er, in->value);
        return 0;
    case OP_NEXTNODE: /* PNEXTNODE: Pos=00 */
        *out = prs_enc_next(in->s, in->value ? 1 : 0, 0, 0, (unsigned)in->payload);
        return 0;
    case OP_SETCODE:  /* PSETCODE: Pos=10, V=0 */
        *out = prs_enc_next(in->s, 0, 2, 0, (unsigned)in->payload & 0xFF);
        return 0;
    case OP_STP:      /* PSTP: encoded as PSETCODE of STOP_OKAY (Pos=10) */
        *out = prs_enc_next(in->s, 0, 2, 0, (unsigned)(P_STOP_OKAY & 0xFF));
        return 0;
    default:
        return -1;    /* OP_INITPARSER etc.: no 32-bit custom-0 form here */
    }
}

enum opcode pm_decode_opcode(uint32_t w)
{
    if (prs_opcode(w) != PRS_OP_C0) return OP__COUNT;
    switch (prs_fnc4(w)) {
    case FNC4_LOAD:     return OP_LOAD;
    case FNC4_LEN:      return OP_LENCUR;
    case FNC4_STORE:    return OP_STORE;
    case FNC4_STOREIMM: return OP_STOREIMM;
    case FNC4_CAM:      return prs_get(w, 30, 30) ? OP_CAMNEXT : OP_CAM;   /* D bit */
    case FNC4_NEXT:     return (prs_get(w, 29, 28) == 2) ? OP_SETCODE : OP_NEXTNODE;
    case FNC4_CMPORD:   return OP_CMPORD;
    case FNC4_CMPIB:    return OP_CMPIB;
    case FNC4_CMPNEIB:  return OP_CMPINEB;
    default:            return OP__COUNT;
    }
}
