# model/ — golden reference model (Phase 2)

The **architectural source of truth**: a C model of the parser ISA with one
`execute_*` per instruction, matching the semantics in
[`docs/phase-1-isa-spec.md`](../docs/phase-1-isa-spec.md) and the recovered
encodings in
[`docs/analysis/patent-encodings-recovered.md`](../docs/analysis/patent-encodings-recovered.md).

RTL is verified against this model in co-simulation (Phase 6). Nothing here
depends on cycle timing — this is pure ISA semantics.

*Empty until Phase 2. See [`docs/phase-2-reference-model.md`](../docs/phase-2-reference-model.md).*
