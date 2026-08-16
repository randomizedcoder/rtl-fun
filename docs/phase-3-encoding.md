# Phase 3 — Instruction encoding

← [Phase 2](phase-2-reference-model.md) · [Docs index](README.md) · [Phase 4 »](phase-4-microarchitecture.md)

## Objective

Give every parser instruction a **bit-accurate encoding**, following the patent's
actual scheme (not the class-per-opcode guess we started with). Provide formats,
field tables, and an assembler `.insn` mapping so code can be emitted before full
toolchain support.

> **Source of truth for bits:**
> [`analysis/patent-encodings-recovered.md`](analysis/patent-encodings-recovered.md)
> — **complete and pixel-verified** from the official USPTO drawing sheets
> (`Fnc4` opcode map, every 32-bit instruction format with exact bit ranges, the
> custom-3 **coprocessor** formats, the Parser Codes table, `Sz` tables, address/
> code + CAM-key formats, register layouts, and the p0–p31 init table). **No
> remaining encoding gaps.**

## Inputs / prerequisites

- Phase 1 instruction set + operand forms.
- RISC-V base ISA formats and the reserved custom opcodes.

## Design detail

### 3.1 Opcode framing (patent-specified)

- **32-bit** parser instructions: RISC-V **custom-0 opcode `[6:0]=0b0001011` (0x0B)**
  + **`Fnc4=[10:7]`** selecting the instruction group (full map:
  [encodings §1.1](analysis/patent-encodings-recovered.md)). Targets **4-byte
  aligned**.
- **64-bit** variant: uses the >32-bit opcode space; **8-byte aligned**. 32/64-bit
  forms interoperate (branch/fall-through) if aligned. *(Companion doc; we implement
  32-bit first.)*
- **Coprocessor** moves + CAM/array programming: **custom-3 `0x7b`**, R-form with
  `CoP=[31:29]=000`, `Cpreg=[28:24]`, `Rs=[19:15]`, `Func3=[14:12]`, `Rd=[11:7]`
  (`CPPRSRD/WR/WRIMM/WRCAM/RDCAM/WRARRAY/RDARRAY`; full table:
  [encodings §2.2](analysis/patent-encodings-recovered.md)).

> This **replaces** our earlier "partition custom-0..3 by instruction class" plan.
> The patent uses **one** primary opcode (custom-0) + a function field, plus custom-3
> for coprocessor transfers.

### 3.2 Address / code encoding (bit-31 selector)

Values in `Next`, `DataBndLoop.Loop`, and CAM/array targets encode an address **or**
a parser code:

```
 bit31 = 0 → 24-bit relative address (bits[23:0]); control bits E/V/NE/NV in [30:24]
 bit31 = 1 → parser code (negative −1..−128; sign-extends to 16/32/64-bit)
```

Address derivations: CAM / instruction-relative `ParserInstrBase | (4*addr)`;
`PNEXTNODE` PC-relative `PC + (addr<<2)`.

**Control bits** (address form, bits 24–30): `E` encapsulation (`0x40000000`),
`V` overlay (`0x20000000`), `NE` next-encap, `NV` next-overlay — consumed by
end-of-node ([Phase 1 §1.8](phase-1-isa-spec.md)).

### 3.3 `Sz` field — two meanings

- **General sub-register instructions:** `Sz` 0=nibble / 1=byte / 2=half / 3=word;
  bits = `4*(1<<Sz)`.
- **Load / store:** `Sz` 1=byte / 2=half / 3=word / **0 = double word (8 bytes)**.

**Sub-register position:** counted from the first byte (position 0 = low-order byte,
little-endian); nibble 0 = high 4 bits of the first byte.

### 3.4 CAM key structure

20-bit key + 32-bit target. Union by the 4 high `Shared` bits:

```c
union {
  struct { Match:16; Shared:4 /* 1..15 */ } Shared;     // shared table, ≤16-bit match
  struct { Match:8; Selector:8; Shared:4 /* 0 */ } NonShared;  // PC-derived selector
}
// non-shared: Selector = (PC << 6) & 0xFF00   (collisions illegal; pad with NOPs)
```

### 3.5 Per-instruction fields (recovered, exact)

Every 32-bit instruction format is now pixel-verified with exact bit ranges — see
the RFC-style diagrams and per-group discriminator tables in
[encodings §2](analysis/patent-encodings-recovered.md). Examples (bit ranges exact):
- **Load `Fnc4=0000`:** `X[31] D[30] Sz[29:28] Blen[27:24] Shift[23:21] E[20]
  Offset[19:11] Fnc4[10:7] Opcode[6:0]`.
