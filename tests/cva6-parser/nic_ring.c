/*
 * nic_ring.c — in-core NIC ring driver over the whole packet corpus (D6).
 *
 * The C half of the `cva6-parser-nic-cosim` app. Where cva6-parser-cosim boots one
 * ELF per packet (each a fresh, one-shot parse), this boots ONCE and parses the
 * entire xdp2 corpus by re-arming the FU between packets — the multi-packet
 * capability D6 adds (parser_shared.rearm, set on every ParseLen store; consumed by
 * the extension's arm gate in Spike/QEMU). It models a NIC RX descriptor ring:
 *
 *   for each corpus frame:
 *     1. MAC RX DMA the frame into the FU packet window       (mac_rx_dma)
 *     2. arm the parse: write ParseLen (= re-arm the engine)
 *     3. run the parse graph                                  (nic_parse_run, asm)
 *     4. read the committed flow_keys back + the exit status, compare to the golden
 *
 * The corpus + its per-packet golden flow_keys/exit-code are baked in at build time
 * by `gen_parser_rom --corpus-blob` (corpus_blob.h). A full clean pass proves the
 * software/logic parses real packets == the golden model across a re-arming run,
 * with no board and no per-packet reboot. On the first mismatch it stops and reports
 * an odd fail code (matching cosim_main.S: 3 keys / 5 code / 7 no-exit); 1 = PASS.
 *
 * The low-level primitives (_start, CAM programming, the parse-block jump, HTIF)
 * live in nic_ring_asm.S; everything here is plain C over the 0x5000_0000 MMIO.
 */
#include "parser_mmio.h"
#include "corpus_blob.h"

#define WR(a, v) (*(volatile unsigned long *)(a) = (unsigned long)(v))
#define RD(a)    (*(volatile unsigned long *)(a))
#define RDB(a)   (*(volatile unsigned char *)(a))

/* provided by nic_ring_asm.S + the model-generated prog.S */
extern void nic_cam_program(void);
extern void nic_parse_run(void);

/* Model the MAC's RX DMA: burst the frame into the FU packet window in 8-byte beats,
 * capped at the 256-byte window — exactly what a hardware MAC pushes before raising
 * RX. corpus_pkt rows are zero-padded to CORPUS_PKT_MAX, so the final (possibly
 * partial) beat reads only in-bounds bytes. */
static void mac_rx_dma(const unsigned char *frame, unsigned len)
{
    unsigned cap   = (len < CORPUS_PKT_MAX) ? len : (unsigned)CORPUS_PKT_MAX;
    unsigned words = (cap + 7u) / 8u;
    for (unsigned i = 0; i < words; i++) {
        unsigned long w = 0;
        for (unsigned b = 0; b < 8; b++)
            w |= (unsigned long)frame[i * 8u + b] << (8u * b);
        WR(PARSER_PKT + (unsigned long)i * 8u, w);
    }
}

int nic_ring_run(void)
{
    nic_cam_program();          /* program the CAM once; it persists across re-arm */

    for (int i = 0; i < CORPUS_N; i++) {
        /* ---- RX: DMA the frame in, then arm the parse (ParseLen write = re-arm) ---- */
        mac_rx_dma(corpus_pkt[i], corpus_len[i]);
        WR(PARSER_PARSELEN, corpus_len[i]);

        /* ---- run the parse graph; the FU returns to us on parse exit ---- */
        nic_parse_run();

        /* drain margin: a no-op on the in-order functional sims, mirrors the RTL
         * cosim's post-exit metadata-commit settle so the driver is RTL-ready too. */
        for (volatile int d = 0; d < 64; d++) { }

        /* ---- 4a. committed flow_keys vs the golden, byte for byte ---- */
        for (unsigned b = 0; b < CORPUS_META_LEN; b++)
            if (RDB(PARSER_META + b) != corpus_meta[i][b])
                return 3;       /* flow_keys mismatch */

        /* ---- 4b. exit code (sign-extended [31:0]) + require an exit was seen ---- */
        unsigned long st = RD(PARSER_STATUS);
        long code = (long)(int)(unsigned int)(st & 0xFFFFFFFFUL);
        if (code != corpus_code[i]) return 5;    /* exit-code mismatch */
        if (((st >> 32) & 1UL) == 0) return 7;   /* parser never exited */
    }

    return 1;                    /* every corpus packet matched -> PASS */
}
