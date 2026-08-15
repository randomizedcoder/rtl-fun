/*
 * libparsermodel — instruction semantics + interpreter.
 * Each execute_* mirrors docs/phase-1-isa-semantics.md (§-refs inline).
 *
 * Model conventions (documented; exact bit-placement is co-verified vs RTL in
 * Phase 6, an acknowledged Phase-2 open question):
 *  - Loaded fields are placed at the MOST-SIGNIFICANT end of a 64-bit register,
 *    and sub-registers are numbered big-endian from the MSB (Pos 0 = topmost
 *    sub-register of the given width). This is the only convention under which
 *    the patent's worked example (version at nibble Pos0, IHL at Pos1, EtherType
 *    at half Pos0) is self-consistent — see pm_extract_subreg / execute_load.
 *  - flow_keys fields hold the NUMERIC value of the packet field (its big-endian
 *    interpretation) as a host integer, e.g. 10.0.0.1 -> 0x0A000001.
 */
#include "parser.h"
#include <string.h>

#define ALL_ONES 0xFFFFFFFFFFFFFFFFULL

/* ---- termination helpers (Phase-1 §2.1) ---- */
static void okay_parser(pstate *ps)            { ps->done = 1; ps->code = P_STOP_OKAY; }
static void fail_parser(pstate *ps, int32_t c) { ps->done = 1; ps->code = c; }
static void parser_exit(pstate *ps, int32_t c) { ps->done = 1; ps->code = IS_OK_CODE(c) ? P_STOP_OKAY : c; }
static void goto_ins(pstate *ps, uint32_t idx) { ps->next_pc = idx; }

static void common_end_of_node(pstate *ps);

/* ---- sub-register access (Phase-1 §1.3) ---- */
uint64_t pm_extract_subreg(uint64_t val, unsigned sz, unsigned pos)
{
    unsigned width = (sz == 0) ? 4u : (8u << (sz - 1)); /* n/b/h/w = 4/8/16/32 */
    unsigned shift = 64u - width - pos * width;
    uint64_t m = (width == 64) ? ALL_ONES : ((1ULL << width) - 1);
    return (val >> shift) & m;
}

/* ---- load helpers (Phase-1 §2.2/§2.3/§2.4) ---- */
static uint64_t read_be(const uint8_t *p, unsigned n)
{
    uint64_t v = 0;
    for (unsigned i = 0; i < n; i++) v = (v << 8) | p[i];
    return v;
}
static uint64_t bswap_n(uint64_t v, unsigned n)
{
    uint64_t r = 0;
    for (unsigned i = 0; i < n; i++) { r = (r << 8) | (v & 0xff); v >>= 8; }
    return r;
}

/* Get_Load_Src_Addr — bounds check (may exit), returns absolute byte offset. */
static int load_src_off(pstate *ps, uint32_t off, unsigned n, int x, uint32_t *out)
{
    if (x) {
        if (off + n > ps->databound)             { fail_parser(ps, P_STOP_TLV_LENGTH); return -1; }
        if (ps->dat.off + off + n > ps->parse_len){ fail_parser(ps, P_STOP_TLV_LENGTH); return -1; }
        *out = ps->dat.off + off;
    } else {
        if (ps->cur.off + off + n > ps->parse_len){ fail_parser(ps, P_STOP_LENGTH); return -1; }
        *out = ps->cur.off + off;
    }
    return 0;
}

/* ---- PINITPARSER (Phase-1 §4.1) ---- */
void pm_init(pstate *ps, const uint8_t *pkt, uint32_t len, struct flow_keys *meta)
{
    memset(ps, 0, sizeof(*ps));
    ps->pkthdrbase = pkt;
    ps->all_len   = len;
    ps->parse_len = len;      /* whole packet present in the model (§2.9) */
    ps->P = 1;
    ps->databound = 0xFFFFFFFFu;
    ps->loop = P_OKAY_RET;
    ps->next = P_STOP_OKAY;
    ps->meta = meta;
    ps->max_nodes = 32;
    ps->max_encap = 4;
    if (meta) memset(meta, 0, sizeof(*meta));
}

