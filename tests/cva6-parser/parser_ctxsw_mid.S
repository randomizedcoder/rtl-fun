/*
 * parser_ctxsw_mid.S — M1 (Table C; §3.1 item 4, register half): a genuine MID-parse
 * context switch of the parser's architectural register state, in-core, over the REAL
 * pipeline and against the golden-model flow_keys oracle.
 *
 * V10 (parser_ctxsw_v10.S) proved a *between-parse* switch of the writable subset
 * {p11,p13,p14,p15,p16}. M1 finishes the register half: the custom-3 ABI now also reaches
 * the in-progress cursor/position state — p1{cur_len,cur_off}, p2{dat_len,dat_off}, p6
 * node_cnt, p7 encap, p8 next_pc (all writable) plus p9 done (READ-ONLY) — so a preempted
 * parse can be SAVED, its writable parser regs CLOBBERED by "another thread", RESTORED,
 * and RESUMED to the identical result.
 *
 * p9 (done) is deliberately read-only: it is a status flag, not restorable cursor state.
 * At any resumable mid-parse checkpoint the parser has not exited, so done==0; the ISR
 * READS p9 only, to prove the preemption really landed mid-parse (the marker). Writing
 * done=1 to a live parse stream would be a spurious mid-stream exit the CVA6 frontend does
 * not model (it wedges fetch), so done is never clobbered/restored here — a distinct
 * limitation, separate from the register-state resume this test delivers.
 *
 * How it works (built on the cosim MMIO driver + the V6 interrupt-resume mechanism):
 *   1. Preload the packet, ParseLen and exit-landing PC; program the CAM (as cosim_main.S).
 *   2. Enable the machine software interrupt and pend CLINT msip=1 immediately before
 *      `j parse_prog`, so the interrupt is taken a few cycles into the multi-node parse
 *      (the proven-stable V6 pattern) — landing on an in-flight parse op, done==0.
 *   3. A bespoke M-mode ISR (below; NOT trap.S's shared vector, so V6/V7 are untouched):
 *        - clears msip (fire once) and, if the parser reports done==0 at entry, sets
 *          saw_midparse=1 (proves a real mid-parse preemption, not a post-exit trap);
 *        - SAVEs the resumable register set {p1,p2,p6,p7,p8,p11,p13,p14,p15,p16} (and
 *          reads p9/done for the marker) via CPPRSRD into mid_save[];
 *        - CLOBBERs every WRITABLE one via CPPRSWR with a B-pattern (p9/done is read-only
 *          and NOT clobbered). This is register-file only: NO STORE and NO CAM program,
 *          because the meta_mem flow_keys frame and the CAM have no custom-3 restore path
 *          (the M2 residual, still deferred);
 *        - RESTOREs every writable register from mid_save[], and `mret`s WITHOUT advancing
 *          mepc: the squashed parse op re-executes from the restored (== original
 *          committed) state and the parse runs to completion.
 *   4. parse_done (the exit-landing PC): compare the committed flow_keys (PARSER_META) to
 *      the model's `expected` byte-for-byte and the latched ParserExitCode to
 *      `expected_code` (as cosim_main.S), then require trap_count>=1 and saw_midparse==1.
 *      tohost=1 on full match (fesvr exit 0 => PASS), else an odd/explicit fail code.
 *
 * Oracle strength: the model `expected` gates the final state (a broken save/restore of
 * the cursor regs corrupts the resumed parse and cannot match), the marker proves a real
 * done==0 preemption occurred, and the clobber proves the restore (not a no-op) is what
 * preserved correctness. The deterministic wrap-TB Scenario 14 separately proves the new
 * encodings + the done=1->0 clear without depending on interrupt timing.
 *
 * The script links this with the SAME generated prog.S (parse_prog + cam_table) and a
 * single multi-node case.S (packet/expected/expected_code) the cosim uses.
 *
 * Run: Variane_testharness parser_ctxsw_mid.elf   (tohost=1 => exit 0 => PASS)
 */
#include "parser_mmio.h"

# CLINT msip (machine software-interrupt pending), CLINT base + 0 (ariane_soc_pkg
# CLINTBase=0x0200_0000). Writing 1 pends a machine software interrupt; 0 clears it.
.equ CLINT_MSIP, 0x02000000

# custom-3 word encodings (transfer GPR a1=x11), same funnel as parser_ctxsw_v10.S:
#   CPPRSRD a1, p<c>  = (c<<24) | (a1<<7)  | 0x7B   = (c<<24) | 0x000005FB
#   CPPRSWR p<c>, a1  = (c<<24) | (a1<<15) | 0x107B = (c<<24) | 0x0005907B
# MSAVE : CPPRSRD a1,p<c> ; mid_save[slot] = a1   (s1 -> mid_save)
.macro MSAVE rd, slot
    .word \rd
    sd    a1, \slot(s1)
