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
# Then (I3, gap G4) a custom-3 readback moves parser register p11 (Next) into an
# integer reg and the PROGRAM self-checks it against the expected reset value — a
# program-driven oracle needing no backdoor: a wrong readback writes a nonzero
# tohost (FAIL). This also exercises the parser integer-RF writeback + RAW forwarding.
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
    .word 0x1AB0230B        # prs.storeimm byte 0xAB -> metadata offset 4

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
    li   t0, 3             # readback mismatch => tohost=3 => exit code 1 => FAIL
2:
    # --- signal result: tohost = t0 ---
    la   t1, tohost
    sd   t0, 0(t1)
1:  j    1b

# fesvr discovers these by symbol name and polls tohost for the exit code.
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost:   .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
