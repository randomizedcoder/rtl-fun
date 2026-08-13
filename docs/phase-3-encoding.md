# Phase 3 — Instruction encoding

← [Phase 2](phase-2-reference-model.md) · [Docs index](README.md) · [Phase 4 »](phase-4-microarchitecture.md)

## Objective

Give every parser instruction a **bit-accurate encoding** in the RISC-V
`custom-0..3` opcode space, with formats, funct-field assignments, and an
assembler `.insn` mapping so code can be emitted before full toolchain support.

## Inputs / prerequisites

- Phase 1 instruction set + operand forms.
- RISC-V base ISA formats (R/I/S) and the reserved custom opcodes.

## Design detail

### 3.1 Opcode budget

RISC-V reserves four major opcodes for non-standard use — `custom-0`, `custom-1`,
`custom-2`, `custom-3` — which standard extensions avoid. We sub-divide them with
`funct3` (and `funct7` where needed). Budget discipline is Risk R3: keep the set
small and Herbert-shaped.

Proposed major-opcode partition (**Decision**, revisit if space is tight):

| Major opcode | Instruction group |
|--------------|-------------------|
| `custom-0` | loads / stores (header ↔ metadata) |
| `custom-1` | length + compare (`lensetmin`, `cmpi`) |
| `custom-2` | CAM / lookup + end-of-node |
| `custom-3` | move / loop / runthread |

### 3.2 Formats

Most parser instructions are register-shaped with small immediates; we lean on
R-type and I-type.

R-type (e.g. CAM lookup, move):
```
 31        25 24    20 19    15 14   12 11     7 6            0
+------------+--------+--------+-------+---------+--------------+
|  funct7    |  rs2   |  rs1   |funct3 |   rd    |  custom-x    |
+------------+--------+--------+-------+---------+--------------+
```

I-type (e.g. load with displacement, compare-immediate):
```
 31              20 19    15 14   12 11     7 6            0
+------------------+--------+-------+---------+--------------+
|    imm[11:0]     |  rs1   |funct3 |   rd    |  custom-x    |
+------------------+--------+-------+---------+--------------+
```

Parser registers are addressed either via a dedicated parser-register file
(encoded in the rd/rs fields, interpreted by the parser unit) or mapped onto a
reserved integer-register subset — **Decision** pending Phase 4 (§1.1 ABI note).

### 3.3 funct3 assignment (illustrative)

Within `custom-0` (loads/stores):
| funct3 | Instr | Notes |
|--------|-------|-------|
| 000 | `prs.load.b` | width in funct3? or funct7? see below |
| 001 | `prs.load.h` | |
| 010 | `prs.load.w` | |
| 011 | `prs.load.d` | |
| 100 | `prs.store.b` | |
| 101 | `prs.store.h` | |
| … | … | |

Qualifiers (`.stp`, `.fail`, field selector `[i]`, multiplier/min for `lensetmin`)
are packed into `funct7` / immediate bits. Example `lensetmin.n pcurhdr,
paccum[i], M:MIN` packs `i`, multiplier `M`, and `MIN` into the immediate.

**Design tension:** encode width in funct3 (few opcodes, many funct7 uses) vs. in
funct7 (frees funct3 for classes). Resolve to maximize headroom for the CAM
sub-table field and the `lensetmin` immediate.

### 3.4 Assembler `.insn` mapping

Before touching binutils/LLVM, emit raw encodings via `.insn` and inline-asm
wrappers (bridges to Phase 7):

```c
static inline void prs_load_h(int disp) {
    /* .insn i <opcode>, <funct3>, rd, rs1, imm  */
    asm volatile(".insn i CUSTOM_0, 0x1, x0, x0, %0" :: "I"(disp));
}
```

Every instruction gets an `.insn` template + a documented bit layout so the
[Phase 2 model](phase-2-reference-model.md) can gain an encoder/decoder and the
[RTL](phase-5-rtl.md) decode can be built against the exact same table.

### 3.5 Machine-readable table

Keep the encoding as data (`isa/parser-opcodes.yaml` or CSV): one row per
instruction with major opcode, funct3, funct7 mask/match, format, operand map,
and `.insn` template. Generate from it: the RTL decode case-table, the model's
encoder/decoder, the assembler macros, and a disassembler stub. **Single source
of truth for bits.**

## Step-by-step tasks

1. Fix the major-opcode partition (3.1).
2. Choose width-in-funct3 vs funct7 (3.3) to preserve headroom.
3. Lay out each instruction's exact bit fields (R/I) incl. qualifiers/immediates.
4. Author the machine-readable table (3.5).
5. Write `.insn` templates + inline-asm wrappers for every instruction (3.4).
6. Add encode/decode to the Phase-2 model and cross-check round-trips.

## Deliverables / artifacts

- `isa/parser-opcodes.{yaml,csv}` — the bit-accurate table.
- `.insn` macros / inline-asm header (`toolchain/parser_insn.h`).
- Encoder/decoder wired into the golden model.

## Exit criteria

- Every instruction has a unique, bit-accurate encoding within `custom-0..3`.
- Round-trip encode→decode matches for all instructions in the model.
- `.insn` templates assemble with stock GNU as / LLVM MC.

## Open questions

- **Decision:** parser registers — dedicated file vs. reserved integer subset?
  (Co-decide with Phase 4; affects rd/rs interpretation.)
- **Decision:** 30-bit vs full 32-bit encodings (blog mentions 30-bit forms).
- **TBD:** compressed (16-bit) forms for hot instructions — worth it? (defer.)

## References

RISC-V unprivileged ISA (custom opcodes, formats); `.insn` docs. See
[references.md](references.md).
