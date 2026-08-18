# parser_ctxsw_v10.S — V10 (Table C, gap G7 / §3.1 item 4): a *between-parse* context
# switch of the parser's architectural register state, in-core, over the REAL pipeline.
#
# This ratifies design decision D7 (docs/phase-4-microarchitecture.md): an OS saves and
# restores a parser thread's live state by REUSING the existing custom-3 move ABI —
# CPPRSRD (`prs.mv.x.p`, spill p-reg -> integer) and CPPRSWR (`prs.mv.p.x`, reload
# integer -> p-reg) — with no new CSRs, no runthread, single encap. The test *is* the
# ABI it ratifies: it spills thread A's parser context to memory, simulates another
# thread (B) clobbering the parser, reloads A, and asserts A came back bit-for-bit.
#
# SCOPE / ABI boundary (honest): custom-3 moves only reach a SUBSET of pstate_t. The
# read set (read_preg, rtl/cva6_parser_wrap.sv) is p1{cur_len,cur_off}, p2{dat_len,
# dat_off}, p11 Next, p13{loop,databound}, p14 Code, p15 Accum, p16 Flags; the WRITE
# set (write_preg) is p11/p13/p14/p15/p16 only. The round-trippable context is therefore
# exactly the read∩write subset {p11,p13,p14,p15,p16}, and every field in it round-trips
# LOSSLESSLY: p13 packs the full 64-bit {loop,databound}; p15/p16 are full 64-bit; p11/p14
# are 32-bit fields whose stored low word reloads to the identical sign-extended read.
# The mid-parse POSITION state (cur_off, dat_off, encap, node_cnt, next_pc, done) is NOT
# ABI-reachable — so this is a between-parse / quiescent-boundary switch. A genuine
# MID-parse preemption needs new encodings and stays deferred (§3.1). p1/p2 are read-only
# telemetry (not writable), so they are not part of the restorable set and not asserted.
#
# Self-contained: like parser_trap_v6.S, the whole check rides CPPRSWR (commit-gated,
# I1) + CPPRSRD readback — integer-observable, no MMIO peripheral / sim backdoor / trap.
#
# custom-3 word encoding (verified against parser_trap_v6.S / parser_insn.S):
#   CPPRSRD a1, p<c>  = (c<<24) | (a1<<7)  | 0x7B      (Func3=0, rd=a1=x11)
#   CPPRSWR p<c>, a1  = (c<<24) | (a1<<15) | 0x107B    (Func3=1, rs=a1=x11)
# All transfers funnel through a1 so the encodings differ only in the cpreg byte.
#
# Sequence (a1=transfer GPR, s0=&saveA, a2=compare temp, t0=result code):
#   (1) SEED    : write A's distinct value into each writable p-reg (CPPRSWR), then read
#                 it back (CPPRSRD) and stash the canonical observable value in saveA[i].
#   (2) CLOBBER : overwrite every p-reg with a B-context pattern; read back and assert it
#                 now DIFFERS from saveA[i] — proves the parser regs were truly overwritten
#                 (guards a "writes ignored" false pass; re-tests all five are writable).
#   (3) RESTORE : reload every p-reg from saveA[i] (CPPRSWR), read back, and assert it
#                 equals saveA[i] bit-for-bit — the D7 save/restore round-trip.
#   All five restore-exact AND all five clobbered => tohost=1 (PASS). Any miss => FAIL.
#
# Run: Variane_testharness parser_ctxsw_v10.elf   (tohost=1 => exit 0 => PASS)

.equ V10_FAIL_CLOBBER, 11        # a clobber left a p-reg unchanged (write ignored)
.equ V10_FAIL_RESTORE, 10        # a restore did not return the saved value bit-exact

# CTX_SEED    <wr_word> <rd_word> <Aval> <slot>: write A, read back, stash saveA[slot].
.macro CTX_SEED wr, rd, val, slot
    li    a1, \val
    .word \wr                    # CPPRSWR p<c>, a1   (p<c> <- a1)
    .word \rd                    # CPPRSRD a1, p<c>   (a1 <- canonical observable value)
    sd    a1, \slot(s0)          # saveA[slot] = A's context for this p-reg
