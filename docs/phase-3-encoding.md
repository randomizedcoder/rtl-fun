# Phase 3 — Instruction encoding

← [Phase 2](phase-2-reference-model.md) · [Docs index](README.md) · [Phase 4 »](phase-4-microarchitecture.md)

## Objective

Give every parser instruction a **bit-accurate encoding**, following the patent's
actual scheme (not the class-per-opcode guess we started with). Provide formats,
field tables, and an assembler `.insn` mapping so code can be emitted before full
toolchain support.

> **Source of truth for bits:**
> [`analysis/patent-encodings-recovered.md`](analysis/patent-encodings-recovered.md)
> (recovered from the patent prose — the figure images did not survive extraction).
> **Per-instruction field *bit-positions* are TBD-from-figure** (need the official
> USPTO drawing sheets); everything else below is from the patent text.

## Inputs / prerequisites

- Phase 1 instruction set + operand forms.
- RISC-V base ISA formats and the reserved custom opcodes.

## Design detail

### 3.1 Opcode framing (patent-specified)

- **32-bit** parser instructions: RISC-V **custom-0 primary opcode `0x0b`** + a
  **4-bit function field** that selects the instruction. (In the patent's
  disassembly every parser opcode byte ends in `0b`.) Targets **4-byte aligned**.
- **64-bit** variant: uses the >32-bit opcode space; **8-byte aligned**. 32/64-bit
  forms interoperate (branch/fall-through) if aligned. *(Companion doc; we implement
  32-bit first.)*
- **Coprocessor** moves + CAM/array programming: **custom-3 `0x7b`**, `CoP=0` =
  parser coprocessor (`CPPRSRD/WR/WRIMM/WRCAM/RDCAM/WRARRAY/RDARRAY`).

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

### 3.5 Per-instruction fields (positions TBD-from-figure)

The patent gives each instruction's **field set and semantics** (Phase 1), and the
register/`Sz`/address encodings above — but the **bit positions within the 32-bit
word** live in per-instruction figures absent from our copy. Until we obtain the
drawing sheets, the machine-readable table (§3.6) records **fields + widths +
semantics**, with positions marked TBD. Representative field sets:
- **Load:** funct, X, Sz, E, Shift, Blen, rd(preg), Offset.
- **Length:** funct, D, Sz, Pos, Shift, Len, S.
- **CAM:** funct, Sz, Pos, F, Share, Miss, A, S.
- **Compare:** funct, Func3, Sz, Pos, N, Er, Value/Mask.
- **Next/imm:** funct, V(overlay), S, Next/Mask(16).
- **Store:** funct, F, Sz, Pos, Sind, E, J, S, Offset.

### 3.6 Machine-readable table

Keep the encoding as data (`isa/parser-opcodes.yaml`): one row per instruction with
primary opcode (`0x0b`/`0x7b`), function value, field list (name/width/**position or
TBD**), operand map, and `.insn` template. Generate from it: the RTL decode table,
the model's encoder/decoder, the assembler macros, and a disassembler stub.

### 3.7 Assembler `.insn` mapping

Before touching binutils/LLVM, emit raw encodings via `.insn` + inline-asm wrappers.
Because exact bit positions are TBD, seed the header from the machine-readable table
and fill positions once recovered:

```c
static inline uint64_t prs_load_h(int disp) {
    uint64_t r;
    asm volatile(".insn r CUSTOM_0, /*funct3*/0, /*funct7*/0, %0, x0, %1"
                 : "=r"(r) : "r"(disp));   /* fields TBD-from-figure */
    return r;
}
```

## Step-by-step tasks

1. Encode the framing (custom-0 `0x0b` + 4-bit function; custom-3 moves) (3.1).
2. Encode the address/code scheme + control bits (3.2) and the `Sz`/position rules
   (3.3) and CAM key union (3.4).
3. Author the machine-readable table with fields + widths + semantics; mark
   bit-positions TBD (3.5–3.6).
4. Write `.insn` templates keyed off the table (3.7).
5. Add encode/decode to the Phase-2 model; round-trip check what is fully known.
6. **Recover** exact bit positions + the Parser Codes value table from the official
   USPTO drawing sheets; fill in the table; remove the TBDs.

## Deliverables / artifacts

- `isa/parser-opcodes.yaml` — fields/widths/semantics (+ positions once recovered).
- `.insn` macros / inline-asm header (`toolchain/parser_insn.h`).
- Encoder/decoder wired into the golden model.

## Exit criteria

- Framing, address/code encoding, `Sz` rules, and CAM key structure are exact and
  match the patent.
- Every instruction has a table row; fully-known encodings round-trip in the model;
  remaining bit-positions are explicitly flagged TBD-from-figure.

## Open questions

- **P2 / blocking full exactness:** obtain the drawing sheets (per-instruction bit
  layouts + Parser Codes table). Source: `patentimages` PDF or XDP2.
- **Decision:** 32-bit only first (defer the 64-bit form).
- **Decision:** parser registers as a dedicated file addressed in `rd/rs` — confirm
  with Phase 4.

## References

RISC-V custom opcodes; patent framing (custom-0 `0x0b`);
[`analysis/patent-encodings-recovered.md`](analysis/patent-encodings-recovered.md).
See [references.md](references.md).
