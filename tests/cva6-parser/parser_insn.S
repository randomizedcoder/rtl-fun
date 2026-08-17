# parser_insn.S — in-core directed test for the CVA6 PARSER FU (custom-0).
#
# Proves the decode->issue->EX->writeback chain end to end: the core fetches a
# custom-0 word, the decoder routes it to fu=PARSER, issue hands it to the parser
# FU over the ready/valid handshake, the FU executes one micro-op and retires it
# via its writeback port (custom-0 writes no integer rd), and the pipeline
# advances to the next instruction. If any link in that chain stalled or trapped,
# the core would never reach the tohost store and the run would time out.
#
# Each .word below is a Phase-3 custom-0 encoding (opcode 0x0b). 0x1000000b is a
# prs.load (Fnc4=LOAD, Sz=1/byte, offset 0) — it reads the (empty in-core) packet
# window, updates parser state, and retires without redirect. We issue several
# back-to-back to exercise the single-in-flight interlock + repeated retire.
#
# 0x1AB0230B is a prs.storeimm (Fnc4=STOREIMM, Sz=1/byte, Value=0xAB, Offset=4,
# S=0): it writes the immediate byte 0xAB into the parser metadata frame at offset
# 4. In cva6_parser_wrap that write is COMMIT-GATED — byte-scattered into meta_mem
# only when the op retires (I2, docs/analysis/cva6-verification-design.md §1). The
# testharness I2 backdoor (tb-backdoor.patch) reads meta_mem hierarchically and, the
# cycle 0xAB lands, prints "*** PARSER META OK ***" — the first in-core value-check
# of the parser's metadata sink (gaps G1/G8).
#
# (I4, gap G3) an end-of-node next-node jump then skips a poison store and lands on
# the target store; the backdoor watcher prints "*** PARSER REDIRECT OK ***" when the
# poison was skipped (meta[5]==0) and the target landed (meta[6]==0xCC) — proving the
# FU steered the frontend refetch to the (byte-translated) node target.
#
# Then (I3, gap G4) a custom-3 readback moves parser register p11 (Next) into an
# integer reg and the PROGRAM self-checks it against the expected reset value — a
# program-driven oracle needing no backdoor: a wrong readback writes a nonzero
# tohost (FAIL). This also exercises the parser integer-RF writeback + RAW forwarding.
#
# Then (I4b, gap G3 CAM path) the CAM is PROGRAMMED from the integer side and used:
#   - CPPRSWR stages a {key,target} word in p15 (Accum); CPPRSWRCAM writes it to a CAM
#     index (index = integer rs1); CPPRSRDCAM does a key lookup back into an integer rd,
#     and the PROGRAM self-checks rd == the programmed target (no backdoor).
#   - a second entry is programmed whose target is a node index; a CAMNEXT.s then HITS it
#     and the end-of-node redirect steers fetch over a poison store (meta[8]) onto a
#     landing store (meta[9]=0xDD) — the backdoor prints "*** PARSER CAM REDIRECT OK ***".
# This exercises the rs1 operand threaded from ex_stage + the CAM program port, and
# unblocks OP_CAMNEXT (a programmed CAM entry driving a real fetch redirect).
#
# Then (V4/V5, gap G6) two in-core pipeline checks: a write-after-write to a parser
# register proves the younger write wins (V4), and a custom-3 readback placed back-to-
# back with a mul + CSR read + branches proves the parser writeback port doesn't
# contend with adjacent retires (V5). Both are program-self-checked via tohost.
#
# Finally (N2, §3.1 item 6) the custom-3 immediate-load form CPPRSWRIMM writes a
# p-register from an 11-bit split immediate (no integer operand); the check proves
# both that the immediate reaches the register and that the decode does NOT clobber
# the integer register the reused Rd field would otherwise select.
#
# Run: Variane_testharness parser_insn.elf   (tohost=1 => exit code 0 => PASS)

