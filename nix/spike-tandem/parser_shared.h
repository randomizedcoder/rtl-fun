// parser_shared.h — state shared between the tandem Spike's parser MMIO device
// (libriscv, riscv/parser_mmio.h) and the parser customext extension (libcustomext,
// customext/parser_ext.cc), for Phase 7 Stage 1c.
//
// The CVA6 core has a memory-mapped packet peripheral at 0x5000_0000 (the packet
// buffer, ParseLen, exit-PC, and the flow_keys/status readback — see
// toolchain/parser_mmio.h). To lock-step the parser's packet-load ops, the tandem
// Spike must model the same peripheral. The mechanism:
//   * the CPU's own `sd` stores land the packet / ParseLen / exit-PC in the device;
//   * the extension runs libparsermodel with pkthdrbase -> pkt and meta -> meta,
//     writing back code / exit_seen as it steps;
//   * the CPU's `ld` of STATUS (0x100) / META (0x200) is served from here, so the
//     loaded rd matches the core's peripheral under lock-step.
// Because the packet arrives via the same store instructions on both sides, the two
// buffers stay coherent for free — no state is copied across (same independence as
// Stage 0/1b).
//
// One process runs one tandem sim, so a single global instance suffices. The
// DEFINITION lives in libriscv (parser_mmio.h, #included once by Simulation.cc);
// every other translation unit sees only this extern declaration.
#ifndef PARSER_SHARED_H
#define PARSER_SHARED_H

#include <cstdint>

extern "C" {

// Field order keeps `meta` at an 8-aligned offset (right after the 256-byte packet):
// the extension binds the model's `struct flow_keys *meta` to it via a cast, so it
// must satisfy flow_keys' 4-byte member alignment.
struct parser_shared {
  uint8_t  pkt[256];    // packet buffer      (device.store, off < 0x100)
  uint8_t  meta[64];    // flow_keys frame    (model writes -> device.load 0x200+)
  uint32_t parse_len;   // PktLen.ParseLen    (device.store, off == 0x100, low 16b)
  uint64_t exit_pc;     // exit landing PC    (device.store, off == 0x108)
  int32_t  code;        // model exit code    (extension -> device.load 0x100 [31:0])
  uint8_t  exit_seen;   // model `done`       (extension -> device.load 0x100 [32])
};

extern struct parser_shared g_parser_shared;

}  // extern "C"

#endif  // PARSER_SHARED_H
