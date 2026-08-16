/* Minimal riscv-tests-style layout for the CVA6 testharness: code at the DRAM
 * base (0x80000000, where the bootrom hands off), a writable .tohost section for
 * the fesvr HTIF handshake. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  .text      : { *(.text) }
  . = ALIGN(0x1000);
  .data      : { *(.data) *(.sdata) }
  .tohost    : { *(.tohost) }
  .bss       : { *(.bss) *(.sbss) }
  _end = .;
}