.endm
# MCLOB : a1 = B-pattern ; CPPRSWR p<c>,a1   (register-file only; used for WRITABLE regs)
.macro MCLOB wr
    li    a1, 0xA5A5A5A5A5A5A5A5
    .word \wr
.endm
# MREST : a1 = mid_save[slot] ; CPPRSWR p<c>,a1   (restore; done returns to saved 0)
.macro MREST wr, slot
    ld    a1, \slot(s1)
    .word \wr
.endm

.section .text.init
.globl _start
_start:
    # ---- point mtvec at the bespoke ISR (direct mode), anchor the save block ----
    la    t0, mid_vector
    csrw  mtvec, t0             # direct mode (4-byte aligned => MODE=0)
    la    t0, mid_ctx
    csrw  mscratch, t0          # mscratch -> the ISR save block
    sd    x0, 40(t0)            # trap_count = 0

    # ---- 1a. preload the packet: sd 8 bytes at a time into the packet buffer ----
    la    t0, packet
    la    t1, packet_len
    ld    t1, 0(t1)
    li    t2, PARSER_PKT
    addi  t3, t1, 7
    srli  t3, t3, 3
1:  beqz  t3, 2f
    ld    t4, 0(t0)
    sd    t4, 0(t2)
    addi  t0, t0, 8
    addi  t2, t2, 8
    addi  t3, t3, -1
    j     1b
2:
    # ---- 1b. ParseLen ----
    li    t0, PARSER_PARSELEN
    la    t1, packet_len
    ld    t1, 0(t1)
    sd    t1, 0(t0)

    # ---- 1c. exit landing PC ----
    li    t0, PARSER_EXIT_PC
    la    t1, parse_done
    sd    t1, 0(t0)

    # ---- 2. program the CAM: one CPPRSWR + CPPRSWRCAM per entry ----
    la    t0, cam_table
    la    t1, cam_count
    ld    t1, 0(t1)
    li    t2, 0
5:  beq   t2, t1, 6f
    ld    a0, 0(t0)
    .word 0x0F05107B           # CPPRSWR    p15, a0
    mv    a1, t2
    .word 0x0F15907B           # CPPRSWRCAM a1, p15
    addi  t0, t0, 8
    addi  t2, t2, 1
    j     5b
6:
    # ---- 2b. arm the machine software interrupt (mie.MSIE + mstatus.MIE), then pend
    #          msip=1 immediately before entering the parse block so it is taken a few
    #          cycles in (mid-parse), exactly as parser_trap_v6.S. ----
    li    t1, 8                 # bit 3 = MSIE / MIE
    csrs  mie, t1
    csrs  mstatus, t1
    li    t1, CLINT_MSIP
    li    t2, 1
    sw    t2, 0(t1)             # msip = 1 -> pend the machine software interrupt

    # ---- 3. run the parse graph; the FU steers node->node and, on exit, redirects to
    #         parse_done. The pended interrupt lands mid-walk -> mid_vector. ----
    j     parse_prog

parse_done:
    # drain the last commit-gated metadata writes before readback (safety margin)
    li    t3, 256
0:  addi  t3, t3, -1
    bnez  t3, 0b

    # ---- 4a. compare flow_keys (MMIO metadata frame) to the model's expected ----
    li    t0, PARSER_META
    la    t1, expected
    la    t2, expected_len
    ld    t2, 0(t2)
    addi  t3, t2, 7
    srli  t3, t3, 3
7:  beqz  t3, 8f
    ld    t5, 0(t0)
    ld    t6, 0(t1)
    bne   t5, t6, fail_keys
    addi  t0, t0, 8
    addi  t1, t1, 8
    addi  t3, t3, -1
    j     7b
8:
    # ---- 4b. compare the latched ParserExitCode + require an exit was seen ----
    li    t0, PARSER_PARSELEN
    ld    t0, 0(t0)
    slli  t1, t0, 32
    srai  t1, t1, 32
    la    t2, expected_code
    ld    t2, 0(t2)
    bne   t1, t2, fail_code
    srli  t0, t0, 32
    andi  t0, t0, 1
    beqz  t0, fail_noexit

    # ---- 4c. M1-specific: the interrupt fired, and it landed mid-parse (done==0) ----
    la    t0, mid_ctx
    ld    t1, 40(t0)           # trap_count
    beqz  t1, fail_notrap      # the mid-parse interrupt never fired
    la    t0, saw_midparse
    ld    t1, 0(t0)
    beqz  t1, fail_nomid       # the ISR never observed a done==0 (mid-parse) preemption

    li    t0, 1               # PASS -> tohost=1 -> fesvr exit 0
    j     done
fail_keys:   li t0, 3         # flow_keys mismatch (resume corrupted the parse)
    j     done
fail_code:   li t0, 5         # exit-code mismatch
    j     done
fail_noexit: li t0, 7         # parser never exited
    j     done
fail_notrap: li t0, 9         # the mid-parse interrupt never fired
    j     done
