// customext/parser_ext.cc — a Spike "customext" extension that teaches the reference
// Spike the parser ISA (custom-0 parse ops + custom-3 coprocessor moves), so the
// RVFI-vs-Spike tandem can lock-step PARSER instructions, not just the base ISA.
//
// This file is compiled INTO libcustomext.so by nix/spike-tandem.nix, which copies
// it — together with the pure-C reference model (parser.c/encoding.c) — into the
// vendored spike tree's customext/ and adds them to customext_srcs. Activation is
// via the "extensions" param ("parser"), set from the CVA6 UVM side.
//
// Design (see the plan / docs/analysis/cva6-verification-design.md §2.6.2):
//   * The extension owns its OWN parser machine state (libparsermodel `pstate`),
//     an independent authoritative model. Because the base ISA is already lock-
//     stepped, the only external input to parser state (rs1 on CPPRSWR) already
//     matches the core, so no state is copied across — rd/pc parity follows from
//     both sides running identical semantics from identical reset.
//   * `next_pc` is an instruction-INDEX register (rtl/cva6_parser_wrap.sv:372-383):
//     a custom-0 op falls through (+1) or redirects to a target index; the byte
//     redirect is pc + ((next_pc_n - next_pc_q) << 2). A custom-3 move never
//     touches it. Parser exit with no MMIO falls through to pc+4.
//   * read_preg/write_preg reproduce the golden field packing in
//     cva6_parser_wrap.sv:225-274 exactly, so CPPRSRD's rd1_wdata matches the core.
//
// NOT handled here (Stage 1c): the 0x5000_0000 MMIO packet buffer. Packet-load ops
// (PLOAD/PLENCUR) decode fine but exec against an empty window and would diverge
// from the core's empty-window load; the Stage-1b directed test excludes them.

#define DECODE_MACRO_USAGE_LOGGED 1
#include "decode_macros.h"
#include "extension.h"

#include <vector>
#include <cstring>
#include <cstdint>

extern "C" {
#include "parser.h"
#include "encoding.h"
}

// Stage 1c: the MMIO packet buffer shared with the tandem Spike's parser_mmio_dev
// (libriscv). g_parser_shared holds the CPU-stored packet/ParseLen/exit-PC and the
// model's code/exit_seen/flow_keys served back on STATUS/META reads.
#include "parser_shared.h"

#define EXTENSION_NAME "parser"

// Field widths mirroring rtl/parser_pkg.sv (PKT_OFF_W, PC_W, CAM_DEPTH).
static const unsigned PARSER_PKT_OFF_W = 9;
static const unsigned PARSER_PC_W      = 10;
static const unsigned PARSER_CAM_DEPTH = 32;

class parser_t : public extension_t
{
 public:
  const char* name() override { return EXTENSION_NAME; }

  parser_t() { reset(); }

  void reset() override {
    std::memset(&ps, 0, sizeof(ps));
    std::memset(&meta, 0, sizeof(meta));
    std::memset(zero_pkt, 0, sizeof(zero_pkt));
    pm_init(&ps, zero_pkt, 0, &meta);
    cam_clear();
    armed = false;                                   // Stage 1c: re-arm each parse
    std::memset(&g_parser_shared, 0, sizeof(g_parser_shared));
  }

  std::vector<insn_desc_t> get_instructions() override {
    std::vector<insn_desc_t> insns;
    // custom-0 (parse ops) and custom-3 (coprocessor moves). Same handler in all
    // eight rv32/rv64 * fast/logged slots (the tandem runs rv64, logged path).
    insns.push_back((insn_desc_t){0x0b, 0x7f, c0, c0, c0, c0, c0, c0, c0, c0});
    insns.push_back((insn_desc_t){0x7b, 0x7f, c3, c3, c3, c3, c3, c3, c3, c3});
    return insns;
  }

  std::vector<disasm_insn_t*> get_disasms() override { return {}; }

  // ---- parser machine state owned by this extension ----
  pstate           ps;
  struct flow_keys meta;
  struct cam_entry ents[PARSER_CAM_DEPTH];
  struct cam_table cam;
  uint8_t          zero_pkt[16];
  bool             armed = false;   // Stage 1c: pstate bound to the MMIO packet yet?

