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
| 4 | [Microarchitecture](phase-4-microarchitecture.md) | Parser datapath + core integration | ✅ Done |
| 5 | [RTL](phase-5-rtl.md) | SystemVerilog implementation | 🔵 In progress |
| 6 | [Verification](phase-6-verification.md) | Co-sim RTL vs golden model | 🔵 In progress |
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
Phase 4 done — the parser microarchitecture is decided at signal-interface
granularity: a 256 B packet buffer with a 128-bit read window, the extract/length/
compare/CAM/end-of-node datapath and its unit interfaces, a 32×64-bit parser
register file with a single-in-flight hazard interlock, and a CVA6 integration
plan mapped to the **pinned v5.3.0 source** — custom-0 as a new in-pipeline
`fu_t::PARSER` reusing `resolved_branch_o` for end-of-node redirect, custom-3 via
CV-X-IF ([`analysis/cva6-integration.md`](analysis/cva6-integration.md)).
Phase 5 in progress — the parser datapath is implemented in synthesizable
SystemVerilog ([`rtl/`](../rtl/README.md)) as a hardware `pm_run`, and **runs the
vertical slice in Verilator producing a `flow_keys` that matches the golden model
byte-for-byte** (`nix run .#parser-sim`). Lint-clean under `-Wall`, with four
Verilator targets at different debug levels (run / trace / debug / lint). The FU
also runs in-core in CVA6: the decode/issue/EX/retire patch is complete, the
32-bit-word decoder (`parser_decode`) is proven vs the model, and a packet now
parses end-to-end in the pipeline over real MMIO ([`analysis/cva6-integration.md`](analysis/cva6-integration.md) §8).
Phase 6 in progress — the verification *foundation* is in place across all four
techniques, every target green from the flake: (1) **toggleable design assertions**
(`rtl/parser_asserts.svh`) compiled into every sim and vanishing from synthesis;
(2) a **SymbiYosys formal proof** that `parser_execute` never writes metadata
out of bounds and always exits with a valid code, for *all* inputs
(`nix run .#parser-formal`); (3) a **directed suite** of 15 positive / negative /
boundary / corner packets — IPv4/IPv6, VLAN, QinQ, IPv6 ext + fragment, malformed
and truncated frames — each matched byte-for-byte and by exit code against the
model (`nix run .#parser-sim-suite`); and (4) **static analysis + fuzzing** —
verible + svlint on the RTL (`nix run .#parser-analyze`), cppcheck + gcc
`-fanalyzer` + clang-tidy + ASan/UBSan on the model (`nix run .#model-analyze`),
and libFuzzer + ASan/UBSan on random packets (`nix run .#model-fuzz`).
The in-core FU is now hardened through increments **I1–I5**: the full **in-core
packet→flow_keys co-simulation over real MMIO** parses all 22 corpus packets in the
CVA6 pipeline and matches the model byte-for-byte + exit code
(`nix run .#cva6-parser-cosim`, 22/22). A **negative control** now guards the
extension: the *stock* core traps the identical custom-0 word as illegal
(`nix run .#parser-negative-control`, G11). **Next:** the directed V-table
interrupt row (V6; V7 faulting-squash done in N4), base-ISA regression, a 2nd config, and coverage sign-off.
Deferred slices: 64-bit instruction form; encoders/execution for the array /
counter / TLV-loop groups; TLV *extraction* loops and tunnel protocols.

## Analysis

- **[analysis/cva6-integration.md](analysis/cva6-integration.md)** — the file/signal
  map for attaching the parser unit to CVA6, grounded in the pinned v5.3.0 source:
  custom opcodes, `fu_t::PARSER`, the `resolved_branch_o` end-of-node redirect,
  CV-X-IF for the custom-3 moves, and the Phase-5 patch checklist.
- **[analysis/cva6-test-evaluation.md](analysis/cva6-test-evaluation.md)** — a
  tapeout-oriented risk register for the **in-core** parser test: what
  `cva6-parser-test` actually proves, the bug-class gaps (incl. a speculation/flush
  state-corruption risk), and the industry best practices (lock-step co-sim,
  `riscv-dv`, RVFI/formal) to close them.
- **[analysis/cva6-verification-design.md](analysis/cva6-verification-design.md)** —
  the follow-up *design*: ordered implementation increments that close those gaps
  (starting with the speculation-safety fix), a **table-driven** verification
  framework (positive/negative/boundary/corner, model-generated oracles), and a
  **manufacturing/self-test (DFT)** section — scan/ATPG, MBIST/CAM-BIST for the
  parser memories, JTAG, and a golden-vector power-on self-test (POST).
- **[analysis/cva6-implementation-status.md](analysis/cva6-implementation-status.md)**
  — the **live progress tracker** for executing that design (increments I1–I5, gap
  burn-down G1–G14, verification-target snapshot). Updated per PR. I1
  (speculation-safety, commit-visible parser state), I2 (commit-gated metadata sink),
  I3 (custom-3 register readback), I4 (end-of-node + CAM-hit fetch redirect), and
  **I5** (all op classes + model-generated encodings + the table-driven in-core
  packet→flow_keys cosim over **real MMIO** — which closes the I2 sim-only-backdoor
  escalation) are all done and green in-core.
- **[analysis/cva6-parser-mmio.md](analysis/cva6-parser-mmio.md)** — the I5 SoC AXI
  MMIO parser peripheral: the address map (packet buffer, flow_keys frame, ParseLen /
  exit-PC / status registers), how `sd`/`ld` bridge through `axi2mem` into the FU, the
  gated parse-exit fetch redirect, and the **registered-read** gotcha (`axi2mem`
  advances the beat address combinationally, so a peripheral must present 1-cycle read
  data or every `ld` returns the next word).
- **[analysis/patent-conformance.md](analysis/patent-conformance.md)** — how the
  design compares to US Patent 12,461,885, and the prioritized corrections applied to
  follow Herbert's model closely.
- **[analysis/patent-encodings-recovered.md](analysis/patent-encodings-recovered.md)**
  — the authoritative bit-level reference: `Fnc4` opcode map, every 32-bit
  instruction format as RFC-style ASCII bit diagrams, the Parser Codes table, `Sz`
  tables, address/code + CAM-key formats, and register layouts (pixel-verified from
  the USPTO drawing sheets).

## Supporting docs

- **[testing-overview.md](testing-overview.md)** — **start here for "how is the parser
  tested?"** The one-stop map of the four test layers (golden-model unit/fuzz,
  standalone RTL-vs-model suite, in-core directed, in-core cosim-vs-model + formal),
  which `nix run .#<app>` runs each, where each lives, and how one generator feeds
  both the standalone suite and the cosim.
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
