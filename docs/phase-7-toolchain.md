# Phase 7 — Toolchain support

← [Phase 6](phase-6-verification.md) · [Docs index](README.md) · [Phase 8 »](phase-8-fpga.md)

## Objective

Make the parser instructions usable from real code, in increasing order of
investment: raw `.insn` → intrinsics → assembler → compiler → ISA simulators. Do
the cheap thing first; only add heavyweight tool support once the ISA has settled.

> **Status: 🔵 In progress.**
> - **Level 1 (§7.2) — done:** the `.insn` + intrinsics header
>   [`toolchain/parser_insn.h`](../toolchain/parser_insn.h) emits every slice
>   instruction from the Phase-3 table.
> - **Level 4 Spike (§7.5) — standalone simulator (Stage 2) + C-intrinsics slice (Stage 3):**
>   the parser custom extension (Phase-2 semantics, reusing `libparsermodel`,
>   `nix/spike-tandem/parser_ext.cc`) was first built libraries-only as the
>   [Phase-6](phase-6-verification.md) RVFI-vs-Spike lock-step oracle (`spike-tandem`). Stage 2
>   adds a **runnable** standalone `spike` ([`nix/spike-parser.nix`](../nix/spike-parser.nix),
>   `install-exes`) with the same extension + the `0x5000_0000` packet MMIO device
>   (`nix run .#parser-spike`). Stage 3 then **authors the slice in C** with the generated
>   intrinsics ([`tests/cva6-parser/parser_slice.c`](../tests/cva6-parser/parser_slice.c)):
>   `nix run .#parser-spike-slice` compiles it, asserts its 53 words are byte-identical to the
>   model ROM, and runs it on the standalone Spike over the 22-case corpus == model. This
>   **closes the Spike leg** of the exit criterion; the one remaining leg is running the same
>   slice on **QEMU** (L4).
> - **Level 2 (§7.3) — done:** a parser-patched `riscv64-none-elf` binutils
>   ([`nix/parser-binutils.nix`](../nix/parser-binutils.nix)) assembles the `prs.*`
>   mnemonics and `objdump` disassembles them — Hybrid operand syntax **plus** the
>   additive Stage-1.5 prose sugar (`pcurptr+N`, `paccum[i]`, `value:mask`; see §7.3).
>   `nix run .#parser-asm-test` assembles every mnemonic (both syntaxes) and checks each
>   word equals the generated/model golden, that objdump renders it readably, **and** that
>   the disassembly reassembles to the same encodings (round-trip).
> - **Open:** the *prose-freeze* follow-on — the parts of the docs' prose that need an
>   ISA-notation decision, not just code: the load `E` spelling, `.stp` fused onto CAM,
>   `mult:min` (log2), the `.fail`/`.min`/`.stop` value qualifiers, store `+N`, and the
>   `lensetmin`/`cmpi` mnemonic aliases. Then LLVM MC + intrinsics/builtins and GCC
>   builtins (L3), **QEMU** modeling (L4), the C-intrinsics slice rewrite (task 2), and the
>   heavyweight random-instruction checks — full upstream riscv-tests and riscv-dv (the
>   latter blocked on a commercial UVM simulator; the Phase-6 Stage-2 campaign randomizes
>   only the *packet* axis).

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

### 7.3 Level 2 — binutils ✅

- **Done.** [`nix/parser-binutils.nix`](../nix/parser-binutils.nix) patches nixpkgs
  `riscv64-none-elf` binutils 2.46 to add the parser instructions to GNU **as**
  (mnemonics → encodings) and **objdump** (disassembly). The opcode-table rows are
  **generated** by `tools/parser-gen` into
  [`toolchain/generated/parser-opc-gas.inc`](../toolchain/generated/parser-opc-gas.inc)
  and pasted into the patch; immediates ride binutils' stock `XtuN@S` bitfield operand,
  so the hand-written operand classes are just the parser p-register `Xpr` (Cpreg[28:24],
  names from the yaml `p_registers`) and the three Stage-1.5 prose operands
  (`Xpo`/`Xpa`/`Xpm`, below).
