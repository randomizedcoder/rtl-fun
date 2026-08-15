# isa/ — machine-readable encoding tables (Phase 3)

The single source from which both the assembler mapping and the SystemVerilog
decode/encode packages are **generated** (see ADR-002 in
[`docs/phase-0-scope-and-stack.md`](../docs/phase-0-scope-and-stack.md) §0.3).

Holds the `Fnc4` opcode map, the 32-bit instruction formats, the `Sz`/parser-code
constants, and CAM-key layouts — transcribed from
[`docs/analysis/patent-encodings-recovered.md`](../docs/analysis/patent-encodings-recovered.md)
into a structured form (e.g. YAML/JSON) plus the generator that emits SV + the
assembler `.insn` macros.

*Empty until Phase 3. See [`docs/phase-3-encoding.md`](../docs/phase-3-encoding.md).*
