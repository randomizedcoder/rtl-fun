// htif.S — the fesvr HTIF mailbox (tohost/fromhost), shared by the in-core tests.
//
// fesvr discovers these by symbol name and polls tohost for the exit code
// (tohost=1 => SUCCESS). #include'd by parser_insn.S and cosim_main.S so the
// block lives in exactly one place (assemble with -I tests/cva6-parser).
// QEMU's HTIF (hw/char/riscv_htif.c) requires the tohost/fromhost ELF symbols to
// have st_size == 8; fesvr/spike ignore the size. The .size directives set only
// symbol metadata (the emitted bytes are unchanged), so all sims are satisfied.
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost:   .dword 0
.size tohost, 8
.align 6
.globl fromhost
fromhost: .dword 0
.size fromhost, 8
