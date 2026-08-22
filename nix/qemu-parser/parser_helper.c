/*
 * parser_helper.c — TCG helpers for the parser custom instructions (Phase 7 QEMU
 * leg). A 1:1 port of nix/spike-tandem/parser_ext.cc's c0/c3 handlers +
 * read_preg/write_preg + reset, reusing model/libparsermodel unchanged.
 *
 *   custom-0 (0x0b): a parse micro-op. Steps the model one instruction and
 *     returns the next guest PC (fall-through pc+4, redirect pc+(delta<<2), or the
 *     MMIO exit PC). Writes no integer register. See helper_parser_c0.
 *   custom-3 (0x7b): coprocessor moves (p-register + CAM I/O). Reads rs1, may
 *     write rd, never redirects. See helper_parser_c3.
 *
 * The parser engine state (pstate + the 32-entry CAM + armed) is a process global,
 * shared with the MMIO device (parser_mmio.c) via g_parser_shared — correct for a
 * single-hart softmmu test machine, mirroring Spike's g_parser_shared.
 */
#include "qemu/osdep.h"
#include "cpu.h"
#include "exec/helper-proto.h"
#include "accel/tcg/cpu-ldst.h"

#include "parser.h"                 /* pstate, flow_keys, cam_*, pm_* (libparsermodel) */
#include "parsermodel_encoding.h"   /* prs_get, pm_decode                             */
#include "parser_shared.h"

/* Field widths mirroring rtl/parser_pkg.sv (PKT_OFF_W, PC_W, CAM_DEPTH). */
#define PARSER_PKT_OFF_W 9u
#define PARSER_PC_W      10u
#define PARSER_CAM_DEPTH 32u

/* ---- parser machine state owned here (shared with the device via globals) ---- */
static pstate           g_ps;
static struct flow_keys g_reset_meta;
static struct cam_entry g_ents[PARSER_CAM_DEPTH];
static struct cam_table g_cam;
static uint8_t          g_zero_pkt[16];
static bool             g_armed;      /* pstate bound to the MMIO packet yet? */

static void cam_clear(void)
{
    /* A sentinel that no valid {4-bit share, 16-bit match} key can hit. */
    for (unsigned i = 0; i < PARSER_CAM_DEPTH; i++) {
        g_ents[i].share  = 0xFFFF;
        g_ents[i].match  = 0xFFFFFFFFu;
        g_ents[i].target = (int32_t)0xFFFFFFFF;
    }
    g_cam.ents = g_ents;
    g_cam.n    = PARSER_CAM_DEPTH;
}

/* Reset the engine + the shared mailbox (registered as a QEMU reset hook). */
void parser_reset(void *opaque)
{
    memset(&g_ps, 0, sizeof(g_ps));
    memset(&g_reset_meta, 0, sizeof(g_reset_meta));
    memset(g_zero_pkt, 0, sizeof(g_zero_pkt));
    pm_init(&g_ps, g_zero_pkt, 0, &g_reset_meta);
    cam_clear();
    g_armed = false;
    memset(&g_parser_shared, 0, sizeof(g_parser_shared));
}

/* Bind the model to the MMIO packet window the CPU filled via `sd` (packet +
 * ParseLen) before the parse block ran. The CAM, programmed by the custom-3 ops
 * that precede the parse block, is separate and survives. */
static void parser_arm(void)
{
    pm_init(&g_ps, g_parser_shared.pkt, g_parser_shared.parse_len,
            (struct flow_keys *)g_parser_shared.meta);
    g_armed = true;
}

