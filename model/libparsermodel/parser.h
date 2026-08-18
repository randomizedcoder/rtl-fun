/*
 * libparsermodel — golden reference model for the parser-instruction ISA.
 *
 * The single architectural source of truth (docs/phase-2-reference-model.md).
 * Each execute_* mirrors, 1:1, a routine in the NORMATIVE Phase-1 semantics
 * (docs/phase-1-isa-semantics.md, §-refs on each function). Everything
 * downstream (RTL, sims, toolchain) is verified against this model, not prose.
 *
 * Scope of THIS file: the vertical-slice smoke path — Ethernet -> IPv4/IPv6 ->
 * TCP/UDP -> flow_keys. Loop heads / TLV / flag-fields (IPv4 options, IPv6 ext
 * headers, GRE flags) are declared where relevant and land in the follow-up.
 */
#ifndef LIBPARSERMODEL_PARSER_H
#define LIBPARSERMODEL_PARSER_H

#include <stdint.h>
#include <stddef.h>

/* ------------------------------------------------------------------ *
 * Parser codes — negative bytes (Phase-1 §1.4; encodings §4).        *
 * The model's exit status uses these exact values so Phase-6 co-sim   *
 * compares real status.                                               *
 * ------------------------------------------------------------------ */
enum parser_code {
    P_OKAY               =   0,
    P_OKAY_RET           =  -1,
    P_OKAY_USE_WILD      =  -2,
    P_OKAY_USE_ALT_WILD  =  -3,
    P_STOP_OKAY          =  -4,
    P_STOP_NODE_OKAY     =  -5,
    P_STOP_SUB_NODE_OKAY =  -6,
    P_STOP_FAIL          = -13,   /* normal (> -13) | abnormal (<= -13) split */
    P_STOP_LENGTH        = -14,
    P_STOP_UNKNOWN_PROTO = -15,
    P_STOP_ENCAP_DEPTH   = -16,
    P_STOP_TLV_LENGTH    = -18,
    P_STOP_LOOP_CNT      = -21,
    P_STOP_OPTION_LIMIT  = -23,
    P_STOP_MAX_NODES     = -24,
    P_STOP_COMPARE       = -25,
};
#define IS_RET_CODE(x) ((int32_t)(x) < 0)                    /* patent L1823 */
#define IS_OK_CODE(x)  (IS_RET_CODE(x) && (int32_t)(x) > P_STOP_FAIL)

/* Next-register control bits (encodings §3). */
#define NEXT_ENCAP_BIT   0x40000000u
#define NEXT_OVERLAY_BIT 0x20000000u
#define NEXT_CODE_BIT    0x80000000u
#define NEXT_ADDR_MASK   0x00FFFFFFu
#define NEXT_CTRL_MASK   0x7F000000u

/* ------------------------------------------------------------------ *
 * flow_keys — the metadata frame the slice populates. PSTORE writes   *
 * sub-registers here at the byte offsets below (offsetof used by the  *
 * parse program). Addresses/ports are stored in network byte order.   *
 * ------------------------------------------------------------------ */
struct flow_keys {
    uint16_t n_proto;      /* EtherType (host order)          */
    uint8_t  ip_proto;     /* IP protocol / next-header        */
    uint8_t  addr_type;    /* 4 = IPv4, 6 = IPv6, 0 = none     */
    uint32_t ipv4_src;     /* network order                    */
    uint32_t ipv4_dst;
    uint8_t  ipv6_src[16];
    uint8_t  ipv6_dst[16];
    uint16_t sport;        /* network order                    */
    uint16_t dport;
};

/* ------------------------------------------------------------------ *
 * Machine state (Phase-1 §1.1). One struct per {offset,length} header.*
 * ------------------------------------------------------------------ */
typedef struct { uint32_t off, len; } hdr_t;

typedef struct {
    /* packet + parse buffer */
    const uint8_t *pkthdrbase;     /* PktHdrBase (p8) */
    uint32_t all_len;              /* PktLen.AllLen   */
    uint32_t parse_len;            /* PktLen.ParseLen */
    uint8_t  P;                    /* PktLen.P — all header bytes present */

    /* two-level cursors */
    hdr_t    cur;                  /* CurHdr  (p1)  offset+length */
    hdr_t    dat;                  /* DataHdr (p2)  offset+length */
    uint32_t databound;           /* DataBndLoop.DataBound (init 0xFFFFFFFF) */
    int32_t  loop;                /* DataBndLoop.Loop — address or code */

    /* working registers */
    uint64_t accum;               /* Accum (p15) */
    uint64_t flags;               /* Flags (p16) */
    int32_t  next;                /* Next  (p11) — address or code + ctrl bits */

    /* counters / encap */
    uint8_t  encap;               /* Counters.Encap */
    uint8_t  cntr[7];             /* Counters.Cntr1..7 */
    uint16_t nonpad_cnt;          /* NodeLoopCnt.NonPadCnt */
    uint16_t node_cnt;            /* NodeLoopCnt.NodeCnt   */

    /* metadata frame (the slice: a single flow_keys) */
    struct flow_keys *meta;

    /* control */
    uint32_t pc;                  /* index of the current instruction   */
    uint32_t next_pc;             /* interpreter: where to fetch next    */
    int      done;                /* set when the parser has exited      */
    int32_t  code;                /* ParserExitCode.Error (exit status)  */

    /* config (read-only after init) */
    uint16_t max_nodes;
    uint8_t  max_encap;

    /* optional trace hook: if non-NULL, pm_run calls it *before* executing each
     * instruction. Zero cost when NULL. Args are (pstate*, instr*) as void* to
     * avoid a forward-declaration cycle; tools/pm-trace uses it. */
    void (*trace)(const void *ps, const void *in, void *ctx);
    void *trace_ctx;
} pstate;

