// parser_mmio.h — the tandem Spike's parser MMIO packet peripheral (0x5000_0000),
// Phase 7 Stage 1c. A smart abstract_device_t that teaches the reference Spike the
// same memory-mapped packet buffer the CVA6 core has (toolchain/parser_mmio.h,
// nix/cva6-parser/mmio.patch), so PLOAD/PLENCUR + the flow_keys/status readback
// lock-step against the core.
//
// It is a dumb byte mailbox over g_parser_shared (parser_shared.h): the CPU's `sd`
// stores land the packet / ParseLen / exit-PC here; the parser customext extension
// runs the model against them and writes back code / exit_seen / flow_keys; the
// CPU's `ld` of STATUS (0x100) / META (0x200) is served from that shared state so
// the loaded rd matches the core's peripheral. The extension performs NO memory
// writes of its own, so nothing pollutes the RVFI commit-log — only the CPU's own
// sd/ld are recorded and compared.
//
// #include this header EXACTLY ONCE (riscv/Simulation.cc): it *defines*
// g_parser_shared. Registered on the bus at 0x5000_0000 alongside DRAM.
#ifndef PARSER_MMIO_H
#define PARSER_MMIO_H

#include <cstdint>
#include <cstring>
#include "abstract_device.h"
#include "parser_shared.h"

// The one definition of the shared state (libriscv); zero-initialized at load.
extern "C" { struct parser_shared g_parser_shared; }

namespace {

// Field map mirrors toolchain/parser_mmio.h + rtl/cva6_parser_wrap.sv:225-432:
//   store  off < 0x100  -> packet buffer
//   store  off == 0x100 -> PktLen.ParseLen (low 16 bits)
//   store  off == 0x108 -> exit landing PC
//   load   off == 0x100 -> STATUS {31'b0, exit_seen, code[31:0]}
//   load   off >= 0x200 -> flow_keys metadata frame
class parser_mmio_dev : public abstract_device_t {
 public:
  parser_mmio_dev() { std::memset(&g_parser_shared, 0, sizeof(g_parser_shared)); }

  bool load(reg_t addr, size_t len, uint8_t* bytes) override {
    if (addr >= 0x1000) return false;
    if (addr == 0x100) {                       // STATUS (read side of ParseLen addr)
      uint64_t s = ((uint64_t)(g_parser_shared.exit_seen ? 1u : 0u) << 32)
                 |  (uint64_t)(uint32_t)g_parser_shared.code;
      for (size_t i = 0; i < len; i++)
        bytes[i] = (i < 8) ? (uint8_t)(s >> (8 * i)) : 0;
      return true;
    }
    if (addr >= 0x200 && addr + len <= 0x200 + sizeof(g_parser_shared.meta)) {
      std::memcpy(bytes, g_parser_shared.meta + (addr - 0x200), len);
      return true;
    }
    std::memset(bytes, 0, len);                // packet region / holes read as 0
    return true;
  }

  bool store(reg_t addr, size_t len, const uint8_t* bytes) override {
    if (addr >= 0x1000) return false;
    if (addr + len <= sizeof(g_parser_shared.pkt)) {   // packet window (< 0x100)
      std::memcpy(g_parser_shared.pkt + addr, bytes, len);
      return true;
    }
    uint64_t v = 0;
    for (size_t i = 0; i < len && i < 8; i++) v |= (uint64_t)bytes[i] << (8 * i);
    if (addr == 0x100)      g_parser_shared.parse_len = (uint32_t)(v & 0xFFFF);
    else if (addr == 0x108) g_parser_shared.exit_pc   = v;
    // other in-window offsets: accepted and ignored
    return true;
  }
};

}  // namespace

#endif  // PARSER_MMIO_H
