# trap.S — reusable in-core machine-mode trap scaffold for the parser tests.
#
# Provides a minimal M-mode trap handler + a TRAP_SETUP macro, #include'd by the
# interrupt/exception tests: V7 faulting-instruction squash (N4) and, later, V6
# machine-timer interrupt mid-parse (N5). The handler is transparent to the
# interrupted code — it saves/restores the temporaries it uses (t0-t3) via a save
# block anchored in mscratch — counts every trap in trap_count (so a test can assert
# a fault actually fired), and dispatches on mcause:
#   - ECALL-from-M (mcause=11): skip the ecall (mepc += 4) and mret — a synchronous
#     fault whose handler resumes AFTER the faulting instruction.
#   - anything else: mret WITHOUT advancing mepc (re-execute the interrupted op) —
#     the seam N5 extends for the machine-timer interrupt (clear mtimecmp, resume).
#
# Contract: mscratch holds &trap_save for the whole test (set by TRAP_SETUP); the
# handler leaves all architectural state untouched (t0-t3 saved/restored; a0-a7,
# s0-s11 never touched). #include it ABOVE _start so the macro is defined first, and
# assemble with -I tests/cva6-parser.

# TRAP_SETUP <treg>: point mtvec at the handler (direct mode), anchor mscratch at the
# save block, and zero trap_count. Clobbers only <treg>.
.macro TRAP_SETUP treg
    la    \treg, trap_vector
    csrw  mtvec, \treg          # direct mode: 4-byte-aligned handler => MODE=0
    la    \treg, trap_save
    csrw  mscratch, \treg       # mscratch -> the handler's save block
    sd    x0, 32(\treg)         # trap_count = 0
.endm

.section .text
.align 2                        # mtvec (direct) requires a 4-byte-aligned base
.globl trap_vector
trap_vector:
    csrrw t0, mscratch, t0      # t0 <- &trap_save ; mscratch <- caller's t0
    sd    t1, 8(t0)
    sd    t2, 16(t0)
    sd    t3, 24(t0)
    csrr  t1, mscratch          # t1 <- caller's t0
    sd    t1, 0(t0)             # stash caller's t0

    ld    t2, 32(t0)            # trap_count++
    addi  t2, t2, 1
    sd    t2, 32(t0)

    csrr  t1, mcause
    li    t3, 11                # ECALL from M-mode (synchronous)
    bne   t1, t3, .Ltrap_ret    # N5: add the machine-timer interrupt leg here
    csrr  t2, mepc              # resume AFTER the faulting ecall
    addi  t2, t2, 4
    csrw  mepc, t2
.Ltrap_ret:
    csrw  mscratch, t0          # restore mscratch -> &trap_save for the next trap
    ld    t1, 8(t0)
    ld    t2, 16(t0)
    ld    t3, 24(t0)
    ld    t0, 0(t0)             # restore caller's t0 last (it held the save base)
    mret

.section .data
.align 3
.globl trap_save
# [0]=caller t0  [8]=t1  [16]=t2  [24]=t3  [32]=trap_count
trap_save:
    .dword 0, 0, 0, 0, 0
