# base_isa.S — base-ISA regression (N6, gap G11): prove the parser patch is
# behaviorally transparent to standard RV64GC. The parser integration changes the
# issue/execute/writeback plumbing (a new fu_t::PARSER, an extra writeback port,
# NrWbPorts bookkeeping — nix/cva6-parser/issue-ex.patch); the risk is that adding
# that path breaks normal instruction retirement. This program retires a broad
# representative slice of RV64GC — integer (RV64I incl. *w ops), M (mul/div/rem),
# A (lr/sc, amo), F/D float, CSR, and every branch flavour — value-checking each
# result on the PATCHED core. Every FU writes back through the same modified
# commit/writeback ports the patch touches, so a correct run is direct evidence the
# base ISA still works under the extension.
#
# Self-checking, no parser ops: on the first mismatch it writes tohost=(id<<1)|1 (so
# fesvr exit code == the failing test id); an unexpected trap writes exit code 0xEE;
# all-pass writes tohost=1 => fesvr SUCCESS. Companion to the negative control (N1):
# N1 proves the stock core REJECTS the parser ops; this proves the patched core still
# ACCEPTS the whole base ISA. (This is a directed representative regression; the full
# upstream riscv-tests suite is the heavier deferred complement — see §3.1 item 7.)
#
# Run: Variane_testharness base_isa.elf   (tohost=1 => exit 0 => PASS)

.section .text.init
.globl _start
_start:
    # Trap vector: any unexpected fault (illegal/misaligned/…) lands here and writes a
    # distinctive exit code 0xEE, so a base-ISA break shows as a clean FAIL not a hang.
    la    t0, trap_isr
    csrw  mtvec, t0
    # Enable the FPU (mstatus.FS = Dirty) so the F/D checks don't trap as illegal.
    li    t0, (3 << 13)
    csrs  mstatus, t0

    # ---------------------------------------------------------------------------
    # RV64I — arithmetic / logic / shift (register form)
    # ---------------------------------------------------------------------------
    li    gp, 1
    li    t0, 5
    li    t1, 7
    add   t2, t0, t1                 # 12
    li    t3, 12
    bne   t2, t3, fail
    sub   t2, t1, t0                 # 2
    li    t3, 2
    bne   t2, t3, fail

    li    gp, 2
    li    t0, 0xF0
    li    t1, 0x0F
    or    t2, t0, t1                 # 0xFF
    li    t3, 0xFF
    bne   t2, t3, fail
    and   t2, t0, t1                 # 0
    bne   t2, x0, fail
    xor   t2, t0, t0                 # 0
    bne   t2, x0, fail

    li    gp, 3
    li    t0, 1
    slli  t2, t0, 20                 # 0x100000
    li    t3, 0x100000
    bne   t2, t3, fail
    li    t0, -8                     # 0xFFFF...F8
    srli  t2, t0, 60                 # logical: 0xF
    li    t3, 0xF
    bne   t2, t3, fail
    srai  t2, t0, 1                  # arithmetic: -4
    li    t3, -4
    bne   t2, t3, fail

    li    gp, 4                      # SLT / SLTU sign handling
    li    t0, -1
    li    t1, 1
    slt   t2, t0, t1                 # signed: -1 < 1 => 1
    li    t3, 1
    bne   t2, t3, fail
    sltu  t2, t0, t1                 # unsigned: 0xFFFF..F < 1 => 0
    bne   t2, x0, fail

    # ---------------------------------------------------------------------------
    # RV64I — *W (32-bit) ops sign-extend into XLEN
    # ---------------------------------------------------------------------------
    li    gp, 5
    li    t0, 0x7FFFFFFF
    li    t1, 1
    addw  t2, t0, t1                 # overflow into bit31 => sign-extended negative
    li    t3, 0xFFFFFFFF80000000
    bne   t2, t3, fail
    li    t0, 1
    sllw  t2, t0, 31                 # 0x8000_0000 sign-extended
    li    t3, 0xFFFFFFFF80000000
    bne   t2, t3, fail
    sraw  t2, t3, 31                 # -1
    li    t3, -1
    bne   t2, t3, fail

    # ---------------------------------------------------------------------------
    # RV64I — LUI / AUIPC / immediates
    # ---------------------------------------------------------------------------
    li    gp, 6
    lui   t0, 0x12345                # 0x12345000
    li    t1, 0x12345000
    bne   t0, t1, fail
    addi  t0, t0, 0x678             # 0x12345678
    li    t1, 0x12345678
    bne   t0, t1, fail

    # ---------------------------------------------------------------------------
    # RV64I — loads / stores (dword / word / half / byte, signed + unsigned)
    # ---------------------------------------------------------------------------
    li    gp, 7
    la    t0, scratch
    li    t1, 0xDEADBEEFCAFEBABE
    sd    t1, 0(t0)
    ld    t2, 0(t0)
    bne   t1, t2, fail
    lw    t2, 0(t0)                  # low word, sign-extended: 0xFFFF..CAFEBABE
    li    t3, 0xFFFFFFFFCAFEBABE
    bne   t2, t3, fail
    lwu   t2, 0(t0)                  # zero-extended: 0xCAFEBABE
    li    t3, 0x00000000CAFEBABE
    bne   t2, t3, fail

    li    gp, 8
    la    t0, scratch
    li    t1, 0x8000                 # a value with bit15 set
    sh    t1, 0(t0)
    lh    t2, 0(t0)                  # sign-extended: negative
    li    t3, 0xFFFFFFFFFFFF8000
    bne   t2, t3, fail
    lhu   t2, 0(t0)                  # zero-extended: 0x8000
    li    t3, 0x8000
    bne   t2, t3, fail
    li    t1, 0x80
    sb    t1, 0(t0)
    lb    t2, 0(t0)                  # sign-extended: -128
    li    t3, -128
    bne   t2, t3, fail
    lbu   t2, 0(t0)                  # zero-extended: 0x80
    li    t3, 0x80
    bne   t2, t3, fail

    # ---------------------------------------------------------------------------
    # Branches — each flavour, taken and not-taken
    # ---------------------------------------------------------------------------
    li    gp, 9
    li    t0, 5
    li    t1, 5
    bne   t0, t1, fail               # not taken (equal)
    beq   t0, t1, 1f                 # taken
    j     fail
