# Phase 7 — Toolchain support

← [Phase 6](phase-6-verification.md) · [Docs index](README.md) · [Phase 8 »](phase-8-fpga.md)

## Objective

Make the parser instructions usable from real code, in increasing order of
investment: raw `.insn` → intrinsics → assembler → compiler → ISA simulators. Do
the cheap thing first; only add heavyweight tool support once the ISA has settled.

## Inputs / prerequisites

- Phase 3 encoding table (`isa/parser-opcodes.*`) — the single source of bits.
- Phase 2 golden model (semantics the simulators must match).

## Design detail

### 7.1 Staging — cheapest first

```
 .insn / inline-asm  ──►  intrinsics header  ──►  binutils (as/objdump)
        │                                                  │
        └── enough to write & run the parser  ─────────────┘
                                                           ▼
                              LLVM MC + intrinsics/builtins ──► Spike ──► QEMU
```

Rule of thumb from the blog: **don't touch GCC/LLVM until the instruction set is
settling.** The `.insn` + intrinsics path (already started in Phase 3 §3.4) is
enough to write real parsers and benchmark them.

### 7.2 Level 1 — `.insn` + intrinsics (do now)

`toolchain/parser_insn.h`: one inline-asm wrapper per instruction, emitting the
exact encoding from the Phase-3 table:

```c
static inline uint64_t prs_load_h(uint32_t disp) {
    uint64_t r;
    asm volatile(".insn i CUSTOM_0, 0x1, %0, x0, %1" : "=r"(r) : "I"(disp));
    return r;
}
/* prs_cam_h_stp, prs_lensetmin_n, prs_cmpi_n_fail, prs_store_*, ... */
```

With these, the Phase-0 slice can be written as ordinary C and run once a
simulator understands the encodings (7.5).

### 7.3 Level 2 — binutils

- Add the parser instructions to GNU **as** (mnemonics → encodings) and **objdump**
  (disassembly), generated from the Phase-3 table.
- Now assembly reads `prs.load.h paccum, pcurptr+12` instead of `.insn` blobs.

### 7.4 Level 3 — LLVM / GCC

- **LLVM MC** layer first (assemble/disassemble), then **intrinsics/builtins** so
  the parser unit is reachable from Clang without inline asm.
- GCC builtins optional/parallel.
- Only worthwhile once encodings are frozen — churn here is expensive.

### 7.5 Level 4 — ISA simulators

- **Spike:** add the parser instructions as a custom extension implementing the
  Phase-2 semantics. Spike becomes an independent executable check of the ISA
  (and a cross-check for Phase 6).
- **QEMU (RISC-V):** model the instructions for faster functional runs and for
  driving larger corpora / the benchmark harness.
- Both must match the golden model bit-for-bit (reuse the Phase-2 corpus).

### 7.6 Consistency guarantee

Everything that touches bits — model encoder/decoder, `.insn` header, binutils,
LLVM MC, Spike, QEMU — is **generated from or checked against `isa/parser-opcodes.*`**.
No hand-copied encodings.

## Step-by-step tasks

1. Finalize `toolchain/parser_insn.h` (`.insn` + intrinsics) for every instruction.
2. Rewrite the Phase-0 slice parser in C using the intrinsics.
3. Add binutils as/objdump support (generated from the table).
4. Add Spike custom-extension support; validate against the Phase-2 corpus.
5. Add QEMU modeling; validate against the corpus.
6. (When frozen) add LLVM MC + intrinsics/builtins; optional GCC builtins.

## Deliverables / artifacts

- `toolchain/parser_insn.h` and a C implementation of the slice parser.
- binutils patch; Spike + QEMU models.
- (Later) LLVM/GCC support.

## Exit criteria

- The slice parser, written in C with intrinsics, assembles and runs on Spike and
  QEMU with outputs matching the golden model.
- Disassembly is human-readable (binutils/objdump).

## Open questions

- **Decision:** upstream-style patches vs. out-of-tree fork for binutils/LLVM/Spike?
- **TBD:** how much LLVM support is worth it pre-freeze (recommend: MC only).
- Register modeling in Spike/QEMU: dedicated parser regs vs. reserved integer subset
  (mirror the Phase-3/4 decision).

## References

`.insn` docs, riscv-gnu-toolchain, LLVM, Spike, QEMU. See [references.md](references.md).
