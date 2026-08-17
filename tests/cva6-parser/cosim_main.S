/*
 * cosim_main.S — in-core parser co-simulation driver (I5).
 *
 * The fixed logic half of the `cva6-parser-cosim` app. Per corpus case the script
 * links this with two generated files:
 *   prog.S   — parse_prog: (the slice program, one custom-0 .word per node, from
 *              enc.hex) + cam_table/cam_count (from cam.hex), shared by all cases
 *   case.S   — packet/packet_len, expected/expected_len, expected_code (per packet)
 *
 * It drives the parser over REAL MMIO (docs/analysis/cva6-parser-mmio.md):
 *   1. `sd` the packet bytes into the FU packet buffer, set ParseLen + exit-landing PC
 *   2. program the CAM (CPPRSWR + CPPRSWRCAM per entry; targets are node indices)
 *   3. jump into the contiguous custom-0 parse block — the FU walks the graph via
 *      end-of-node redirects and, on exit, returns to parse_done (the landing PC)
 *   4. `ld` the committed flow_keys back and compare to the model's expected bytes,
 *      and compare the latched ParserExitCode to the model's return code
 *   5. tohost = 1 on full match (fesvr exit 0 => PASS), else an odd fail code
 *
 * This is the first true packet->flow_keys equivalence check IN-CORE (gaps G5/G9).
 * Run: Variane_testharness cosim_NN.elf   (tohost=1 => exit 0 => PASS)
 */
#include "parser_mmio.h"

.section .text.init
.globl _start
_start:
    # ---- 1a. preload the packet: sd 8 bytes at a time into the packet buffer ----
    la    t0, packet             # src (padded to a multiple of 8 by the generator)
    la    t1, packet_len
    ld    t1, 0(t1)              # packet length in bytes
    li    t2, PARSER_PKT         # dst MMIO
    addi  t3, t1, 7
    srli  t3, t3, 3             # nwords = ceil(len/8)
1:  beqz  t3, 2f
    ld    t4, 0(t0)
    sd    t4, 0(t2)
    addi  t0, t0, 8
    addi  t2, t2, 8
    addi  t3, t3, -1
    j     1b
2:
    # ---- 1b. ParseLen (PktLen.ParseLen) ----
    li    t0, PARSER_PARSELEN
    la    t1, packet_len
    ld    t1, 0(t1)
    sd    t1, 0(t0)

    # ---- 1c. exit landing PC (where the FU returns control on parse exit) ----
    li    t0, PARSER_EXIT_PC
    la    t1, parse_done
    sd    t1, 0(t0)

    # ---- 2. program the CAM: one CPPRSWR + CPPRSWRCAM per entry ----
    # cam_table[i] = (share<<48)|(match<<32)|target  (== the Accum word CPPRSWR wants:
    # p15>>32 = {share<<16|match} = the 20-bit key source; p15[31:0] = node target).
    la    t0, cam_table
    la    t1, cam_count
    ld    t1, 0(t1)             # entry count
    li    t2, 0                # CAM index
5:  beq   t2, t1, 6f
    ld    a0, 0(t0)            # {key<<32 | target}
    .word 0x0F05107B          # CPPRSWR    p15, a0   (Accum <- a0)
    mv    a1, t2               # index
    .word 0x0F15907B          # CPPRSWRCAM a1, p15   (CAM[a1] <- {key,target})
    addi  t0, t0, 8
    addi  t2, t2, 1
    j     5b
6:
    # ---- 3. run the parse graph. The FU steers fetch node->node and, on parse
    #         exit, redirects here to parse_done (a_exit_redirects). ----
    j     parse_prog

parse_done:
    # give the last commit-gated metadata writes time to drain before readback (the
    # parser retires its ops in order after the exit redirect; this is a safety margin)
    li    t3, 256
0:  addi  t3, t3, -1
    bnez  t3, 0b

    # ---- 4a. compare flow_keys (MMIO metadata frame) to the model's expected ----
    li    t0, PARSER_META
    la    t1, expected
    la    t2, expected_len
    ld    t2, 0(t2)            # nbytes
    addi  t3, t2, 7
    srli  t3, t3, 3           # nwords = ceil(nbytes/8)
7:  beqz  t3, 8f
    ld    t5, 0(t0)          # committed flow_keys word
    ld    t6, 0(t1)          # expected word
    bne   t5, t6, fail_keys
    addi  t0, t0, 8
    addi  t1, t1, 8
    addi  t3, t3, -1
    j     7b
8:
    # ---- 4b. compare the latched ParserExitCode + require an exit was seen ----
    li    t0, PARSER_PARSELEN  # read side = status {[32]=exit seen, [31:0]=code}
    ld    t0, 0(t0)
    slli  t1, t0, 32
    srai  t1, t1, 32          # sign-extend the 32-bit code
    la    t2, expected_code
    ld    t2, 0(t2)
    bne   t1, t2, fail_code
    srli  t0, t0, 32
    andi  t0, t0, 1           # exit-seen bit
    beqz  t0, fail_noexit

    li    t0, 1               # PASS  -> tohost=1 -> fesvr exit 0
    j     done
fail_keys:   li t0, 3         # flow_keys mismatch
    j     done
fail_code:   li t0, 5         # exit-code mismatch
    j     done
fail_noexit: li t0, 7         # parser never exited
done:
    la    t1, tohost
    sd    t0, 0(t1)
9:  j     9b

#include "htif.S"
