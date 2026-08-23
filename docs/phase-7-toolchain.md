# Phase 7 — Toolchain support

← [Phase 6](phase-6-verification.md) · [Docs index](README.md) · [Phase 8 »](phase-8-fpga.md)

## Objective

Make the parser instructions usable from real code, in increasing order of
investment: raw `.insn` → intrinsics → assembler → compiler → ISA simulators. Do
the cheap thing first; only add heavyweight tool support once the ISA has settled.

> **Status: 🔵 In progress — the exit criterion is met** (the C slice runs on Spike **and**
> QEMU == the golden model); the remaining work is the deferred tail (LLVM MC + GCC builtins,
> full upstream riscv-tests, riscv-dv, the non-slice ISA groups, and the prose-freeze items).
> - **Level 1 (§7.2) — done:** the `.insn` + intrinsics header
>   [`toolchain/parser_insn.h`](../toolchain/parser_insn.h) emits every slice
>   instruction from the Phase-3 table.
> - **Level 4 (§7.5) — standalone Spike (Stage 2) + C-intrinsics slice (Stage 3) + QEMU:**
>   the parser custom extension (Phase-2 semantics, reusing `libparsermodel`,
>   `nix/spike-tandem/parser_ext.cc`) was first built libraries-only as the
>   [Phase-6](phase-6-verification.md) RVFI-vs-Spike lock-step oracle (`spike-tandem`). Stage 2
>   adds a **runnable** standalone `spike` ([`nix/spike-parser.nix`](../nix/spike-parser.nix),
>   `install-exes`) with the same extension + the `0x5000_0000` packet MMIO device
>   (`nix run .#parser-spike`). Stage 3 then **authors the slice in C** with the generated
>   intrinsics ([`tests/cva6-parser/parser_slice.c`](../tests/cva6-parser/parser_slice.c)):
>   `nix run .#parser-spike-slice` compiles it, asserts its 53 words are byte-identical to the
>   model ROM, and runs it on the standalone Spike over the 22-case corpus == model. The **QEMU
>   leg** then teaches a patched `qemu-system-riscv64` the same ops + device
>   ([`nix/qemu-parser.nix`](../nix/qemu-parser.nix)) and runs the identical ELFs and C slice on
>   it (`nix run .#parser-qemu` / `.#parser-qemu-slice`, both 22/0 == model). With Spike **and**
>   QEMU green, **the exit criterion is met** ✅.
> - **Level 2 (§7.3) — done:** a parser-patched `riscv64-none-elf` binutils
>   ([`nix/parser-binutils.nix`](../nix/parser-binutils.nix)) assembles the `prs.*`
>   mnemonics and `objdump` disassembles them — Hybrid operand syntax **plus** the
>   additive Stage-1.5 prose sugar (`pcurptr+N`, `paccum[i]`, `value:mask`; see §7.3).
>   `nix run .#parser-asm-test` assembles every mnemonic (both syntaxes) and checks each
>   word equals the generated/model golden, that objdump renders it readably, **and** that
>   the disassembly reassembles to the same encodings (round-trip).
> - **In progress — the *prose-freeze* follow-on:** the notation items that needed an
>   ISA-notation decision (not just code) are now **frozen** in
>   [phase-1-isa-spec.md](phase-1-isa-spec.md) §1.12: the load `E` → `.be` (E=1 = big-endian),
>   `.stp` = the group S bit, `mult:min` (log2), the `.stop`/`.stopnode`/`.stopsub`/`.fail`
>   (cmp `Er`) + CAM `Miss` + `.min` (length `D`) suffixes, store/storeimm `pmeta+N`, required
>   destination pseudo-registers, and the `prs.lenset{,min,add}` / `prs.cmpi{,ne}` aliases —
>   being implemented as suffix-variant + alias rows in `tools/parser-gen` + the binutils patch
>   (bits unchanged; §7.3). Then LLVM MC + intrinsics/builtins and GCC
>   builtins (L3), and the
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
- **Prose-freeze (pinned; implementing):** the notation items that needed an ISA-notation
  *decision*, not just code, are now **frozen** in
  [phase-1-isa-spec.md](phase-1-isa-spec.md) §1.12 "Assembly notation (frozen)": the load
  `E`-bit → `.be` suffix (E=1 = big-endian; the model is the source of truth and the polarity
  prose was corrected to it); `.stp` = the group S bit on cam/camnext + the length family
  (distinct from the standalone `prs.stp` `next`-group word — same effect, different encoding);
  `mult:min` (assembler sets `Shift=log2(mult)`); the `.stop`/`.stopnode`/`.stopsub`/`.fail`
  (cmp `Er`), CAM `Miss`, and `.min` (length `D`) suffixes; store/storeimm `pmeta+N` (a
  metadata-frame displacement, distinct from load's packet `pcurptr+N`); required destination
  pseudo-register decoration (`paccum`/`pnext`/`pcurhdr`/`pdathdr`), where for CAM the
  `paccum`/`pnext` destination **selects** the `D` bit — a single `prs.cam` mnemonic (no separate
  `prs.camnext`), matching the patent's disassembly; and the
  `prs.lenset{,min,add}` / `prs.cmpi{,ne}` mnemonic aliases. Unlike Stage-1.5 these fold bits
  into the mnemonic/aliases (not pure operand sugar), so they extend `tools/parser-gen` with
  suffix-variant + alias rows; every spelling still encodes to identical bits and round-trips
  through objdump.

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
  and runs it on the standalone Spike over the 22-case corpus == model. This **closes the Spike
  leg** of the exit criterion.
- **QEMU (RISC-V) ✅:** `nix build .#qemu-parser`
  ([`nix/qemu-parser.nix`](../nix/qemu-parser.nix)) patches nixpkgs `qemu` (11.0.3,
  restricted to `riscv64-softmmu`) to decode + execute the custom-0/custom-3 parser ops
  via TCG helpers ([`nix/qemu-parser/parser_helper.c`](../nix/qemu-parser/parser_helper.c),
  a port of the Spike `parser_ext.cc` reusing `libparsermodel` unchanged) and to map the
  `0x5000_0000` packet MMIO device ([`parser_mmio.c`](../nix/qemu-parser/parser_mmio.c)) on
  the `-M spike` machine — whose HTIF (`tohost=1` → exit 0) + DRAM@0x80000000 run the
  existing self-checking ELFs unmodified. Custom-3 (0x7b) aliases QEMU's RV128 doubleword ops,
  which are remapped to the unused custom-1 opcode (rv64 never uses RV128); on stock QEMU the
  ops trap illegal (a genuine extension). `nix run .#parser-qemu` runs the `parser_tandem.S`
  smoke + the **22-case corpus == model** on the patched `qemu-system-riscv64`, and `nix run
  .#parser-qemu-slice` compiles the C slice (byte-identical to the model ROM) and runs it
  **22/0 == model**. This **closes the QEMU leg** — the exit criterion is met on both
  simulators. (`-nographic` wires the guest console to stdin, so the runner gives QEMU
  `</dev/null` to avoid draining the per-case suite loop.)
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
   model on the standalone Spike) **and** `nix run .#parser-qemu-slice` (same slice, 22/0
   == model on QEMU).