- **Hybrid operand syntax** (the increment that landed): real register operands where they
  exist + a dotted size suffix, e.g.

  ```asm
  prs.load.h    1, 12          ; Sz via .h suffix; E=1, Offset=12
  prs.store.b   0, 8           ; Pos=0, Offset=8
  prs.mv.p.x    pnext, a0      ; write GPR a0 -> parser p-register pnext
  prs.mv.x.p    a1, paccum     ; read parser p-register paccum -> GPR a1
  ```

  Objdump round-trips the register names (`pnext`, `paccum`, …). This replaces `.insn`
  blobs for the assemblable slice.
- **Prose operand sugar (Stage 1.5, additive) ✅:** on top of Hybrid, the lossless subset
  of the docs' prose that maps cleanly and reversibly to encoder bits. Three forms, driven
  by a `prose:` map in the yaml and emitted as extra opcode rows by `tools/parser-gen`:

  ```asm
  prs.load.h    1, pcurptr+12         ; Offset via pcurptr+N (bare `pcurptr` == 0)
  prs.store.b   paccum[0], 8          ; Pos via paccum[i] sub-register index
  prs.cmpib     1, paccum[0], 0x40:0xF0  ; Value:Mask as one value:mask pair
  ```

  Each sugared mnemonic gets a prose row **before** its Hybrid row (identical match/mask):
  gas tries the prose row first, so `objdump` prints the sugar; the Hybrid form still
  assembles because gas falls through when the `pcurptr`/`paccum` keyword is absent. Both
  syntaxes hit the exact same word, and the disassembly reassembles (round-trip). The new
  operand classes (`XpoN@S` = `pcurptr+N`, `XpaN@S` = `paccum[i]`, `Xpm` = `value:mask`)
  live in the patch's `Xp` vendor namespace next to `Xpr`.
- **Deferred — the prose-freeze follow-on:** the parts of the docs' prose that need an
  ISA-notation decision, not just code, and so must be pinned in the yaml/docs first: the
  load `E`-bit spelling; `.stp` fused onto CAM (vs the separate `prs.stp`); `mult:min` with
  the log2 transform; the `.fail`/`.min`/`.stop`/`.stopnode` value qualifiers; store/storeimm
  `pcurptr+N`; bare pseudo-register *destination* decoration; and the `lensetmin`/`cmpi`
  mnemonic aliases. None of these round-trip as pure operand sugar today.

### 7.4 Level 3 — LLVM / GCC

- **LLVM MC** layer first (assemble/disassemble), then **intrinsics/builtins** so
  the parser unit is reachable from Clang without inline asm.
- GCC builtins optional/parallel.
- Only worthwhile once encodings are frozen — churn here is expensive.

### 7.5 Level 4 — ISA simulators

- **Spike ✅ (standalone, Stage 2):** the parser instructions are a custom extension
  (`nix/spike-tandem/parser_ext.cc`) implementing the Phase-2 semantics by reusing the
  pure-C `libparsermodel`. [`nix/spike-parser.nix`](../nix/spike-parser.nix) builds a
  **runnable** `spike` from the vendored CVA6 tree (`install-exes`; the executables link
  the shared `yaml-cpp` — the one delta from the libraries-only `spike-tandem`), with the
  `0x5000_0000` packet MMIO device registered on the bus (the same `Simulation.cc` patch
  the tandem uses, since the `spike` main is that openhw `Simulation`). `nix run
  .#parser-spike` runs the ELFs directly (`spike --isa=rv64gc`; the parser extension is
  always-on via `Proc.cc`, so no `--extension` flag — passing it would double-register): a
  `parser_tandem.S` smoke then the 22-case packet corpus, each passing iff it self-checks
  == the golden model (HTIF `tohost=1` → exit 0). This is Spike as an **independent
  executable** check of the ISA, distinct from the Phase-6 `spike-tandem` oracle (left
  untouched).