/* ---- read_preg: golden CPPRSRD packing (cva6_parser_wrap.sv:225-239) ---- */
static uint64_t read_preg(unsigned sel)
{
    const uint32_t off_mask = (1u << PARSER_PKT_OFF_W) - 1;
    const uint32_t pc_mask  = (1u << PARSER_PC_W) - 1;
    switch (sel) {
    case 1:  return ((uint64_t)(g_ps.cur.len & off_mask) << PARSER_PKT_OFF_W)
                  |  (uint64_t)(g_ps.cur.off & off_mask);          /* p1  CurHdr*   */
    case 2:  return ((uint64_t)(g_ps.dat.len & off_mask) << PARSER_PKT_OFF_W)
                  |  (uint64_t)(g_ps.dat.off & off_mask);          /* p2  DataHdr*  */
    case 6:  return (uint64_t)g_ps.node_cnt;                       /* p6  NodeLoopCnt */
    case 7:  return (uint64_t)g_ps.encap;                          /* p7  Counters/encap */
    case 8:  return (uint64_t)(g_ps.next_pc & pc_mask);            /* p8  NextPc    */
    case 9:  return (uint64_t)(g_ps.done & 1);                     /* p9  Done (RO) */
    case 11: return (uint64_t)(int64_t)(int32_t)g_ps.next;         /* p11 Next  (sext32) */
    case 13: return ((uint64_t)(uint32_t)g_ps.loop << 32)
                  |  (uint64_t)g_ps.databound;                     /* p13 DataBndLoop */
    case 14: return (uint64_t)(int64_t)(int32_t)g_ps.code;         /* p14 ExitCode (sext32) */
    case 15: return g_ps.accum;                                    /* p15 Accum     */
    case 16: return g_ps.flags;                                    /* p16 Flags     */
    default: return 0;                                             /* outside subset: 0 */
    }
}

/* ---- write_preg: golden CPPRSWR inverse (cva6_parser_wrap.sv:256-274) ---- */
static void write_preg(unsigned sel, uint64_t v)
{
    const uint32_t off_mask = (1u << PARSER_PKT_OFF_W) - 1;
    const uint32_t pc_mask  = (1u << PARSER_PC_W) - 1;
    switch (sel) {
    case 1:  g_ps.cur.off = (uint32_t)(v & off_mask);
             g_ps.cur.len = (uint32_t)((v >> PARSER_PKT_OFF_W) & off_mask); break;
    case 2:  g_ps.dat.off = (uint32_t)(v & off_mask);
             g_ps.dat.len = (uint32_t)((v >> PARSER_PKT_OFF_W) & off_mask); break;
    case 6:  g_ps.node_cnt  = (uint16_t)(v & 0xFFFF); break;
    case 7:  g_ps.encap     = (uint8_t)(v & 0xFF); break;
    case 8:  g_ps.next_pc   = (uint32_t)(v & pc_mask); break;
    case 11: g_ps.next      = (int32_t)(uint32_t)v; break;
    case 13: g_ps.databound = (uint32_t)v; g_ps.loop = (int32_t)(uint32_t)(v >> 32); break;
    case 14: g_ps.code      = (int32_t)(uint32_t)v; break;
    case 15: g_ps.accum     = v; break;
    case 16: g_ps.flags     = v; break;
    default: break;   /* p9 (done) is read-only; anything else ignored */
    }
}

/* ---- custom-0: a parse micro-op advances the model + computes the redirect ---- */
target_ulong HELPER(parser_c0)(CPURISCVState *env, uint32_t insn, target_ulong pc)
{
    instr d;
    uint32_t cur;
    int64_t delta;

    if (pm_decode(insn, &d) != 0) {
        riscv_raise_exception(env, RISCV_EXCP_ILLEGAL_INST, GETPC());
    }
    if (d.op == OP_CAM || d.op == OP_CAMNEXT) {
        d.cam = &g_cam;                       /* attach the programmed table */
    }
    if (!g_armed) {
        parser_arm();                         /* lazily bind to the MMIO packet */
    }
    cur = g_ps.next_pc;
    g_ps.pc      = cur;                        /* pm_run's per-step bookkeeping... */
    g_ps.next_pc = cur + 1;                    /* ...default fall-through          */
    pm_exec_one(&g_ps, &d);
    /* custom-0 writes no integer rd (the core forces rd=x0). Publish the running
     * verdict so a later `ld PARSER_STATUS` (device 0x100) matches. */
    g_parser_shared.code      = g_ps.code;
    g_parser_shared.exit_seen = g_ps.done ? 1 : 0;
    if (g_ps.done) {                          /* parser exit */
        return g_parser_shared.exit_pc ? (target_ulong)g_parser_shared.exit_pc
                                       : pc + 4;   /* inline: fall through */
    }
    delta = (int64_t)g_ps.next_pc - (int64_t)cur;
    if (delta == 1) {
        return pc + 4;                        /* fall-through */
    }
    return pc + (target_ulong)(delta << 2);   /* redirect */
}

