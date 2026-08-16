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
# back-to-back to exercise the single-in-flight interlock + repeated retire, then
# signal PASS via the fesvr HTIF tohost symbol.
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

    # --- signal PASS: tohost = 1 ---
    li   t0, 1
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