.endm

# CTX_CLOBBER <wr_word> <rd_word> <slot>: overwrite with B, assert it changed.
.macro CTX_CLOBBER wr, rd, slot
    li    a1, 0xA5A5A5A5A5A5A5A5 # thread B's garbage (!= any A value chosen below)
    .word \wr                    # CPPRSWR p<c>, a1
    .word \rd                    # CPPRSRD a1, p<c>
    ld    a2, \slot(s0)
    beq   a1, a2, .Lfail_clobber # unchanged => the write was ignored => FAIL
.endm

# CTX_RESTORE <wr_word> <rd_word> <slot>: reload from saveA, assert bit-exact.
.macro CTX_RESTORE wr, rd, slot
    ld    a1, \slot(s0)          # A's saved context
    .word \wr                    # CPPRSWR p<c>, a1   (restore)
    .word \rd                    # CPPRSRD a1, p<c>   (read back)
    ld    a2, \slot(s0)
    bne   a1, a2, .Lfail_restore # not bit-exact => restore lost state => FAIL
.endm

.section .text.init
.globl _start
_start:
    li    t0, 1                  # assume PASS (tohost=1 => exit 0)
    la    s0, saveA              # s0 -> the save block for the whole test

    # ---- (1) SEED thread A's parser context, spill each p-reg to saveA[] ----
    # A values are distinct; p11/p14 set bit31 so the sign-extended readback is exercised
    # (write takes v[31:0], read returns {{32{v[31]}}, v[31:0]}); p13/p15/p16 use full 64.
    CTX_SEED 0x0B05907B, 0x0B0005FB, 0x89ABCDEF,         0    # p11 Next   (32-bit, bit31=1)
    CTX_SEED 0x0D05907B, 0x0D0005FB, 0x1234567890ABCDEF, 8    # p13 {loop,databound} (64)
    CTX_SEED 0x0E05907B, 0x0E0005FB, 0xDEADBEEF,         16   # p14 Code   (32-bit, bit31=1)
    CTX_SEED 0x0F05907B, 0x0F0005FB, 0xCAFEF00DDEADBEEF, 24   # p15 Accum  (64)
    CTX_SEED 0x1005907B, 0x100005FB, 0x0123456789ABCDEF, 32   # p16 Flags  (64)

    # ---- (2) CLOBBER: simulate thread B using the parser; assert each reg changed ----
    CTX_CLOBBER 0x0B05907B, 0x0B0005FB, 0
    CTX_CLOBBER 0x0D05907B, 0x0D0005FB, 8
    CTX_CLOBBER 0x0E05907B, 0x0E0005FB, 16
    CTX_CLOBBER 0x0F05907B, 0x0F0005FB, 24
    CTX_CLOBBER 0x1005907B, 0x100005FB, 32

    # ---- (3) RESTORE thread A from saveA[]; assert each reg is bit-exact ----
    CTX_RESTORE 0x0B05907B, 0x0B0005FB, 0
    CTX_RESTORE 0x0D05907B, 0x0D0005FB, 8
    CTX_RESTORE 0x0E05907B, 0x0E0005FB, 16
    CTX_RESTORE 0x0F05907B, 0x0F0005FB, 24
    CTX_RESTORE 0x1005907B, 0x100005FB, 32

    j     .Lpass                 # every reg clobbered then restored bit-exact => PASS

.Lfail_clobber:
    li    t0, V10_FAIL_CLOBBER   # a clobber was ignored => tohost=11 => FAIL
    j     .Ldone
.Lfail_restore:
    li    t0, V10_FAIL_RESTORE   # a restore lost state => tohost=10 => FAIL
.Lpass:
.Ldone:
    la    t1, tohost
    sd    t0, 0(t1)
1:  j     1b

.section .data
.align 3
# saveA[5]: thread A's spilled parser context, one dword per writable p-reg.
# [0]=p11  [8]=p13  [16]=p14  [24]=p15  [32]=p16
saveA:
    .dword 0, 0, 0, 0, 0

#include "htif.S"