/* ---- custom-3: coprocessor moves (register / CAM I/O, no node advance) ---- */
void HELPER(parser_c3)(CPURISCVState *env, uint32_t insn)
{
    uint32_t w = insn;
    unsigned cpreg = prs_get(w, 28, 24);
    unsigned C     = prs_get(w, 23, 23);   /* CPPRSWRCAM delete flag (D) */
    unsigned I     = prs_get(w, 21, 21);   /* immediate form            */
    unsigned R     = prs_get(w, 20, 20);   /* 1 = CAM op                */
    unsigned func3 = prs_get(w, 14, 12);
    unsigned rs1n  = prs_get(w, 19, 15);
    unsigned rdn   = prs_get(w, 11, 7);
    target_ulong rs1 = rs1n ? env->gpr[rs1n] : 0;

    if (I) {   /* CPPRSWRIMM: p[cpreg] <- 11-bit split immediate {R, Rs, Rd} */
        unsigned imm = ((prs_get(w, 20, 20) & 1u) << 10)
                     |  (prs_get(w, 19, 15) << 5)
                     |   prs_get(w, 11, 7);
        write_preg(cpreg, imm);
        return;
    }
    if (R == 0 && func3 == 0) {             /* CPPRSRD: rd <- p[cpreg] */
        if (rdn) {
            env->gpr[rdn] = read_preg(cpreg);
        }
        return;
    }
    if (R == 0 && func3 == 1) {             /* CPPRSWR: p[cpreg] <- rs1 */
        write_preg(cpreg, rs1);
        return;
    }
    if (R == 1 && func3 == 0) {             /* CPPRSRDCAM: rd <- CAM lookup(key=rs1) */
        unsigned share = (unsigned)((rs1 >> 16) & 0xF);
        uint32_t match = (uint32_t)(rs1 & 0xFFFF);
        bool hit = false;
        int32_t tgt = (int32_t)0xFFFFFFFF;
        for (unsigned i = 0; i < g_cam.n; i++) {
            if (g_ents[i].share == share && g_ents[i].match == match) {
                tgt = g_ents[i].target;
                hit = true;
                break;
            }
        }
        if (rdn) {
            env->gpr[rdn] = hit ? (target_ulong)(uint32_t)tgt   /* hit: {32'h0, target} */
                                : (target_ulong)0xFFFFFFFFFFFFFFFFull; /* miss: all-ones */
        }
        return;
    }
    if (R == 1 && func3 == 1) {             /* CPPRSWRCAM: program CAM[rs1] from p[cpreg] */
        uint64_t src = read_preg(cpreg);    /* {share@[51:48], match@[47:32], target@[31:0]} */
        unsigned idx = (unsigned)(rs1 & (PARSER_CAM_DEPTH - 1));
        if (C) {                            /* delete */
            g_ents[idx].share  = 0xFFFF;
            g_ents[idx].match  = 0xFFFFFFFFu;
            g_ents[idx].target = (int32_t)0xFFFFFFFF;
        } else {
            g_ents[idx].share  = (uint16_t)((src >> 48) & 0xF);
            g_ents[idx].match  = (uint32_t)((src >> 32) & 0xFFFF);
            g_ents[idx].target = (int32_t)(uint32_t)src;
        }
        return;
    }
    riscv_raise_exception(env, RISCV_EXCP_ILLEGAL_INST, GETPC());
}