  // Stage 1c: bind the model to the MMIO packet window the CPU filled via `sd`
  // (packet + ParseLen) before the parse block ran. pkthdrbase -> the device packet
  // buffer; meta -> the device-visible flow_keys frame, so the model writes metadata
  // straight where `ld PARSER_META` reads it. The CAM (ents/cam), programmed by the
  // custom-3 ops that precede the parse block, is separate and survives. In the 1b
  // inline path (no MMIO stores) g_parser_shared is all-zero, so this reduces to an
  // empty window with parse_len 0 — reproducing today's packet-independent behavior.
  void arm() {
    pm_init(&ps, g_parser_shared.pkt, g_parser_shared.parse_len,
            (struct flow_keys*)g_parser_shared.meta);
    armed = true;
  }

  void cam_clear() {
    // A sentinel that no valid {4-bit share, 16-bit match} key can hit.
    for (unsigned i = 0; i < PARSER_CAM_DEPTH; i++) {
      ents[i].share  = 0xFFFF;
      ents[i].match  = 0xFFFFFFFFu;
      ents[i].target = (int32_t)0xFFFFFFFF;
    }
    cam.ents = ents;
    cam.n    = PARSER_CAM_DEPTH;
  }

  // ---- read_preg: golden CPPRSRD packing (cva6_parser_wrap.sv:225-239) ----
  uint64_t read_preg(unsigned sel) {
    const uint32_t off_mask = (1u << PARSER_PKT_OFF_W) - 1;
    const uint32_t pc_mask  = (1u << PARSER_PC_W) - 1;
    switch (sel) {
      case 1:  return ((uint64_t)(ps.cur.len & off_mask) << PARSER_PKT_OFF_W)
                    |  (uint64_t)(ps.cur.off & off_mask);                 // p1  CurHdr*
      case 2:  return ((uint64_t)(ps.dat.len & off_mask) << PARSER_PKT_OFF_W)
                    |  (uint64_t)(ps.dat.off & off_mask);                 // p2  DataHdr*
      case 6:  return (uint64_t)ps.node_cnt;                             // p6  NodeLoopCnt
      case 7:  return (uint64_t)ps.encap;                               // p7  Counters/encap
      case 8:  return (uint64_t)(ps.next_pc & pc_mask);                 // p8  NextPc
      case 9:  return (uint64_t)(ps.done & 1);                          // p9  Done (RO)
      case 11: return (uint64_t)(int64_t)(int32_t)ps.next;              // p11 Next  (sext32)
      case 13: return ((uint64_t)(uint32_t)ps.loop << 32)
                    |  (uint64_t)ps.databound;                          // p13 DataBndLoop
      case 14: return (uint64_t)(int64_t)(int32_t)ps.code;              // p14 ExitCode (sext32)
      case 15: return ps.accum;                                        // p15 Accum
      case 16: return ps.flags;                                        // p16 Flags
      default: return 0;                                               // outside subset: 0
    }
  }

  // ---- write_preg: golden CPPRSWR inverse (cva6_parser_wrap.sv:256-274) ----
  void write_preg(unsigned sel, uint64_t v) {
    const uint32_t off_mask = (1u << PARSER_PKT_OFF_W) - 1;
    const uint32_t pc_mask  = (1u << PARSER_PC_W) - 1;
    switch (sel) {
      case 1:  ps.cur.off = (uint32_t)(v & off_mask);
               ps.cur.len = (uint32_t)((v >> PARSER_PKT_OFF_W) & off_mask); break;
      case 2:  ps.dat.off = (uint32_t)(v & off_mask);
               ps.dat.len = (uint32_t)((v >> PARSER_PKT_OFF_W) & off_mask); break;
      case 6:  ps.node_cnt = (uint16_t)(v & 0xFFFF); break;
      case 7:  ps.encap    = (uint8_t)(v & 0xFF); break;
      case 8:  ps.next_pc  = (uint32_t)(v & pc_mask); break;
      case 11: ps.next     = (int32_t)(uint32_t)v; break;
      case 13: ps.databound = (uint32_t)v; ps.loop = (int32_t)(uint32_t)(v >> 32); break;
      case 14: ps.code     = (int32_t)(uint32_t)v; break;
      case 15: ps.accum    = v; break;
      case 16: ps.flags    = v; break;
      default: break;   // p9 (done) is read-only; anything else ignored
    }
  }

 private:
  static parser_t* self(processor_t* p) {
    return static_cast<parser_t*>(p->get_extension(EXTENSION_NAME));
  }