/* ---- PLOAD (Phase-1 §4.2) ---- */
static void execute_load(pstate *ps, const instr *in)
{
    unsigned n = (in->sz == 0) ? 8u : (1u << (in->sz - 1));
    uint32_t at;
    if (load_src_off(ps, in->offset, n, in->x, &at)) return;   /* bounds; MNR */

    uint64_t raw = read_be(ps->pkthdrbase + at, n);            /* big-endian numeric */
    uint64_t val = in->e ? raw : bswap_n(raw, n);              /* E: keep BE; else host-order */
    val <<= in->shift;
    if (in->blen) {
        unsigned mb = (n == 8) ? in->blen * 2u : in->blen;     /* Sz==0 doubles Blen (§2.3) */
        val &= (mb >= 64) ? 0 : (ALL_ONES >> mb);
    }
    ps->accum = val << (64u - 8u * n);                         /* place field at MSB */

    /* load-sets-length (§2.4): grow header length to cover the last byte */
    if (in->x) { if (in->offset + n > ps->dat.len) ps->dat.len = in->offset + n; }
    else       { if (in->offset + n > ps->cur.len) ps->cur.len = in->offset + n; }
}

/* ---- PLENCUR / lensetmin (Phase-1 §4.3) ---- *
 * min/const base is `Len`; computed length = (field<<Shift)+Len (D=0) or
 * (field<<Shift) checked >= Len (D=1); Shift==7 => constant length = Len.
 * Sets DataHdr.Offset and DataBound (§3.2). Numbers match the patent's worked
 * example (IHL=7 -> len 28, DataHdr.Offset 34, DataBound 8).                  */
static void execute_lencur(pstate *ps, const instr *in)
{
    uint64_t field = pm_extract_subreg(ps->accum, in->sz, in->pos);
    uint32_t len;
    if (in->shift == 7)      len = in->value;                  /* constant-length check */
    else if (!in->d)         len = (uint32_t)((field << in->shift) + in->value);
    else                     len = (uint32_t)(field << in->shift);
    len &= 0x1FF;                                              /* 9-bit truncation */

    if (in->d) {
        uint32_t minv = (in->value == 0) ? 1u : in->value;
        if (len < minv) { fail_parser(ps, P_STOP_LENGTH); return; }
    }
    uint32_t last = ps->cur.off + len;
    if (last > ps->parse_len || len < ps->cur.len) { fail_parser(ps, P_STOP_LENGTH); return; }

    ps->cur.len = len;
    if (in->d || in->shift == 7)
        ps->dat.off = ps->cur.off + in->value;                /* options start after min hdr */
    ps->databound = ps->cur.off + ps->cur.len - ps->dat.off;  /* §3.2 */
    if (in->s) common_end_of_node(ps);
}

/* ---- compare family (Phase-1 §4.4) ---- */
static void common_2bit_error(pstate *ps, unsigned er)
{
    switch (er) {
    case ER_STOP:     parser_exit(ps, P_STOP_COMPARE); break;
    case ER_STOPNODE: common_end_of_node(ps);          break;
    case ER_STOPSUB:  ps->loop = P_STOP_SUB_NODE_OKAY; common_end_of_node(ps); break;
    default:          fail_parser(ps, P_STOP_FAIL);    break; /* ER_FAIL */
    }
}
static void execute_cmpib(pstate *ps, const instr *in)
{
    uint64_t t = pm_extract_subreg(ps->accum, 1, in->pos);
    if ((t & in->mask) != in->value) { common_2bit_error(ps, in->er); return; }
    if (in->s) common_end_of_node(ps);
}
static void execute_cmpineb(pstate *ps, const instr *in)
{
    uint64_t t = pm_extract_subreg(ps->accum, 1, in->pos);
    if ((t & in->mask) == in->value) { common_2bit_error(ps, in->er); return; }
    if (in->s) common_end_of_node(ps);
}
static void execute_cmpord(pstate *ps, const instr *in)
{
    uint64_t v = pm_extract_subreg(ps->accum, in->sz, in->pos);
    int r = (in->func3 == 0) ? (v <  in->value) :
            (in->func3 == 1) ? (v <= in->value) :
            (in->func3 == 2) ? (v >  in->value) :
                               (v >= in->value);
    if (!r) { common_2bit_error(ps, in->er); return; }
    if (in->s) common_end_of_node(ps);
}