fail_nomid:  li t0, 11        # the preemption never landed mid-parse (done==0)
done:
    la    t1, tohost
    sd    t0, 0(t1)
9:  j     9b

# ---- bespoke M-mode ISR: save / clobber / restore the resumable position+data registers --
.section .text
.align 2                       # mtvec (direct) requires a 4-byte-aligned base
mid_vector:
    csrrw t0, mscratch, t0     # t0 <- &mid_ctx ; mscratch <- caller t0
    sd    a1, 8(t0)            # stash caller a1 (custom-3 transfer GPR)
    sd    a2, 16(t0)           # stash caller a2
    sd    t1, 24(t0)           # stash caller t1
    sd    s1, 32(t0)           # stash caller s1 (mid_save pointer)
    csrr  t1, mscratch
    sd    t1, 0(t0)            # stash caller t0

    ld    t1, 40(t0)           # trap_count++
    addi  t1, t1, 1
    sd    t1, 40(t0)

    li    t1, CLINT_MSIP       # clear msip so the interrupt fires exactly once
    sw    x0, 0(t1)

    # mid-parse marker: read p9 (done). done==0 => a genuine mid-parse preemption.
    .word 0x090005FB           # CPPRSRD a1, p9   (a1 = done)
    bnez  a1, .Lno_marker
    li    t1, 1
    la    a2, saw_midparse
    sd    t1, 0(a2)
.Lno_marker:

    la    s1, mid_save         # s1 -> the ISR save block for the parser regs

    # ---- SAVE the resumable register set (CPPRSRD; always serviceable). p9/done is read
    #      here too for completeness, but it is read-only and not restored below. ----
    MSAVE 0x010005FB, 0        # p1  {cur_len,cur_off}
    MSAVE 0x020005FB, 8        # p2  {dat_len,dat_off}
    MSAVE 0x060005FB, 16       # p6  node_cnt
    MSAVE 0x070005FB, 24       # p7  encap
    MSAVE 0x080005FB, 32       # p8  next_pc
    MSAVE 0x090005FB, 40       # p9  done
    MSAVE 0x0B0005FB, 48       # p11 Next
    MSAVE 0x0D0005FB, 56       # p13 {loop,databound}
    MSAVE 0x0E0005FB, 64       # p14 Code
    MSAVE 0x0F0005FB, 72       # p15 Accum
    MSAVE 0x100005FB, 80       # p16 Flags

    # ---- CLOBBER every WRITABLE reg (register-file only; NO store, NO CAM — the M2
    #      boundary). p9 (done) is read-only and NOT clobbered — it is a status flag, not
    #      restorable cursor state, and injecting done=1 on a live parse stream would be a
    #      spurious mid-stream exit the frontend does not model. ----
    MCLOB 0x0105907B           # p1
    MCLOB 0x0205907B           # p2
    MCLOB 0x0605907B           # p6
    MCLOB 0x0705907B           # p7
    MCLOB 0x0805907B           # p8
    MCLOB 0x0B05907B           # p11
    MCLOB 0x0D05907B           # p13
    MCLOB 0x0E05907B           # p14
    MCLOB 0x0F05907B           # p15
    MCLOB 0x1005907B           # p16

    # ---- RESTORE every writable reg from mid_save[] (p9/done is read-only, not restored) --
    MREST 0x0105907B, 0        # p1
    MREST 0x0205907B, 8        # p2
    MREST 0x0605907B, 16       # p6
    MREST 0x0705907B, 24       # p7
    MREST 0x0805907B, 32       # p8
    MREST 0x0B05907B, 48       # p11
    MREST 0x0D05907B, 56       # p13
    MREST 0x0E05907B, 64       # p14
    MREST 0x0F05907B, 72       # p15
    MREST 0x1005907B, 80       # p16

    csrw  mscratch, t0         # restore mscratch -> &mid_ctx for a (hypothetical) next trap
    ld    a1, 8(t0)
    ld    a2, 16(t0)
    ld    t1, 24(t0)
    ld    s1, 32(t0)
    ld    t0, 0(t0)            # restore caller t0 last (it held the save base)
    mret                        # WITHOUT advancing mepc: the squashed parse op re-executes

.section .data
.align 3
# mid_ctx: [0]=caller t0 [8]=a1 [16]=a2 [24]=t1 [32]=s1 [40]=trap_count
mid_ctx:
    .dword 0, 0, 0, 0, 0, 0
# saw_midparse: set to 1 by the ISR iff the parser reported done==0 at preemption.
.globl saw_midparse
saw_midparse:
    .dword 0
# mid_save[11]: the spilled parser register context (one dword per resumable p-reg).
# [0]p1 [8]p2 [16]p6 [24]p7 [32]p8 [40]p9 [48]p11 [56]p13 [64]p14 [72]p15 [80]p16
.align 3
mid_save:
    .dword 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0

#include "htif.S"