1:  li    t1, 6
    blt   t0, t1, 2f                 # 5 < 6 taken
    j     fail
2:  bge   t0, t1, fail               # 5 >= 6 not taken
    li    t0, -1
    li    t1, 1
    bltu  t1, t0, 3f                 # 1 < 0xFFFF..F unsigned taken
    j     fail
3:  bgeu  t1, t0, fail               # not taken

    # ---------------------------------------------------------------------------
    # M extension — mul / mulh / div / rem (signed + unsigned + *w)
    # ---------------------------------------------------------------------------
    li    gp, 10
    li    t0, 6
    li    t1, 7
    mul   t2, t0, t1                 # 42
    li    t3, 42
    bne   t2, t3, fail
    li    t0, -3
    li    t1, 5
    mul   t2, t0, t1                 # -15
    li    t3, -15
    bne   t2, t3, fail

    li    gp, 11
    li    t0, 0x100000000           # 2^32
    li    t1, 0x100000000           # 2^32
    mulhu t2, t0, t1                 # (2^64) >> 64 = 1
    li    t3, 1
    bne   t2, t3, fail

    li    gp, 12
    li    t0, 100
    li    t1, 7
    div   t2, t0, t1                 # 14
    li    t3, 14
    bne   t2, t3, fail
    rem   t2, t0, t1                 # 2
    li    t3, 2
    bne   t2, t3, fail
    li    t0, -100
    li    t1, 7
    div   t2, t0, t1                 # -14 (trunc toward zero)
    li    t3, -14
    bne   t2, t3, fail
    rem   t2, t0, t1                 # -2
    li    t3, -2
    bne   t2, t3, fail

    li    gp, 13                     # divw / mulw (32-bit, sign-extended)
    li    t0, 1000000
    li    t1, 3
    mulw  t2, t0, t1                 # 3000000
    li    t3, 3000000
    bne   t2, t3, fail
    divw  t2, t0, t1                 # 333333
    li    t3, 333333
    bne   t2, t3, fail

    # ---------------------------------------------------------------------------
    # A extension — amoadd.d, lr.d/sc.d
    # ---------------------------------------------------------------------------
    li    gp, 14
    la    t0, atomic_var
    li    t1, 100
    sd    t1, 0(t0)
    li    t2, 5
    amoadd.d t3, t2, (t0)            # returns old (100); mem becomes 105
    li    t4, 100
    bne   t3, t4, fail
    ld    t5, 0(t0)
    li    t4, 105
    bne   t5, t4, fail

    li    gp, 15
    la    t0, atomic_var
    lr.d  t1, (t0)                   # 105
    addi  t1, t1, 1                  # 106
    sc.d  t2, t1, (t0)               # success => t2 == 0
    bne   t2, x0, fail
    ld    t3, 0(t0)
    li    t4, 106
    bne   t3, t4, fail

    # ---------------------------------------------------------------------------
    # F / D extension — round-tripped through fcvt so results are integer-comparable
    # ---------------------------------------------------------------------------
    li    gp, 16
    li    t0, 3
    fcvt.d.w ft0, t0                 # 3.0
    li    t1, 4
    fcvt.d.w ft1, t1                 # 4.0
    fadd.d ft2, ft0, ft1             # 7.0
    fcvt.w.d t2, ft2                 # 7
    li    t3, 7
    bne   t2, t3, fail
    fmul.d ft2, ft0, ft1             # 12.0
    fcvt.w.d t2, ft2                 # 12
    li    t3, 12
    bne   t2, t3, fail

    li    gp, 17
    li    t0, 12
    fcvt.d.w ft0, t0                 # 12.0
    li    t1, 4
    fcvt.d.w ft1, t1                 # 4.0
    fdiv.d ft2, ft0, ft1             # 3.0
    fcvt.w.d t2, ft2                 # 3
    li    t3, 3
    bne   t2, t3, fail
    li    t0, 16
    fcvt.d.w ft0, t0                 # 16.0
    fsqrt.d ft2, ft0                 # 4.0
    fcvt.w.d t2, ft2                 # 4
    li    t3, 4
    bne   t2, t3, fail

    li    gp, 18                     # float compares set an integer reg
    li    t0, 5
    fcvt.d.w ft0, t0
    li    t1, 5
    fcvt.d.w ft1, t1
    feq.d t2, ft0, ft1               # equal => 1
    li    t3, 1
    bne   t2, t3, fail
    li    t1, 6
    fcvt.d.w ft1, t1
    flt.d t2, ft0, ft1               # 5 < 6 => 1
    bne   t2, t3, fail
    feq.d t2, ft0, ft1               # 5 == 6 => 0
    bne   t2, x0, fail

    li    gp, 19                     # single-precision fadd.s + fsw/flw round-trip
    li    t0, 10
    fcvt.s.w ft0, t0                 # 10.0f
    li    t1, 20
    fcvt.s.w ft1, t1                 # 20.0f
    fadd.s ft2, ft0, ft1             # 30.0f
    la    t0, scratch
    fsw   ft2, 0(t0)
    flw   ft3, 0(t0)
    fcvt.w.s t2, ft3                 # 30
    li    t3, 30
    bne   t2, t3, fail

    # ---------------------------------------------------------------------------
    # Zicsr — csrrw / csrrs / csrrc on mscratch (a safe scratch CSR)
    # ---------------------------------------------------------------------------
    li    gp, 20
    li    t0, 0xA5A5
    csrw  mscratch, t0
    csrr  t1, mscratch
    bne   t0, t1, fail
    li    t0, 0x0F0F
    csrrs t2, mscratch, t0           # old (0xA5A5) returned; set bits
    li    t3, 0xA5A5
    bne   t2, t3, fail
    csrr  t1, mscratch               # 0xA5A5 | 0x0F0F = 0xAFAF
    li    t3, 0xAFAF
    bne   t1, t3, fail
    li    t0, 0x0F0F
    csrrc t2, mscratch, t0           # clear those bits => 0xA0A0
    csrr  t1, mscratch
    li    t3, 0xA0A0
    bne   t1, t3, fail

    # ---------------------------------------------------------------------------
    # JAL / JALR — call/return linkage
    # ---------------------------------------------------------------------------
    li    gp, 21
    li    a0, 41
    jal   ra, add_one                # a0 += 1 => 42
    li    t3, 42
    bne   a0, t3, fail

    # ---- all checks passed ----
pass:
    li    t0, 1
    la    t1, tohost
    sd    t0, 0(t1)
1:  j     1b

fail:
    slli  t0, gp, 1                  # tohost = (failing id << 1) | 1 => exit code == id
    ori   t0, t0, 1
    la    t1, tohost
    sd    t0, 0(t1)
1:  j     1b

# A trivial leaf callee for the JAL/JALR linkage check.
add_one:
    addi  a0, a0, 1
    jalr  x0, 0(ra)

.align 2
trap_isr:
    li    t0, (0xEE << 1) | 1        # unexpected trap => distinctive exit code 0xEE
    la    t1, tohost
    sd    t0, 0(t1)
1:  j     1b

.section .data
.align 3
scratch:     .dword 0
atomic_var:  .dword 0

#include "htif.S"