  // ---- custom-0 handler: a parse micro-op advances the model + computes redirect --
  static reg_t c0(processor_t* p, insn_t insn, reg_t pc) {
    parser_t* e = self(p);
    instr d;
    if (pm_decode((uint32_t)insn.bits(), &d) != 0)
      return ::illegal_instruction(p, insn, pc);   // reserved / packet-only Fnc4
    if (d.op == OP_CAM || d.op == OP_CAMNEXT)
      d.cam = &e->cam;                            // attach the programmed table
    if (!e->armed) e->arm();                       // Stage 1c: bind to the MMIO packet
    uint32_t cur = e->ps.next_pc;
    e->ps.pc      = cur;                          // pm_run's per-step bookkeeping...
    e->ps.next_pc = cur + 1;                      // ...default fall-through
    pm_exec_one(&e->ps, &d);
    // custom-0 writes no integer rd (the core forces rd=x0) -> no WRITE_RD.
    // Publish the running verdict so a later `ld PARSER_STATUS` (device 0x100) matches.
    g_parser_shared.code      = e->ps.code;
    g_parser_shared.exit_seen = e->ps.done ? 1 : 0;
    if (e->ps.done)                               // parser exit
      return g_parser_shared.exit_pc ? (reg_t)g_parser_shared.exit_pc  // MMIO: return
                                     : pc + 4;    // 1b inline: fall through
    int64_t delta = (int64_t)e->ps.next_pc - (int64_t)cur;
    if (delta == 1) return pc + 4;                // fall-through
    return pc + (reg_t)(delta << 2);              // == redirect_pc_calc
  }

  // ---- custom-3 handler: coprocessor moves (register / CAM I/O, no node advance) --
  static reg_t c3(processor_t* p, insn_t insn, reg_t pc) {
    parser_t* e = self(p);
    uint32_t w = (uint32_t)insn.bits();
    unsigned cpreg = prs_get(w, 28, 24);
    unsigned C     = prs_get(w, 23, 23);   // CPPRSWRCAM delete flag (D)
    unsigned I     = prs_get(w, 21, 21);   // immediate form
    unsigned R     = prs_get(w, 20, 20);   // 1 = CAM op
    unsigned func3 = prs_get(w, 14, 12);

    if (I) {   // CPPRSWRIMM: p[cpreg] <- 11-bit split immediate {R, Rs, Rd}
      unsigned imm = ((prs_get(w, 20, 20) & 1u) << 10)
                   |  (prs_get(w, 19, 15) << 5)
                   |   prs_get(w, 11, 7);
      e->write_preg(cpreg, imm);
      return pc + 4;
    }
    if (R == 0 && func3 == 0) {             // CPPRSRD: rd <- p[cpreg]
      WRITE_RD(e->read_preg(cpreg));
      return pc + 4;
    }
    if (R == 0 && func3 == 1) {             // CPPRSWR: p[cpreg] <- rs1
      e->write_preg(cpreg, RS1);
      return pc + 4;
    }
    if (R == 1 && func3 == 0) {             // CPPRSRDCAM: rd <- CAM lookup(key=rs1)
      uint64_t k     = RS1;
      unsigned share = (unsigned)((k >> 16) & 0xF);
      uint32_t match = (uint32_t)(k & 0xFFFF);
      bool hit = false; int32_t tgt = (int32_t)0xFFFFFFFF;
      for (unsigned i = 0; i < e->cam.n; i++)
        if (e->ents[i].share == share && e->ents[i].match == match) { tgt = e->ents[i].target; hit = true; break; }
      WRITE_RD(hit ? (reg_t)(uint32_t)tgt                     // hit: {32'h0, target}
                   : (reg_t)0xFFFFFFFFFFFFFFFFull);           // miss: all-ones
      return pc + 4;
    }
    if (R == 1 && func3 == 1) {             // CPPRSWRCAM: program CAM[index=rs1] from p[cpreg]
      uint64_t src = e->read_preg(cpreg);   // {share@[51:48], match@[47:32], target@[31:0]}
      unsigned idx = (unsigned)(RS1 & (PARSER_CAM_DEPTH - 1));
      if (C) {                              // delete
        e->ents[idx].share = 0xFFFF; e->ents[idx].match = 0xFFFFFFFFu;
        e->ents[idx].target = (int32_t)0xFFFFFFFF;
      } else {
        e->ents[idx].share  = (uint16_t)((src >> 48) & 0xF);
        e->ents[idx].match  = (uint32_t)((src >> 32) & 0xFFFF);
        e->ents[idx].target = (int32_t)(uint32_t)src;
      }
      return pc + 4;
    }
    return ::illegal_instruction(p, insn, pc);
  }
};

REGISTER_EXTENSION(parser, []() { return new parser_t; })
