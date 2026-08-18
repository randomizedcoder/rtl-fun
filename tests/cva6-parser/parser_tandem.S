# parser_tandem.S — parser-op RVFI-vs-Spike lock-step directed test (Phase 7, Stage 1b).
#
# The base-ISA tandem (Stage 0, base_isa.S) proved every retired RV64GC instruction
# matches a reference Spike. This test extends that oracle to the PARSER ISA: every
# custom-0 / custom-3 op below is stepped against the parser-extended Spike
# (nix/spike-tandem/parser_ext.cc) and the scoreboard checks insn / rd / pc match.
#
# SCOPE (Stage 1b): packet-INDEPENDENT ops only. PLOAD/PLENCUR read the 0x5000_0000
# MMIO packet window, which Spike does not model until Stage 1c — with an empty
# in-core window the core's load retires while the model's bounds check exits, a
# pc_wdata divergence. So this test carries NO PLOAD: it drives parser state from
# the integer side (CPPRSWR) and checks it back, exactly the parser_insn.S pattern.
#
# Layout note: the parser's node index (`next_pc`) counts only custom-0 ops and is
# decoupled from the byte PC; a redirect is pc + ((next_pc_n - next_pc_q) << 2), so a
# custom-0 redirect target must be `delta` custom-0 ops ahead AND `delta` instructions
# ahead in memory (a contiguous .word block). Custom-3 ops never advance next_pc, so
# the custom-3 sections below leave the redirect block starting at node index 0.
#
# Each section ALSO program-self-checks its values into tohost, so a green run means
# both "Spike agreed on every op" (the tandem report) AND "the values are correct"
# (fesvr SUCCESS). Run: Variane_testharness parser_tandem.elf  (tohost=1 => PASS).

.section .text.init
.globl _start
_start:
    li   t0, 1                     # assume PASS (tohost=1 => exit 0)

    # --- custom-3 register readback: read p11 (Next) == reset P_STOP_OKAY (-4) ---
    # 0x0B0003FB = prs.mv.x.p t2, p11 (CPPRSRD cpreg=11, Func3=0, Rd=t2). Its rd is
    # lock-stepped: Spike's read_preg(11) sign-extends Next just like cva6_parser_wrap.
    .word 0x0B0003FB               # prs.mv.x.p t2, p11
    li   t3, -4
    beq  t2, t3, 1f
    li   t0, 3                     # p11 readback mismatch => FAIL
1:
    # --- WAW on a parser register: last writer wins (p16 Flags) ---
    li   a0, 0x11
    .word 0x1005107B               # CPPRSWR p16, a0   (Flags <- 0x11)
    li   a0, 0x22
    .word 0x1005107B               # CPPRSWR p16, a0   (Flags <- 0x22, younger wins)
    .word 0x100007FB               # CPPRSRD a5, p16   (a5 <- Flags)
    li   a6, 0x22
    beq  a5, a6, 2f
    li   t0, 5                     # WAW mismatch => FAIL
2:
    # --- CPPRSWRIMM: 11-bit split immediate -> p16, no integer rd clobber ---
    # imm=0x1DC => Imm1=0x1C=t3; preset t3 and prove decode does NOT write x[Imm1].
    li   t3, 0xBEEF
    .word 0x10271E7B               # CPPRSWRIMM p16, 0x1DC  (Flags <- 0x1DC)
    .word 0x100007FB               # CPPRSRD a5, p16
    li   a6, 0xBEEF
    bne  t3, a6, 3f                # t3 clobbered => FAIL
    li   a6, 0x1DC
    beq  a5, a6, 4f
3:  li   t0, 7                     # CPPRSWRIMM mismatch/clobber => FAIL
4:
    # --- CAM program + lookup: program CAM[0], look it up, check rd == target ---
    # CPPRSWR stages {key,target} in Accum(p15); CPPRSWRCAM writes it at index=rs1;
    # CPPRSRDCAM keys {share=rs1[19:16], match=rs1[15:0]} back into rd. The Spike
    # extension mirrors the cva6_parser_wrap staged-word packing (share@[51:48],
    # match@[47:32], target@[31:0]) so the looked-up rd matches under lock-step.
    li   a0, 0x00010800000000CD    # {key=(share1<<16)|0x0800, target=0xCD}
    .word 0x0F05107B               # CPPRSWR  p15, a0
    li   a1, 0                     # CAM index 0
    .word 0x0F15907B               # CPPRSWRCAM a1, p15   (CAM[0] = {share1,0x0800,0xCD})
    li   a3, 0x00010800            # lookup key {share=1, match=0x0800}
    .word 0x0016867B               # CPPRSRDCAM a2, a3    (a2 <- target)
    li   a4, 0xCD
    beq  a2, a4, 5f
    li   t0, 9                     # CAM lookup mismatch => FAIL
5:
    # --- custom-0 end-of-node redirect: skip a poison store, land on the target ---
    # These are the FIRST custom-0 ops, so node indices start at 0:
    #   node0: nextnode payload=2, s=1  -> redirect to node 2 (byte +8), skip node 1
    #   node1: storeimm poison          -> flushed, never retires
    #   node2: storeimm landing         -> retires
    # Spike's c0 handler returns pc + ((2-0)<<2) = pc+8, matching the FU's
    # resolved_branch_o redirect; both sides retire {nextnode, landing}.
    .word 0x8000150B               # prs.nextnode payload=2, s=1   (node 0)
    .word 0x1EE02B0B               # POISON: prs.storeimm 0xEE -> meta[5] (node 1, skipped)
    .word 0x1CC0330B               # landing: prs.storeimm 0xCC -> meta[6] (node 2)

    # --- signal result: tohost = t0 ---
    la   t1, tohost
    sd   t0, 0(t1)
1:  j    1b

#include "htif.S"