.section .text.init
.globl _start
_start:
    # --- instructions under test: custom-0 PARSER ops ---
    .word 0x1000000b        # prs.load byte, offset 0
    .word 0x1000000b        # prs.load byte, offset 0
    .word 0x1000000b        # prs.load byte, offset 0
    .word 0x1000000b        # prs.load byte, offset 0
    .word 0x1AB0230B        # prs.storeimm byte 0xAB -> metadata offset 4 (node 4)

    # --- end-of-node redirect (I4, gap G3): a next-node jump skips a poison store ---
    # The parser instructions are a contiguous 4-byte block, so parser node index N
    # maps to byte PC base+N*4. These are nodes 5,6,7:
    #   node5: nextnode payload=7, s=1  -> jump to node 7 (byte +8), skipping node 6
    #   node6: storeimm 0xEE -> meta[5]  -> POISON; must be flushed (never commits)
    #   node7: storeimm 0xCC -> meta[6]  -> landing target; commits
    # The FU translates the node target to a byte PC (pc_i + (7-5)*4) and drives
    # resolved_branch_o(is_mispredict) so the frontend refetches at node7. The I4
    # backdoor watcher checks meta[5]==0 (poison skipped) && meta[6]==0xCC (landed).
    .word 0x80003D0B        # prs.nextnode payload=7, s=1   (node 5)
    .word 0x1EE02B0B        # POISON: prs.storeimm 0xEE -> meta[5] (node 6, skipped)
    .word 0x1CC0330B        # landing: prs.storeimm 0xCC -> meta[6] (node 7)

    # --- custom-3 register readback (I3, gap G4): read p11 (Next) into t2 ---
    # 0x0B0003FB = prs.mv.x.p t2, p11 (CPPRSRD: CoP=000, Cpreg=11, S=I=R=0,
    # Func3=000, Rd=x7/t2). After reset Next=P_STOP_OKAY (-4), sign-extended to
    # 0xFFFFFFFFFFFFFFFC; none of the ops above change Next. This is a program-driven
    # self-check: the dependent instructions below consume t2 (exercising the integer
    # RF writeback + RAW forwarding, V3), and only a correct readback yields PASS.
    .word 0x0B0003FB        # prs.mv.x.p t2, p11  (t2 <- Next)
    li   t3, -4             # expected P_STOP_OKAY, sign-extended
    li   t0, 1             # assume PASS (tohost=1 => exit 0)
    beq  t2, t3, 2f
    li   t0, 3             # I3 readback mismatch => tohost=3 => exit code 1 => FAIL
2:
    # --- CAM program + readback (I4b, gap G3 CAM path) : program CAM[0], read it back ---
    # Custom-3 words (opcode 0x7b): rs1/rd are real integer registers so the CVA6 decoder
    # feeds regs[rs1] to the FU. CPPRSWR stages {key,target} in Accum (p15); CPPRSWRCAM
    # writes it at index=rs1; CPPRSRDCAM does a key lookup back into rd. Program self-check.
    li   a0, 0x00010800000000CD   # {key32=(share1<<16)|0x0800, target=0xCD}
    .word 0x0F05107B        # CPPRSWR  p15, a0    (Accum <- {key,target})
    li   a1, 0              # CAM index 0
    .word 0x0F15907B        # CPPRSWRCAM a1, p15  (CAM[0] = {v,share1,0x0800,0xCD})
    li   a3, 0x00010800     # lookup key {share=1, match=0x0800}
    .word 0x0016867B        # CPPRSRDCAM a2, a3   (a2 <- CAM lookup target)
    li   a4, 0xCD           # expected programmed target
    beq  a2, a4, 3f
    li   t0, 5              # I4b CAM readback mismatch => tohost=5 => FAIL
