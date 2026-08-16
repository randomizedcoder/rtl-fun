# toolchain/ — assembler / intrinsics / sim patches (Phase 7)

Software support for the extension, in order of increasing effort:

1. `.insn` macros / inline-asm intrinsics (usable immediately for tests)
2. binutils (gas) mnemonics
3. LLVM MC + builtins, disassembler
4. Spike and QEMU model updates (functional ISA reference)

Assembler mappings are generated from [`isa/`](../isa/README.md).

## `parser_insn.h` (Phase 3)

Step 1 landed early: `parser_insn.h` builds raw parser instruction words from the
exact patent fields (via [`libparsermodel/encoding.h`](../model/libparsermodel/encoding.h)),
so tests and program images can emit encodings before gas/LLVM support exists.
It provides readable builders (`prs_load_h`, `prs_store`, `prs_camnext`, the
custom-3 `prs_mv_*`, …) and a `PRS_EMIT(word)` `.insn` macro for planting a
constant word into the instruction stream once a core executes it (Phase 5+).

Steps 2–4 (gas/LLVM/Spike/QEMU) remain Phase 7.

See [`docs/phase-7-toolchain.md`](../docs/phase-7-toolchain.md) and
[`docs/phase-3-encoding.md`](../docs/phase-3-encoding.md).
