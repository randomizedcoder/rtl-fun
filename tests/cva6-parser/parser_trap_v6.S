# parser_trap_v6.S — V6 (Table C, gap G7): an asynchronous interrupt fires mid-parse
# and squashes an in-flight parser op; after the ISR returns (mret WITHOUT advancing
# mepc), the interrupted parser op re-issues and commits the SAME result as an
# interrupt-free run. This demonstrates the I1 speculation-safety path (flush ->
# rollback -> re-execute) end-to-end through a REAL machine-mode *interrupt*, in-core —
# the asynchronous companion to V7's synchronous ecall (parser_trap_v7.S). Together
# V6 (interrupt) + V7 (exception) close G7: both flavours of the identical single-cycle
# flush_i that reaches the parser FU.
#
# The "parser op under test" is CPPRSWR p16 <- a0, a custom-3 write of commit-gated
# parser register state (same op V7 uses). It rides the exact same pending-queue
# commit-gate + flush rollback as a custom-0 parse op's flow_keys/metadata write, and
# its committed value is integer-observable via CPPRSRD, so the whole check is
# self-contained (no MMIO peripheral / sim backdoor needed).
#
# Interrupt mechanism: the CLINT machine *software* interrupt (msip at CLINT base + 0),
# chosen over the timer for determinism — writing msip=1 with mstatus.MIE + mie.MSIE
# set pends the interrupt immediately (no reliance on mtime advancing). The write
# propagates through the SoC AXI to the CLINT over a few cycles, so the interrupt is
# taken a handful of cycles later — landing on the in-flight parser op stream that
# follows. The trap handler (trap.S) clears msip (so it fires exactly once) and mret's
# WITHOUT advancing mepc, resuming onto the interrupted instruction.
#
# Whichever instruction the async interrupt happens to squash — the CPPRSWR (rolled
# back, re-executed from committed state) or the CPPRSRD (re-reads the already-committed
# p16) — the final committed value is invariant, because a0 (0x5C) is preserved across
# the ISR and CPPRSWR is idempotent from committed state. The test asserts that
# invariant plus "the interrupt fired exactly once".
#
# Sequence:
#   (1) a CLEAN write+readback establishes the interrupt-free result (s0).
#   (2) enable machine software interrupts, pend msip=1, then the IDENTICAL write —
#       taken mid-flight by the interrupt — then read back (s1).
#   (3) assert interrupt-run (s1) == clean-run (s0), the committed value is exact, and
#       the interrupt fired exactly once (trap_count==1). tohost=1 => PASS.
#
# Run: Variane_testharness parser_trap_v6.elf   (tohost=1 => exit 0 => PASS)

# trap.S first: it defines the TRAP_SETUP macro + trap_vector + trap_save + CLINT_MSIP.
#include "trap.S"

.section .text.init
.globl _start
_start:
    TRAP_SETUP t0                # mtvec=trap_vector, mscratch=&trap_save, trap_count=0
    li    t0, 1                  # assume PASS (tohost=1 => exit 0)

    # ---- (1) clean baseline: p16 (Flags) <- 0x5C, read into s0 (no interrupt) ----
    li    a0, 0x5C
    .word 0x1005107B             # CPPRSWR p16, a0   (Flags <- 0x5C)
    .word 0x1000047B             # CPPRSRD s0, p16   (s0 = clean result)

    # ---- (2) interrupt run: the SAME write, taken mid-flight by an async interrupt --
    # Enable the machine software interrupt (mie.MSIE, bit 3) and global interrupts
    # (mstatus.MIE, bit 3), then pend msip=1. The interrupt propagates through the AXI
    # and is taken a few cycles later, flushing the in-flight parser op: st_q rolls back
    # to st_arch and its buffered write is discarded (I1). The handler clears msip and
    # returns onto the interrupted op, which re-executes from committed state -> 0x5C.
    li    t1, 8                  # bit 3 = MSIE / MIE
    csrs  mie, t1                # enable machine software interrupt
    csrs  mstatus, t1            # enable global (M-mode) interrupts

    li    a0, 0x5C
    li    t1, CLINT_MSIP         # CLINT msip register
    li    t2, 1
    sw    t2, 0(t1)              # msip = 1 -> pend the machine software interrupt
    .word 0x1005107B             # CPPRSWR p16, a0   (taken mid-flight, then re-executed)
    .word 0x100004FB             # CPPRSRD s1, p16   (s1 = interrupt-run result)

    # ---- (3) assertions: interrupt-run == clean-run, exact value, fired once ----
    bne   s0, s1, 8f             # interrupt-run != clean-run => corruption => FAIL
    li    a6, 0x5C
    bne   s1, a6, 8f             # sanity: the committed value is exactly 0x5C
    la    t1, trap_save          # the interrupt must have fired exactly once
    ld    t2, 32(t1)
    li    t3, 1
    beq   t2, t3, 9f
8:  li    t0, 6                  # V6 mismatch / wrong trap count => tohost=6 => FAIL
9:
    la    t1, tohost
    sd    t0, 0(t1)
1:  j     1b

#include "htif.S"