3:
    # --- CAM-hit redirect (I4b): program a node-target entry, then a CAMNEXT.s HITS it ---
    # CAM[1] target is node index 10; at the CAMNEXT the internal node counter is 8
    # (custom-3 ops above don't advance it), so the FU redirects fetch to node 8+2
    # (byte +8), skipping the poison store — confirmed in-core: redirect_pc=0x80000076.
    # (If the preceding parser-op sequence changes, re-confirm the counter with a
    # temporary backdoor print of u_parser_fu.st_q.next_pc at the redirect.)
    li   a0, 0x000200060000000A   # {key32=(share2<<16)|0x0006, target=node 10}
    .word 0x0F05107B        # CPPRSWR  p15, a0    (Accum <- {key, node10})
    li   a1, 1              # CAM index 1
    .word 0x0F15907B        # CPPRSWRCAM a1, p15  (CAM[1] = {v,share2,0x0006,10})
    li   a0, 0x0006         # match value; Accum[15:0] is the CAMNEXT key source
    .word 0x0F05107B        # CPPRSWR  p15, a0    (Accum <- 0x0006)
    # contiguous custom-0 block (nodes 8,9,10 by byte layout):
    .word 0xE302040B        # prs.camnext.s share=2 sz=half pos=3  (CAM-hit redirect)
    .word 0x1EE0430B        # POISON: prs.storeimm 0xEE -> meta[8] (node 9, skipped)
    .word 0x1DD04B0B        # landing: prs.storeimm 0xDD -> meta[9] (node 10)

    # --- V4 (Table C, gap G6): WAW on the parser register file — last writer wins ---
    # Two custom-3 writes to the SAME p-register (p16 Flags) in program order; the
    # younger must win. Custom-3 layout (opcode 0x7b): CoP[31:29]=0, Cpreg[28:24],
    # R[20], Rs[19:15], Func3[14:12], Rd[11:7]. So:
    #   0x1005107B = CPPRSWR p16, a0   (cpreg=16, R=0, Func3=1, Rs=a0/x10)
    #   0x100007FB = CPPRSRD a5, p16   (cpreg=16, R=0, Func3=0, Rd=a5/x15)
    # The readback reads the working state that reflects every older accepted write, so a
    # stale (older) value fails the self-check. (The wrap-TB Scenario 9 additionally
    # proves the *architectural/committed* WAW ordering.)
    li   a0, 0x11
    .word 0x1005107B        # CPPRSWR p16, a0   (Flags <- 0x11)
    li   a0, 0x22
    .word 0x1005107B        # CPPRSWR p16, a0   (Flags <- 0x22, write-after-write)
    .word 0x100007FB        # CPPRSRD a5, p16   (a5 <- Flags)
    li   a6, 0x22
    beq  a5, a6, 4f
    li   t0, 9             # V4 WAW mismatch => tohost=9 => FAIL
4:
    # --- V5 (Table C, gap G6): parser op adjacent to mul/CSR/branch — no WB/commit contention ---
    # The custom-3 readback retires on the parser writeback port; back-to-back with a MUL
    # (mult-unit WB), a CSR read (CSR WB), and taken branches it checks that the added
    # parser WB port neither drops nor corrupts a neighbour's retire (and vice-versa). We
    # first write a known sentinel to p16, then value-check BOTH the parser readback of it
    # AND the mul result.
    li   a0, 0x5A
    .word 0x1005107B        # CPPRSWR p16, a0   (Flags <- 0x5A)
    li   s1, 7
    li   s2, 6
    mul  s0, s1, s2         # s0 = 42, mult-unit writeback
    .word 0x100007FB        # CPPRSRD a5, p16   (a5 <- Flags), adjacent to the mul
    csrr s3, mhartid        # CSR read adjacent (M-mode safe; exercises CSR WB adjacency)
    li   a6, 0x5A
    bne  a5, a6, 5f
    li   a7, 42
    bne  s0, a7, 5f
    j    6f
5:  li   t0, 11            # V5 adjacency mismatch => tohost=11 => FAIL
6:
    # --- N2 (Table B custom-3, §3.1 item 6): CPPRSWRIMM immediate-load ---
    # The immediate-load form writes a p-register from an 11-bit split immediate
    # (Imm2[20:15], Imm1[11:7]) — it has NO integer source or destination. Because the
    # immediate reuses the Rs/Rd fields, the decode patch forces integer rs1/rd to x0
    # for I=1, so a buggy decoder that kept Rd=Imm1[4:0] would clobber x[Imm1]. Here
    # imm=0x1DC => Imm1=0x1C=t3: preset t3 to a sentinel and prove it is UNCHANGED, and
    # read p16 (Flags) back == 0x1DC (proving the immediate reached the p-register and
    # overwrote the 0x5A left by V5). Commit-gated like CPPRSWR.
    #   0x10271E7B = CPPRSWRIMM p16, 0x1DC  (cpreg=16, S=0, I=1, Func3=1)
    #   0x100007FB = CPPRSRD    a5, p16
    li   t3, 0xBEEF         # sentinel in x[Imm1]; a correct decode must NOT touch it
    .word 0x10271E7B        # CPPRSWRIMM p16, 0x1DC  (Flags <- 0x1DC; no integer rd)
    .word 0x100007FB        # CPPRSRD a5, p16   (a5 <- Flags)
    li   a6, 0xBEEF
    bne  t3, a6, 8f         # t3 clobbered => decode wrote x[Imm1] => FAIL
    li   a6, 0x1DC
    beq  a5, a6, 7f
8:  li   t0, 13            # N2 CPPRSWRIMM mismatch/clobber => tohost=13 => FAIL
7:
    # --- signal result: tohost = t0 ---
    la   t1, tohost
    sd   t0, 0(t1)
1:  j    1b

# fesvr discovers these by symbol name and polls tohost for the exit code.
#include "htif.S"
