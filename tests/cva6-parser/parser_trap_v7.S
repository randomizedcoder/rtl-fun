# parser_trap_v7.S — V7 (Table C, gap G7): a faulting instruction squashes an
# in-flight parser op; after the trap handler returns, the re-executed parser op
# commits the SAME result as a fault-free run. This demonstrates the I1
# speculation-safety path (flush -> rollback -> re-execute) end-to-end through a
# REAL machine-mode exception, in-core — the FU-level rollback is proven separately
# by parser_wrap_tb Sc.1/Sc.4/Sc.11.
#
# The "parser op under test" is CPPRSWR p16 <- a0, a custom-3 write of commit-gated
# parser register state. It rides the exact same pending-queue commit-gate + flush
# rollback as a custom-0 parse op's flow_keys/metadata write, and — unlike the
# metadata frame — its committed value is integer-observable via CPPRSRD, so the
# whole check is self-contained (no MMIO peripheral / sim backdoor needed).
#
# Sequence:
#   (1) a CLEAN write+readback establishes the fault-free result (s0).
#   (2) the IDENTICAL write preceded by an `ecall` — an older synchronous fault that
#       flushes the younger, in-flight CPPRSWR — then read back (s1). The handler
#       skips the ecall (mepc+=4) and mret's onto the CPPRSWR, which re-executes from
#       committed state.
#   (3) assert fault-run (s1) == clean-run (s0), the committed value is exact, and the
#       fault fired exactly once (trap_count==1). tohost=1 => PASS.
#
# Run: Variane_testharness parser_trap_v7.elf   (tohost=1 => exit 0 => PASS)

# trap.S first: it defines the TRAP_SETUP macro + trap_vector + trap_save.
#include "trap.S"

.section .text.init
.globl _start
_start:
    TRAP_SETUP t0                # mtvec=trap_vector, mscratch=&trap_save, trap_count=0
    li    t0, 1                  # assume PASS (tohost=1 => exit 0)

    # ---- (1) clean baseline: p16 (Flags) <- 0x5C, read into s0 (no fault) ----
    li    a0, 0x5C
    .word 0x1005107B             # CPPRSWR p16, a0   (Flags <- 0x5C)
    .word 0x1000047B             # CPPRSRD s0, p16   (s0 = clean result)

    # ---- (2) fault run: the SAME write, with an older ecall in front ----
    # The ecall is OLDER (earlier in program order) than the CPPRSWR, so its
    # commit-time exception flushes the younger, in-flight CPPRSWR: st_q rolls back to
    # st_arch and its buffered write is discarded (I1). The handler skips the ecall and
    # returns onto the CPPRSWR, which re-executes from committed state and commits 0x5C.
    li    a0, 0x5C
    ecall                        # older synchronous fault -> flush the younger CPPRSWR
    .word 0x1005107B             # CPPRSWR p16, a0   (squashed, then re-executed)
    .word 0x100004FB             # CPPRSRD s1, p16   (s1 = fault-run result)

    # ---- (3) assertions: fault-run == clean-run, exact value, fault fired once ----
    bne   s0, s1, 8f             # fault-run != clean-run => corruption => FAIL
    li    a6, 0x5C
    bne   s1, a6, 8f             # sanity: the committed value is exactly 0x5C
    la    t1, trap_save          # the fault must have fired exactly once
    ld    t2, 32(t1)
    li    t3, 1
    beq   t2, t3, 9f
8:  li    t0, 7                  # V7 mismatch / wrong trap count => tohost=7 => FAIL
9:
    la    t1, tohost
    sd    t0, 0(t1)
1:  j     1b

#include "htif.S"
