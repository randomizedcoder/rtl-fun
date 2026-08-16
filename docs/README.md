# Design docs — index

This folder plans the entire project: from Tom Herbert's *parser instructions*
concept to real SystemVerilog RTL for a RISC-V ISA extension, verified against a
golden model and prototyped on FPGA.

## Reading order

1. **[00-overview.md](00-overview.md)** — the centerpiece design doc. Read first.
2. The phase docs, in order (each builds on the last):

| Phase | Doc | Objective | Status |
|------:|-----|-----------|--------|
| 0 | [Scope & stack](phase-0-scope-and-stack.md) | Lock goals, base core, first vertical slice | ✅ Done |
| 1 | [ISA spec](phase-1-isa-spec.md) · [**semantics**](phase-1-isa-semantics.md) | Define parser registers & instruction semantics | ✅ Done |
| 2 | [Reference model](phase-2-reference-model.md) | Golden C model + packet corpus | ✅ Done |
| 3 | [Encoding](phase-3-encoding.md) | Allocate `custom-0..3` opcodes & formats | ✅ Done |
| 4 | [Microarchitecture](phase-4-microarchitecture.md) | Parser datapath + core integration | 🟡 Draft |
| 5 | [RTL](phase-5-rtl.md) | SystemVerilog implementation | 🟡 Draft |
| 6 | [Verification](phase-6-verification.md) | Co-sim RTL vs golden model | 🟡 Draft |
| 7 | [Toolchain](phase-7-toolchain.md) | Assembler → LLVM/GCC → Spike/QEMU | 🟡 Draft |
| 8 | [FPGA](phase-8-fpga.md) | Prototype & bring-up on hardware | 🟡 Draft |
| 9 | [Benchmark](phase-9-benchmark.md) | flow_dissector comparison | 🟡 Draft |

Status legend (tracks phase **execution**, not just the doc):
🟡 Draft (design written, not yet executed) · 🔵 In progress (being executed) ·
✅ Done (executed & merged to `main`).

**Progress:** Phase 0 done — CVA6 Verilator baseline builds from Nix
(`nix run .#cva6-baseline`) with the RISC-V cross-toolchain and a reproducibility
snapshot ([environment.md](environment.md)). Phase 1 done — the normative
[per-instruction semantics](phase-1-isa-semantics.md) are complete and patent-cited.
Phase 2 done — the golden C model (`model/libparsermodel`) parses Ethernet,
802.1Q/802.1ad VLAN (incl. stacked), IPv4 (with options), IPv6 (with hop-by-hop /
routing / fragment / dest-opts extension headers), TCP and UDP into a `flow_keys`.
It passes directed unit tests, hostile/malformed cases (§2.3), and a robustness
sweep over the pinned xdp2 `proto_audit` corpus — all 306 Ethernet pcaps
terminate cleanly, no crashes/hangs (`nix run .#model-test`). A single-step
tracer lives in [tools/pm-trace](../tools/README.md).
Phase 3 done — the bit-accurate encoding is captured as a machine-readable table
([`isa/parser-opcodes.yaml`](../isa/parser-opcodes.yaml)), with a C encoder/decoder
wired into the model ([`encoding.c`](../model/libparsermodel/encoding.c)) and
`.insn` emitters ([`toolchain/parser_insn.h`](../toolchain/parser_insn.h)). Every
instruction in the slice program encodes to its exact custom-0 word and decodes
back (round-trip + golden-vector tests in `nix run .#model-test`).
**Next:** Phase 4 (parser microarchitecture + CVA6 integration point).
Deferred slices: 64-bit instruction form; encoders/execution for the array /
counter / TLV-loop groups; TLV *extraction* loops and tunnel protocols.

## Analysis

- **[analysis/patent-conformance.md](analysis/patent-conformance.md)** — how the
  design compares to US Patent 12,461,885, and the prioritized corrections applied to
  follow Herbert's model closely.
- **[analysis/patent-encodings-recovered.md](analysis/patent-encodings-recovered.md)**
  — the authoritative bit-level reference: `Fnc4` opcode map, every 32-bit
  instruction format as RFC-style ASCII bit diagrams, the Parser Codes table, `Sz`
  tables, address/code + CAM-key formats, and register layouts (pixel-verified from
  the USPTO drawing sheets).

## Supporting docs

- **[nix.md](nix.md)** — the Nix dev environment (`nix develop`), its layout, and how to extend it.
- **[environment.md](environment.md)** — pinned tool versions (the Phase 0 reproducibility snapshot).
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