- **CAM `Fnc4=1000`:** `S[31] D[30] Sz[29:28] Pos[27:24] Func3[23:21] F[20]
  Share[19:16] Miss[15:11] …`.
- **Store `Fnc4=0100`:** `S[31] F[30] Sz[29:28] Pos[27:24] J[23] Sind[22:20]
  Offset[19:11] …`.
- **Compare `Fnc4=1011`:** `S[31] D[30] Sz[29:28] Pos[27:24] Func3[23:21] Er[20:19]
  Value[18:11] …`.

### 3.6 Machine-readable table

Keep the encoding as data (`isa/parser-opcodes.yaml`): one row per instruction with
primary opcode (`0x0b`/`0x7b`), function value, field list (name/width/**position or
TBD**), operand map, and `.insn` template. Generate from it: the RTL decode table,
the model's encoder/decoder, the assembler macros, and a disassembler stub.

### 3.7 Assembler `.insn` mapping

Before touching binutils/LLVM, emit raw encodings via `.insn` + inline-asm wrappers,
built directly from the exact fields (opcode `0x0b`, `Fnc4`, and the per-instruction
bit ranges in [encodings §2](analysis/patent-encodings-recovered.md)):

```c
/* PLOAD .h from pcurptr+disp: X=0 D=0 Sz=2 Fnc4=0000 Opcode=0x0b */
static inline uint64_t prs_load_h(unsigned off) {
    uint64_t r; uint32_t w = 0x0b | (0x0 << 7) | ((off & 0x1ff) << 11) | (2u << 28);
    asm volatile(".insn 0x%x" : "=r"(r) : "i"(w));   /* fields now exact */
    return r;
}
```

## Step-by-step tasks

1. Encode the framing (custom-0 `0x0b` + 4-bit function; custom-3 moves) (3.1).
2. Encode the address/code scheme + control bits (3.2) and the `Sz`/position rules
   (3.3) and CAM key union (3.4).
3. Author the machine-readable table with fields + **exact bit positions** +
   semantics from [encodings §2](analysis/patent-encodings-recovered.md) (3.5–3.6).
4. Write `.insn` templates keyed off the table (3.7).
5. Add encode/decode to the Phase-2 model; round-trip check every instruction
   (custom-0 and custom-3).

## Deliverables / artifacts

- [`isa/parser-opcodes.yaml`](../isa/parser-opcodes.yaml) — machine-readable table:
  framing, `Fnc4` map, `Sz` rules, per-group bit ranges + discriminators,
  custom-3 coprocessor forms, next-word/CAM-key formats, and Parser Codes. ✅
- [`toolchain/parser_insn.h`](../toolchain/parser_insn.h) — `.insn` word builders /
  inline-asm emitters keyed off the exact fields. ✅
- Encoder/decoder wired into the golden model
  ([`encoding.h`](../model/libparsermodel/encoding.h) /
  [`encoding.c`](../model/libparsermodel/encoding.c)) with `pm_encode` for the
  model's opcode set + custom-3. ✅

## Exit criteria

- ✅ Framing, `Fnc4` map, per-instruction bit ranges (custom-0 **and** custom-3),
  address/code encoding, `Sz` rules, CAM key structure, and Parser Codes are exact
  and match the patent (`isa/parser-opcodes.yaml`) — no encoding gaps.
- ✅ Every instruction in the slice program encodes to its exact custom-0 word and
  decodes back; golden-vector + round-trip tests pass (`nix run .#model-test`).

**Scope note:** the C encoder covers the opcode set the model executes (load,
length, store/storeimm, cam/camnext, compares, next/stp) plus the custom-3
coprocessor moves. The remaining groups (array, counters, extract/loop, TLV
length, lifecycle) are specified in the YAML with exact bits but their encoders +
execution land alongside their model support (see Phase-2 deferrals). 64-bit form
deferred per the decision below.

## Open questions

- **Decision:** 32-bit only first (defer the 64-bit form).
- **Decision:** parser registers as a dedicated file addressed in `rd/rs` — confirm
  with Phase 4.

## References

RISC-V custom opcodes; patent framing (custom-0 `0x0b`);
[`analysis/patent-encodings-recovered.md`](analysis/patent-encodings-recovered.md).
See [references.md](references.md).