- **Level 4 Spike — the slice is now written in C (Stage 3):** the Phase-0 slice is authored
  as ordinary C with the generated intrinsics
  ([`tests/cva6-parser/parser_slice.c`](../tests/cva6-parser/parser_slice.c): 53 `PRS_EMIT(
  prs_*(...))` calls, one per `pm_slice_program()` entry). `nix run .#parser-spike-slice`
  compiles it (-O2), asserts the 53 words are **byte-identical to the model ROM** (`enc.hex`),
  and runs it on the standalone Spike over the 22-case corpus == model. The **Spike leg of the
  exit criterion is closed**; only the QEMU leg remains.
- **QEMU (RISC-V):** model the instructions for faster functional runs and for
  driving larger corpora / the benchmark harness. Still open — the remaining leg of the
  exit criterion (the same C slice must also run on QEMU == model).
- Both must match the golden model bit-for-bit (reuse the Phase-2 corpus).

### 7.6 Consistency guarantee

Everything that touches bits — model encoder/decoder, `.insn` header, binutils,
LLVM MC, Spike, QEMU — is **generated from or checked against `isa/parser-opcodes.*`**.
No hand-copied encodings.

> **Status: ✅ the codegen spine is real.** `tools/parser-gen` reads
> `isa/parser-opcodes.yaml` (the new `mnemonics:` block + the `groups:` bit-truth) and
> emits `toolchain/generated/`: the binutils opcode fragment (`parser-opc.inc`,
> match/mask + operand descriptors — consumed by the L2 binutils patch) and the
> `parser_intrinsics.h` word-builders. `nix run .#parser-gen-check` regenerates and
> proves (a) the committed artifacts are byte-stable and (b) the generated encoders
> equal the model's hand-written `encoding.c` + the golden constants
> (`prs_load_h(12)==0x2010600b`) — closing the yaml↔C drift the round-trip tests can't
> catch. Scope = the `pm_encode` custom-0 set + the custom-3 moves.

## Step-by-step tasks

1. ✅ Finalize the `.insn` + intrinsics for every instruction — generated,
   drift-checked `toolchain/generated/parser_intrinsics.h` (`PRS_EMIT` now emits a
   correctly-unsigned `.insn 4` word, exercised for real by the Stage-3 slice).
2. ✅ Rewrite the Phase-0 slice parser in C using the intrinsics —
   [`tests/cva6-parser/parser_slice.c`](../tests/cva6-parser/parser_slice.c),
   `nix run .#parser-spike-slice` (byte-identical to the model ROM, 22-case corpus ==
   model on the standalone Spike). The QEMU leg (task 5) remains.
3. ✅ Add binutils as/objdump support (generated from the table) — Hybrid operand
   syntax + additive prose sugar (`pcurptr+N`, `paccum[i]`, `value:mask`); round-tripping
   `objdump`. `nix run .#parser-asm-test`. Prose-freeze items deferred (§7.3).
4. ✅ Add Spike custom-extension support; validate against the Phase-2 corpus —
   standalone `nix run .#parser-spike` (Stage 2) + the C slice on it (Stage 3).
5. Add QEMU modeling; validate against the corpus.
6. (When frozen) add LLVM MC + intrinsics/builtins; optional GCC builtins.

## Deliverables / artifacts

- `toolchain/parser_insn.h` and a C implementation of the slice parser.
- binutils patch; Spike + QEMU models.
- (Later) LLVM/GCC support.

## Exit criteria

- The slice parser, written in C with intrinsics, assembles and runs on Spike and
  QEMU with outputs matching the golden model. **Spike leg ✅** (`nix run
  .#parser-spike-slice`: the C slice is byte-identical to the model ROM and runs the
  22-case corpus == model); **QEMU leg open.**
- Disassembly is human-readable (binutils/objdump). ✅ (`nix run .#parser-asm-test`)

## Open questions

- **Decision:** upstream-style patches vs. out-of-tree fork for binutils/LLVM/Spike?
- **TBD:** how much LLVM support is worth it pre-freeze (recommend: MC only).
- Register modeling in Spike/QEMU: dedicated parser regs vs. reserved integer subset
  (mirror the Phase-3/4 decision).

## References

`.insn` docs, riscv-gnu-toolchain, LLVM, Spike, QEMU. See [references.md](references.md).