3. ✅ Add binutils as/objdump support (generated from the table) — Hybrid operand
   syntax + additive prose sugar (`pcurptr+N`, `paccum[i]`, `value:mask`); round-tripping
   `objdump`. `nix run .#parser-asm-test`. Prose-freeze items deferred (§7.3).
4. ✅ Add Spike custom-extension support; validate against the Phase-2 corpus —
   standalone `nix run .#parser-spike` (Stage 2) + the C slice on it (Stage 3).
5. ✅ Add QEMU modeling; validate against the corpus — patched `qemu-system-riscv64`
   ([`nix/qemu-parser.nix`](../nix/qemu-parser.nix)), `nix run .#parser-qemu` (asm corpus)
   + `nix run .#parser-qemu-slice` (C slice), both 22/0 == model.
6. (When frozen) add LLVM MC + intrinsics/builtins; optional GCC builtins.

## Deliverables / artifacts

- `toolchain/parser_insn.h` and a C implementation of the slice parser.
- binutils patch; Spike + QEMU models.
- (Later) LLVM/GCC support.

## Exit criteria

- ✅ **Met.** The slice parser, written in C with intrinsics, assembles and runs on Spike
  **and** QEMU with outputs matching the golden model. **Spike leg** (`nix run
  .#parser-spike-slice`) and **QEMU leg** (`nix run .#parser-qemu-slice`): the C slice is
  byte-identical to the model ROM (53 words == `enc.hex`) and runs the 22-case corpus == model
  on both simulators. The asm-corpus twins (`parser-spike` / `parser-qemu`) also pass 22/0.
- Disassembly is human-readable (binutils/objdump). ✅ (`nix run .#parser-asm-test`)

## Open questions

- **Decision:** upstream-style patches vs. out-of-tree fork for binutils/LLVM/Spike?
- **TBD:** how much LLVM support is worth it pre-freeze (recommend: MC only).
- Register modeling in Spike/QEMU: dedicated parser regs vs. reserved integer subset
  (mirror the Phase-3/4 decision).

## References

`.insn` docs, riscv-gnu-toolchain, LLVM, Spike, QEMU. See [references.md](references.md).
