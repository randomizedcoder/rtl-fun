/*
 * parser_mmio.c — QEMU parser packet MMIO device (0x5000_0000), Phase 7 QEMU leg.
 *
 * A 4 KiB byte mailbox over g_parser_shared, a 1:1 port of the Spike device
 * (nix/spike-tandem/parser_mmio.h) to QEMU's MemoryRegionOps:
 *   store  off  < 0x100 -> packet buffer (byte-granular)
 *   store  off == 0x100 -> PktLen.ParseLen (low 16 bits)
 *   store  off == 0x108 -> exit landing PC (64-bit)
 *   load   off == 0x100 -> STATUS {[32]=exit_seen, [31:0]=code}
 *   load   off in [0x200, 0x200+sizeof meta) -> flow_keys frame
 *   everything else in-window: store accepted+ignored, load reads 0
 *
 * The CPU's own sd/ld drive this; the custom-0 helper (parser_helper.c) runs the
 * model against the same g_parser_shared and publishes code/exit_seen/meta.
 */
#include "qemu/osdep.h"
#include "system/memory.h"
#include "system/reset.h"
#include "parser_shared.h"
#include "parser_mmio.h"

/* The single definition of the shared mailbox (declared extern everywhere else). */
struct parser_shared g_parser_shared;

static uint64_t parser_mmio_read(void *opaque, hwaddr addr, unsigned size)
{
    if (addr == 0x100) {                       /* STATUS (read side of ParseLen) */
        return ((uint64_t)(g_parser_shared.exit_seen ? 1u : 0u) << 32)
             |  (uint64_t)(uint32_t)g_parser_shared.code;
    }
    if (addr >= 0x200 && addr + size <= 0x200 + sizeof(g_parser_shared.meta)) {
        uint64_t v = 0;
        for (unsigned i = 0; i < size && i < 8; i++) {
            v |= (uint64_t)g_parser_shared.meta[(addr - 0x200) + i] << (8 * i);
        }
        return v;
    }
    return 0;                                  /* packet region / holes read as 0 */
}

static void parser_mmio_write(void *opaque, hwaddr addr, uint64_t val,
                              unsigned size)
{
    if (addr + size <= sizeof(g_parser_shared.pkt)) {   /* packet window (< 0x100) */
        for (unsigned i = 0; i < size; i++) {
            g_parser_shared.pkt[addr + i] = (uint8_t)(val >> (8 * i));
        }
        return;
    }
    if (addr == 0x100) {
        g_parser_shared.parse_len = (uint32_t)(val & 0xFFFF);
    } else if (addr == 0x108) {
        g_parser_shared.exit_pc = val;
    }
    /* other in-window offsets: accepted and ignored */
}

static const MemoryRegionOps parser_mmio_ops = {
    .read = parser_mmio_read,
    .write = parser_mmio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 8 },
    .impl  = { .min_access_size = 1, .max_access_size = 8 },
};

void parser_mmio_map(MemoryRegion *sysmem, hwaddr base)
{
    MemoryRegion *mr = g_new0(MemoryRegion, 1);

    memory_region_init_io(mr, NULL, &parser_mmio_ops, NULL,
                          "riscv.parser-mmio", 0x1000);
    memory_region_add_subregion(sysmem, base, mr);
    qemu_register_reset(parser_reset, NULL);
}
