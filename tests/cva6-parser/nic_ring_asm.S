/*
 * nic_ring_asm.S — the low-level half of the in-core NIC ring driver (D6).
 *
 * The C driver (nic_ring.c) models a NIC RX descriptor ring: it DMAs each corpus
 * frame into the FU packet window, arms a parse (ParseLen write), reads the
 * committed flow_keys back and compares to the golden model — all plain C over the
 * 0x5000_0000 MMIO. This file holds the two parser primitives C can't express:
 *
 *   nic_cam_program()  program the CAM once via custom-3 (CPPRSWR + CPPRSWRCAM).
 *                      The CAM persists across parser re-arm (only pkt/ParseLen/done
 *                      reset per packet), so it is programmed a single time.
 *   nic_parse_run()    set the exit-landing PC to a return trampoline and jump into
 *                      the shared parse block (parse_prog, from the model-generated
 *                      prog.S). The FU walks the graph node->node and, on parse exit,
 *                      redirects fetch to nic_parse_ret, from where we `ret` to C
 *                      (ra is preserved across the FU redirect).
 *
 * plus _start (stack + call + HTIF verdict) and the tohost/fromhost mailbox.
 *
 * The single new capability D6 exercises vs cva6-parser-cosim: ONE booted process
 * parses the WHOLE corpus by re-arming the FU between packets (parser_shared.rearm,
 * set on each ParseLen store) — a multi-packet run, not one ELF per packet.
 */
#include "parser_mmio.h"

.section .text.init
.globl _start
_start:
    la    sp, _stack_top
    call  nic_ring_run          # int nic_ring_run(void) -> a0 = verdict (1 = PASS)
    la    t1, tohost
    sd    a0, 0(t1)             # tohost = verdict; fesvr exits (verdict>>1), 1 => exit 0
1:  j     1b

.section .text
.globl nic_cam_program
# void nic_cam_program(void): load cam_table[0..cam_count) into the FU CAM.
# cam_table[i] = (share<<48)|(match<<32)|target — the Accum word CPPRSWR expects
# (p15>>32 = 20-bit key, p15[31:0] = node target). cam_table/cam_count are provided
# by the model-generated prog.S (shared with cosim_main.S's step 2).
nic_cam_program:
    la    t0, cam_table
    la    t1, cam_count
    ld    t1, 0(t1)             # entry count
    li    t2, 0                # CAM index
1:  beq   t2, t1, 2f
    ld    a0, 0(t0)            # {key<<32 | target}
    .word 0x0F05107B          # CPPRSWR    p15, a0   (Accum <- a0)
    mv    a1, t2               # index
    .word 0x0F15907B          # CPPRSWRCAM a1, p15   (CAM[a1] <- {key,target})
    addi  t0, t0, 8
    addi  t2, t2, 1
    j     1b
2:  ret

.globl nic_parse_run
# void nic_parse_run(void): the packet + ParseLen are already armed by the C caller;
# jump into the parse block and return once the FU redirects to nic_parse_ret on exit.
nic_parse_run:
    li    t0, PARSER_EXIT_PC
    la    t1, nic_parse_ret
    sd    t1, 0(t0)            # exit-landing PC = our trampoline
    j     parse_prog           # FU steers node->node; on exit redirects to below
nic_parse_ret:
    ret                        # ra was preserved across the redirect

# ---- a small descending stack for the C driver (bss, not loaded) ----
.section .bss
.align 4
_stack:
    .skip 4096
_stack_top:

#include "htif.S"