/* ------------------------------------------------------------------ *
 * Decoded instruction + program (Phase-2 §2.2). The program is a      *
 * table of decoded instructions the interpreter walks; the SAME table  *
 * is what Phase-3 encodes and Phase-6 runs on RTL.                     *
 * ------------------------------------------------------------------ */
enum opcode {
    OP_INITPARSER = 0,
    OP_LOAD,          /* PLOAD */
    OP_LENCUR,        /* PLENCUR (lenset / lensetmin) */
    OP_CMPIB,         /* PCMPIB (masked byte eq) */
    OP_CMPINEB,       /* PCMPINEB */
    OP_CMPORD,        /* PCMPI{LT,LE,GT,GE}B */
    OP_CAM,           /* PCAM  -> Accum */
    OP_CAMNEXT,       /* PCAMNEXT -> Next */
    OP_STORE,         /* PSTORE */
    OP_STOREIMM,      /* PSTOREIMM */
    OP_NEXTNODE,      /* PNEXTNODE */
    OP_SETCODE,       /* PSETCODE */
    OP_STP,           /* PSTP */
    OP__COUNT
};

/* CAM entry: 20-bit key + 32-bit target (encodings §3). Model uses a
 * linear table; share!=0 = shared table, share==0 = PC-derived selector. */
struct cam_entry { uint16_t share; uint32_t match; int32_t target; };
struct cam_table { const struct cam_entry *ents; size_t n; };

typedef struct instr {
    enum opcode op;
    /* operands (union-ish; only the fields the op uses are read) */
    unsigned sz, pos, shift, blen;
    int      x, e, d, s;            /* X/E/D/S bits */
    int      f, j;                  /* F (frame/flags) bits */
    uint32_t offset;               /* load/store displacement */
    uint32_t value, mask;          /* compare/store immediate */
    unsigned func3, er;            /* ordered-compare op / on-false action */
    unsigned share;                /* CAM table id (0 = PC selector) */
    unsigned miss;                 /* CAM miss disposition */
    const struct cam_table *cam;   /* CAM table for this lookup */
    int32_t  payload;              /* PNEXTNODE target (instr index) / SETCODE code */
} instr;

/* CAM miss dispositions (Phase-1 §2.6). */
enum cam_miss { MISS_WILD = 0, MISS_ALT, MISS_STOP, MISS_STOPSUB, MISS_FAIL, MISS_FAILSUB };
/* on-false actions for compare (Phase-1 §2.8). */
enum cmp_er   { ER_STOP = 0, ER_STOPNODE, ER_STOPSUB, ER_FAIL };

/* ------------------------------------------------------------------ *
 * Public API                                                          *
 * ------------------------------------------------------------------ */

/* Initialise state for a PDU. pkt/len is the whole frame; meta is the
 * caller-owned flow_keys the program stores into. (PINITPARSER, §4.1) */
void pm_init(pstate *ps, const uint8_t *pkt, uint32_t len, struct flow_keys *meta);

/* Run a decoded program to completion; returns the exit parser code. */
int32_t pm_run(pstate *ps, const instr *prog, size_t n);

/* Execute a single decoded instruction against `ps` (one step of pm_run's loop,
 * without the fetch/PC bookkeeping). The caller drives ps->pc / ps->next_pc.
 * Used by out-of-tree steppers (the Spike tandem parser extension) that fetch
 * instructions themselves. */
void pm_exec_one(pstate *ps, const instr *in);

/* Sub-register extract (Phase-1 §1.3): big-endian numbering, Pos 0 = the
 * most-significant sub-register of the given width. */
uint64_t pm_extract_subreg(uint64_t val, unsigned sz, unsigned pos);

/* The slice parse program (Ethernet -> IPv4/IPv6 -> TCP/UDP). Returns the
 * program table and sets *n. Defined in program.c. */
const instr *pm_slice_program(size_t *n);

#endif /* LIBPARSERMODEL_PARSER_H */