/* ---- CAM (Phase-1 §4.5 / §2.6) ---- */
static int32_t cam_lookup(pstate *ps, const instr *in)
{
    uint64_t key_src = in->f ? ps->flags : ps->accum;
    uint32_t match = (uint32_t)pm_extract_subreg(key_src, in->sz, in->pos);
    const struct cam_table *t = in->cam;
    if (!t) return (int32_t)0xFFFFFFFF;                        /* miss (no table) */
    for (size_t i = 0; i < t->n; i++)
        if (t->ents[i].share == in->share && t->ents[i].match == match)
            return t->ents[i].target;
    return (int32_t)0xFFFFFFFF;                                /* all-ones = miss */
}
static int32_t cam_miss(pstate *ps, unsigned miss)
{
    switch (miss) {
    case MISS_STOP:    parser_exit(ps, P_STOP_UNKNOWN_PROTO); break;
    case MISS_STOPSUB: ps->loop = P_STOP_SUB_NODE_OKAY; common_end_of_node(ps); break;
    case MISS_FAIL:    fail_parser(ps, P_STOP_UNKNOWN_PROTO); break;
    case MISS_FAILSUB: fail_parser(ps, P_STOP_TLV_LENGTH); break;
    default:           break; /* WILD/ALT: handled by caller via Wildcard regs (deferred) */
    }
    return P_STOP_UNKNOWN_PROTO;
}
static int32_t cam_result(pstate *ps, const instr *in)
{
    int32_t r = cam_lookup(ps, in);
    if ((uint32_t)r == 0xFFFFFFFFu) r = cam_miss(ps, in->miss);
    return r;
}
static void execute_cam(pstate *ps, const instr *in)
{
    int32_t r = cam_result(ps, in);
    if (ps->done) return;
    ps->accum = (uint32_t)r;
    if (in->s) common_end_of_node(ps);
}
static void execute_camnext(pstate *ps, const instr *in)
{
    int32_t r = cam_result(ps, in);
    if (ps->done) return;
    /* The target encodes its own control bits (encap/overlay); do NOT carry
     * bits from the prior Next value — at node entry it holds a RET code
     * (e.g. P_STOP_OKAY = 0xFFFFFFFC) whose low bits would spuriously set
     * ENCAP/OVERLAY. */
    ps->next = (int32_t)((uint32_t)r & (NEXT_ADDR_MASK | NEXT_CTRL_MASK));
    if (in->s) common_end_of_node(ps);
}

/* ---- store family (Phase-1 §4.7) ---- */
static void store_bytes(pstate *ps, uint32_t off, uint64_t val, unsigned n)
{
    if (!ps->meta) return;
    if (off + n > sizeof(*ps->meta)) return;                  /* out-of-region: silent skip */
    memcpy((uint8_t *)ps->meta + off, &val, n);               /* host-order native */
}
static void execute_store(pstate *ps, const instr *in)
{
    uint64_t src = in->j ? ps->flags : ps->accum;
    unsigned n; uint64_t t;
    if (in->sz == 0) { t = src; n = 8; }
    else             { t = pm_extract_subreg(src, in->sz, in->pos); n = 1u << (in->sz - 1); }
    if (in->e) t = bswap_n(t, n);
    store_bytes(ps, in->offset, t, n);
    if (in->s) common_end_of_node(ps);
}
static void execute_storeimm(pstate *ps, const instr *in)
{
    unsigned n = (in->sz == 0) ? 4u : (1u << (in->sz - 1));
    store_bytes(ps, in->offset, in->value, n);
    if (in->s) common_end_of_node(ps);
}

/* ---- control / next (Phase-1 §4.9) ---- */
static void execute_nextnode(pstate *ps, const instr *in)
{
    /* payload encodes target + its control bits; do not carry stale bits from
     * a RET-code Next (see execute_camnext). */
    ps->next = in->payload & (int32_t)(NEXT_ADDR_MASK | NEXT_CTRL_MASK);
    if (in->value) ps->next |= NEXT_OVERLAY_BIT;              /* V bit reuses `value` flag */
    if (in->s) common_end_of_node(ps);
}
static void execute_setcode(pstate *ps, const instr *in)
{
    ps->next = (int32_t)(NEXT_CODE_BIT | (in->payload & 0xFF));
    if (in->s) common_end_of_node(ps);
}

