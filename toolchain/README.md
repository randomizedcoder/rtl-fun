# toolchain/ — assembler / intrinsics / sim patches (Phase 7)

Software support for the extension, in order of increasing effort:

1. `.insn` macros / inline-asm intrinsics (usable immediately for tests)
2. binutils (gas) mnemonics
3. LLVM MC + builtins, disassembler
4. Spike and QEMU model updates (functional ISA reference)

Assembler mappings are generated from [`isa/`](../isa/README.md).

*Empty until Phase 7. See [`docs/phase-7-toolchain.md`](../docs/phase-7-toolchain.md).*
