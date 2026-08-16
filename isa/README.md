# isa/ — machine-readable encoding tables (Phase 3)

The single source from which both the assembler mapping and the SystemVerilog
decode/encode packages are **generated** (see ADR-002 in
[`docs/phase-0-scope-and-stack.md`](../docs/phase-0-scope-and-stack.md) §0.3).

Holds the `Fnc4` opcode map, the 32-bit instruction formats, the `Sz`/parser-code
constants, and CAM-key layouts — transcribed from
[`docs/analysis/patent-encodings-recovered.md`](../docs/analysis/patent-encodings-recovered.md)
into a structured form plus (later) the generator that emits SV + the assembler
`.insn` macros.

## `parser-opcodes.yaml`

The bit-accurate encoding table (Phase 3): framing (custom-0 `0x0b` + `Fnc4`;
custom-3 `0x7b` coprocessor), the `Fnc4` group map, `Sz` rules, per-group field
bit-ranges with discriminators, the next-word/CAM-key formats, and the Parser
Codes. Bit numbering is LSB-0 (a field the recovered doc lists `[hi:lo]` is
`[hi, lo]` here), matching the C encoder.

Consumers of this table:
- [`model/libparsermodel/encoding.c`](../model/libparsermodel/encoding.c) — the C
  encoder/decoder (kept in sync by the round-trip tests in `nix run .#model-test`).
- [`toolchain/parser_insn.h`](../toolchain/parser_insn.h) — `.insn` word builders.
- Phase 5 RTL decode table + Phase 7 assembler (to be generated from this file).

See [`docs/phase-3-encoding.md`](../docs/phase-3-encoding.md).
