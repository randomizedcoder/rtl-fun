# negctl.S — negative control (gap G11): a custom-0 PARSER word must be REJECTED
# (illegal-instruction trap) by the STOCK CVA6 core. This is the negative twin of
# cva6-parser-test: the *identical* word the patched core executes and retires must
# TRAP on the unpatched core, proving the parser ops are a genuine ISA *extension*
# rather than something the base RV64GC decoder already accepts.
#
# Contract (run via scripts/parser-negative-control.sh on the STOCK model):
#   stock core   : the custom-0 word raises Illegal Instruction (mcause=2); the trap
#                  handler writes tohost=1 => fesvr SUCCESS => negative control PASS.
#   patched core : the word executes (no trap); the fall-through writes tohost=3
#                  => fesvr FAILED             => (confirms the word is real on the patch).
# So a SUCCESS here means "the stock core correctly rejected the parser op".
#
# Run: Variane_testharness negctl.elf   (tohost=1 => exit 0 => stock rejected it)
.section .text.init
.globl _start
_start:
    la    t0, trap_handler
    csrw  mtvec, t0            # direct mode: the handler is 4-byte aligned (MODE=0)
    li    t0, 3               # preset the no-trap (FAIL) code
    .word 0x1000000b          # prs.load byte — a custom-0 PARSER op (opcode 0x0b)
    # reached only if NO trap occurred (the core actually executed the parser op):
    la    t1, tohost
    sd    t0, 0(t1)           # tohost = 3 => FAILED (this is the patched-core path)
1:  j     1b

.align 2
trap_handler:
    csrr  t2, mcause
    li    t3, 2               # Illegal Instruction
    li    t0, 5               # trapped, but NOT illegal-instruction => unexpected
    bne   t2, t3, 2f
    li    t0, 1               # correct: illegal-instruction trap => negative control PASS
2:  la    t1, tohost
    sd    t0, 0(t1)
3:  j     3b

# fesvr discovers tohost/fromhost by symbol name (shared HTIF mailbox).
#include "htif.S"
