# Design docs — index

This folder plans the entire project: from Tom Herbert's *parser instructions*
concept to real SystemVerilog RTL for a RISC-V ISA extension, verified against a
golden model and prototyped on FPGA.

## Reading order

1. **[00-overview.md](00-overview.md)** — the centerpiece design doc. Read first.
2. The phase docs, in order (each builds on the last):

| Phase | Doc | Objective | Status |
|------:|-----|-----------|--------|
| 0 | [Scope & stack](phase-0-scope-and-stack.md) | Lock goals, base core, first vertical slice | 🟡 Draft |
| 1 | [ISA spec](phase-1-isa-spec.md) | Define parser registers & instruction semantics | 🟡 Draft |
| 2 | [Reference model](phase-2-reference-model.md) | Golden C model + packet corpus | 🟡 Draft |
| 3 | [Encoding](phase-3-encoding.md) | Allocate `custom-0..3` opcodes & formats | 🟡 Draft |
| 4 | [Microarchitecture](phase-4-microarchitecture.md) | Parser datapath + core integration | 🟡 Draft |
| 5 | [RTL](phase-5-rtl.md) | SystemVerilog implementation | 🟡 Draft |
| 6 | [Verification](phase-6-verification.md) | Co-sim RTL vs golden model | 🟡 Draft |
| 7 | [Toolchain](phase-7-toolchain.md) | Assembler → LLVM/GCC → Spike/QEMU | 🟡 Draft |
| 8 | [FPGA](phase-8-fpga.md) | Prototype & bring-up on hardware | 🟡 Draft |
| 9 | [Benchmark](phase-9-benchmark.md) | flow_dissector comparison | 🟡 Draft |

Status legend: 🟡 Draft · 🟢 Ready · 🔵 In progress · ✅ Done.

## Supporting docs

- **[glossary.md](glossary.md)** — terms (parse graph, cursor, TLV, CAM, custom0-3, IPC, XDP2/PANDA…).
- **[references.md](references.md)** — external links (blog, patent, RISC-V spec, CVA6/Ibex, flow_dissector, tooling).

## Conventions

- **Format:** Markdown with ASCII block diagrams — portable and diff-friendly.
  (Mermaid is fine where a renderer is available, but keep an ASCII fallback.)
- **Per-phase template:** every phase doc follows the same skeleton —
  *Objective · Inputs/prereqs · Design detail · Step-by-step tasks · Deliverables ·
  Exit criteria · Open questions · References.*
- **Honesty markers:** unresolved specifics are tagged **TBD** or **Decision**.
- **Layer discipline:** ISA semantics, microarchitecture, and RTL are kept
  strictly separate. The ISA spec (Phase 1) never encodes cycle counts.