/* ---- Common_End_of_Node (Phase-1 §5): Loop first, then Next ---- */
static void common_end_of_node(pstate *ps)
{
    /* Stage 1: the Loop register (data-header / sub-node level). */
    if (!IS_RET_CODE(ps->loop)) {                 /* Loop = address -> live loop */
        ps->databound -= ps->dat.len;
        ps->dat.off   += ps->dat.len;
        ps->dat.len    = 0;
        goto_ins(ps, (uint32_t)ps->loop);
        return;
    } else if (!IS_OK_CODE(ps->loop)) {           /* Loop = error code */
        fail_parser(ps, ps->loop);
        return;
    }
    /* else Loop = OKAY code -> fall through to Next */

    /* Stage 2: the Next register (protocol-header level). */
    if (!IS_RET_CODE(ps->next)) {                 /* Next = address */
        if (++ps->node_cnt > ps->max_nodes) { fail_parser(ps, P_STOP_MAX_NODES); return; }
        uint32_t nx = (uint32_t)ps->next;
        uint32_t target = nx & NEXT_ADDR_MASK;

        if (nx & NEXT_ENCAP_BIT) {                /* encapsulation node */
            if (++ps->encap > ps->max_encap) { fail_parser(ps, P_STOP_ENCAP_DEPTH); return; }
        }
        if (nx & NEXT_OVERLAY_BIT) {
            /* overlay: offsets / lengths unchanged */
        } else {                                  /* normal transition */
            ps->cur.off += ps->cur.len;
            ps->dat.off  = ps->cur.off;
            ps->cur.len  = 0;
            ps->dat.len  = 0;
            ps->databound = 0xFFFFFFFFu;
        }
        ps->loop = P_OKAY_RET;                     /* arm Loop for next node */
        ps->next = P_STOP_OKAY;                    /* "no Next set" at the destination */
        goto_ins(ps, target);
    } else if (IS_OK_CODE(ps->next)) {            /* Next = OK code -> normal exit */
        okay_parser(ps);
    } else {                                       /* Next = error code */
        fail_parser(ps, ps->next);
    }
}

/* ---- interpreter ---- */
static void exec_one(pstate *ps, const instr *in)
{
    switch (in->op) {
    case OP_INITPARSER: break;                    /* handled by pm_init */
    case OP_LOAD:      execute_load(ps, in);      break;
    case OP_LENCUR:    execute_lencur(ps, in);    break;
    case OP_CMPIB:     execute_cmpib(ps, in);     break;
    case OP_CMPINEB:   execute_cmpineb(ps, in);   break;
    case OP_CMPORD:    execute_cmpord(ps, in);    break;
    case OP_CAM:       execute_cam(ps, in);       break;
    case OP_CAMNEXT:   execute_camnext(ps, in);   break;
    case OP_STORE:     execute_store(ps, in);     break;
    case OP_STOREIMM:  execute_storeimm(ps, in);  break;
    case OP_NEXTNODE:  execute_nextnode(ps, in);  break;
    case OP_SETCODE:   execute_setcode(ps, in);   break;
    case OP_STP:       common_end_of_node(ps);    break;
    default:           fail_parser(ps, P_STOP_FAIL); break;
    }
}

int32_t pm_run(pstate *ps, const instr *prog, size_t n)
{
    ps->next_pc = 0;
    unsigned guard = 0;
    while (!ps->done) {
        if (ps->next_pc >= n) { fail_parser(ps, P_STOP_FAIL); break; }  /* ran off the end */
        if (++guard > 100000u) { fail_parser(ps, P_STOP_LOOP_CNT); break; } /* infinite-loop guard */
        ps->pc = ps->next_pc;
        ps->next_pc = ps->pc + 1;                 /* default: fall through */
        if (ps->trace) ps->trace(ps, &prog[ps->pc], ps->trace_ctx);
        exec_one(ps, &prog[ps->pc]);
    }
    return ps->code;
}
