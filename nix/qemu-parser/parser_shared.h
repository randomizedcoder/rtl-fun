/*
 * parser_shared.h — state shared between the QEMU parser MMIO device
 * (parser_mmio.c) and the parser TCG helpers (parser_helper.c), Phase 7 QEMU leg.
 *
 * The port of nix/spike-tandem/parser_shared.h to QEMU. The CVA6 core has a
 * memory-mapped packet peripheral at 0x5000_0000 (packet buffer, ParseLen,
 * exit-PC, and the flow_keys/status readback — see toolchain/parser_mmio.h). To
 * run the parser ELFs, QEMU models the same peripheral:
 *   * the CPU's `sd` stores land the packet / ParseLen / exit-PC in the device;
 *   * the custom-0 helper runs libparsermodel with pkthdrbase -> pkt and
 *     meta -> meta, writing back code / exit_seen as it steps;
 *   * the CPU's `ld` of STATUS (0x100) / META (0x200) is served from here.
 *
 * A QEMU process runs one single-hart softmmu machine, so one global instance
 * suffices (mirrors Spike's g_parser_shared). The DEFINITION lives in
 * parser_mmio.c; every other TU sees this extern declaration.
 */
#ifndef PARSER_SHARED_H
#define PARSER_SHARED_H

#include <stdint.h>

/* Field order keeps `meta` at an 8-aligned offset (right after the 256-byte
 * packet): the helper binds the model's `struct flow_keys *meta` to it via a
 * cast, so it must satisfy flow_keys' 4-byte member alignment. */
struct parser_shared {
    uint8_t  pkt[256];    /* packet buffer      (device store, off < 0x100)      */
    uint8_t  meta[64];    /* flow_keys frame    (model writes -> device load 0x200+) */
    uint32_t parse_len;   /* PktLen.ParseLen    (device store, off == 0x100, low 16b) */
    uint64_t exit_pc;     /* exit landing PC    (device store, off == 0x108)     */
    int32_t  code;        /* model exit code    (helper -> device load 0x100 [31:0]) */
    uint8_t  exit_seen;   /* model `done`       (helper -> device load 0x100 [32]) */
};

extern struct parser_shared g_parser_shared;

/* Reset the parser engine + the shared mailbox (registered as a QEMU reset hook
 * by parser_mmio_map; defined in parser_helper.c). */
void parser_reset(void *opaque);

#endif  /* PARSER_SHARED_H */
