/*
 * parser_mmio.h — QEMU parser packet MMIO peripheral (0x5000_0000), Phase 7 QEMU
 * leg. Port of nix/spike-tandem/parser_mmio.h to a QEMU MemoryRegion.
 *
 * parser_mmio_map() creates the device MemoryRegion (memory_region_init_io over
 * the byte semantics of the Spike device) and adds it to `sysmem` at `base`, and
 * registers the engine reset hook. Called once from hw/riscv/spike.c's machine init.
 */
#ifndef PARSER_MMIO_H
#define PARSER_MMIO_H

#include "exec/hwaddr.h"
#include "system/memory.h"

void parser_mmio_map(MemoryRegion *sysmem, hwaddr base);

#endif  /* PARSER_MMIO_H */
