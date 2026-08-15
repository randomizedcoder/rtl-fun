# Phase 0 — Scope & stack

← [Overview](00-overview.md) · [Docs index](README.md) · [Phase 1 »](phase-1-isa-spec.md)

## Objective

Lock the things everything else depends on: **what** we're building first (the
vertical slice), **which base core** we extend, and **what tooling** we stand up.
Exit this phase with no ambiguity about scope or stack.

## Inputs / prerequisites

- The [overview](00-overview.md) (problem framing, three-layer discipline, ADR-001).
- The blog + patent (see [references](references.md)) as the concept source.
- A Linux dev box with disk/CPU for RTL sim and (later) FPGA tools.

## Design detail

### 0.1 The first vertical slice

We commit to **one** end-to-end path — deep enough to be real, narrow enough to
finish:

```
Ethernet ─┬─ 802.1Q VLAN (stackable) ─┐
          ▼◄──────────────────────────┘
   IPv4  ── (IHL-based length, version check)
   IPv6  ── (fixed 40B + extension-header chain)
          ▼
   TCP / UDP  (ports)
          ▼
   struct flow_keys
```

Output struct (illustrative):

```c
struct flow_keys {
    uint8_t  ip_version;   /* 4 or 6            */
    uint8_t  ip_proto;     /* TCP=6, UDP=17     */
    uint16_t sport, dport;
    union { uint32_t v4; uint8_t v6[16]; } src, dst;
    uint16_t vlan_id;      /* outermost, if any */
};
```

This mirrors Linux `flow_dissector`, giving a meaningful, well-understood
benchmark target.

### 0.2 Base-core selection (confirm ADR-001)

| Criterion | **CVA6** ✅ | Ibex | VexRiscv | Rocket+RoCC |
|-----------|------------|------|----------|-------------|
| HDL | SystemVerilog | SystemVerilog | SpinalHDL | Chisel |
| ISA width | RV64GC | RV32IMC | RV32/64 | RV64 |
| Pipeline | 6-stage in-order | 2-stage | configurable | in-order + RoCC |
| Silicon proof | taped out | OpenTitan | FPGA-proven | taped out |
| EDA / tape-out fit | **strong** | strong | weaker | weaker |
| Custom-instr integration | in-pipeline exec unit | in-pipeline | plugin (easiest) | RoCC (loosely-coupled) |
| Fit for 64-bit keys | **native** | awkward | ok | native |

**Decision:** CVA6. It matches the deciding axis — *appropriate for likely chip
manufacturers* (SystemVerilog + commercial EDA), gives RV64 registers for 64-bit
packet fields, and is real silicon. Ibex stays documented as the fallback if
CVA6's size becomes an obstacle for early FPGA bring-up.

### 0.3 ADR-002 — Parser-unit HDL (language choice)

**Status:** Accepted (recommendation). Consistent with [ADR-001](00-overview.md#5-key-architectural-decision-adr-001-systemverilog--cva6);
revisit only if team HDL expertise strongly favors SpinalHDL/Bluespec.

**Context.** CVA6 is written in **SystemVerilog**, and the patent's parser
instructions are a **tightly-coupled** execution unit: they intermix freely with
integer instructions, share the PC and register-file plumbing, and redirect fetch
at end-of-node. The hardest, most iterative work is therefore *inside* CVA6
(decode → issue → EX functional unit → fetch redirect → hazards). That property —
not a stylistic preference — drives the choice: a same-language seam removes an
entire class of integration/debug pain, and loosely-coupled/generated-Verilog
approaches hurt most exactly there.

**Options considered.** (★ = better; ✦ = too new to judge)

| Option | What it is | Tape-out / EDA fit | Tight CVA6 integration | Productivity (control+datapath) | Verilator+cocotb | Talent / ecosystem | Risk |
|--------|------------|--------------------|------------------------|---------------------------------|------------------|--------------------|------|
| **SystemVerilog** ✅ | Same language as CVA6 | ★★★ native | ★★★ no language boundary | ★★ verbose (mitigated by codegen) | ★★★ | ★★★ huge | ★ lowest |
| **SpinalHDL** | Scala HDL → clean, readable Verilog | ★★ (DV/PD sign off on generated RTL) | ★★ generated block + SV wrapper | ★★★ excellent generators/plugins | ★★★ | ★ small | ★★ |
| **Bluespec (BSV)** | Rule/atomic-transaction HDL | ★★ generated | ★★ | ★★★ *best semantic fit for parsing FSMs* | ★★ | ★ niche | ★★★ |
| **Chisel (Rocket)** | Scala HDL → Verilog | ★★ noisier output | ★ natural path is RoCC = **loosely coupled** | ★★★ | ★★★ | ★★ | ★★ |
| **Amaranth** | Python HDL → Verilog | ★ weakest tape-out track record | ★★ | ★★★ | ★★★ | ★ | ★★★ |
| **Veryl** | Modern lang → 1:1 SystemVerilog | ★★★ (output *is* SV) | ★★★ | ★★ | ★★★ | ✦ brand-new | ★★★ |

**Pros / cons that decide it:**
- **SystemVerilog** — *pro:* zero language boundary with CVA6; every ASIC flow
  (Synopsys/Cadence lint, CDC, DFT, synthesis) is SV-first; largest talent pool;
  Verilator+cocotb work directly. *con:* verbose, classic footguns (latches,
  X-prop) — largely removed by **generating the decode/encode tables from the ISA
  table** ([`analysis/patent-encodings-recovered.md`](analysis/patent-encodings-recovered.md)).
- **SpinalHDL** — *pro:* lovely parameterization/plugin model, emits readable
  Verilog, VexRiscv proves tight custom-instruction integration. *con:* Scala +
  small community; a DV/PD team still signs off on generated Verilog and debugs
  across a language boundary at the CVA6 seam.
- **Bluespec** — *pro:* rule-based atomics model parse-node/loop/end-of-node
  control elegantly; strong typing; real silicon history. *con:* niche, steep
  curve, hard to hire for — a large bet for a first effort.
- **Chisel** — *pro:* powerful generators, Rocket ecosystem. *con:* its natural
  integration is **RoCC (loosely coupled)** — the wrong shape for intermixed,
  in-pipeline parser instructions; noisier generated Verilog; heavy build.
- **Amaranth / Veryl** — productive/modern; Amaranth has the weakest tape-out
  record, and Veryl (transpiles 1:1 to SV — appealing long-term) is too new to bet
  a first silicon effort on.

**Decision.** Write the parser unit in **SystemVerilog**, with **code-generation
from the ISA table** (a script emitting SV packages for the `Fnc4` decode, field
extraction, and the register/`Sz`/parser-code constants). Rationale:
1. **The ISA is tightly coupled** — a same-language seam with CVA6 is worth more
   than any higher-level HDL's productivity, because the integration edits live
   inside CVA6.
2. **It is the stated deciding axis** — "appropriate for likely chip manufacturers"
   = SystemVerilog + commercial EDA; generated Verilog is a sign-off friction point.
3. **We keep the generator upside anyway** — the parameterization that makes
   Chisel/SpinalHDL attractive is mostly the decode/encode tables, which we
   generate into SV from the machine-readable ISA table.

**Flip condition.** If the team already has **deep SpinalHDL or Bluespec** expertise
and explicitly prioritizes design-velocity over first-pass tape-out-readiness,
**SpinalHDL** is the strongest alternative (readable output, proven tight
custom-instruction integration in VexRiscv).

### 0.4 Repo layout (target, created as phases land)

```
docs/                 design docs (this set)
model/                golden C reference model  (Phase 2)
isa/                  machine-readable encoding tables (Phase 3)
rtl/                  SystemVerilog parser unit  (Phase 5)
  parser_pkg.sv
  parser_decode.sv
  parser_execute.sv
  parser_*.sv
tb/                   cocotb / Verilator testbench  (Phase 6)
corpus/               packet corpus incl. malformed  (Phase 2)
toolchain/            .insn macros, intrinsics, sim patches  (Phase 7)
fpga/                 board build + block design  (Phase 8)
bench/                benchmark harness + results  (Phase 9)
```

### 0.5 Toolchain prerequisites

All of the below (except the FPGA vendor flow) are provided reproducibly by the
Nix dev shell — `nix develop`. See [nix.md](nix.md) and the pinned versions in
[environment.md](environment.md).

- **Verilator** + **cocotb** (co-sim, Phase 6).
- **RISC-V bare-metal toolchain** (`riscv64-none-elf-gcc`/binutils, newlib) — in
  the shell now; used to compile the CVA6 sim test programs and, later, `.insn`
  parser tests (Phase 7).
- **Spike** and **QEMU** (functional ISA reference, Phase 7). Spike also supplies
  the DPI libraries (`libfesvr`/`libriscv`/`libdisasm`) the CVA6 testharness links.
- **CVA6** base core — pinned via Nix (`nix/cva6.nix`, v5.3.0) and built into a
  Verilator model by [`scripts/cva6-baseline.sh`](../scripts/cva6-baseline.sh).
- (Later) FPGA vendor flow — board **TBD** (Phase 8).

### 0.6 CVA6 Verilator baseline (task 4)

The stock CVA6 core builds to a Verilator simulator with no RTL changes yet — the
baseline we will later extend with the parser unit:

```sh
nix run .#cva6-baseline
# -> build/cva6/work-ver/Variane_testharness   (target: cv64a6_imafdc_sv39, RV64GC)
```

The builder is a Nix `writeShellApplication` (`nix/cva6-baseline.nix`, body in
[`scripts/cva6-baseline.sh`](../scripts/cva6-baseline.sh)) — so its tools come from
`runtimeInputs` and `shellcheck` gates it at build time. It assembles a unified
`$RISCV` prefix from the scattered Nix outputs (toolchain + Spike + yaml-cpp),
copies the read-only pinned source into `build/cva6/`, and runs `make verilate`.
One local patch is applied: CVA6 v5.3.0's root `verilate` target links none of the
DPI elf-loader sources, so the script adds the vendored `fesvr_dpi.cc` (which
defines `read_elf`/`get_section`/`read_section_void`/`read_symbol`).

## Step-by-step tasks

1. Ratify the vertical slice (0.1) and the `flow_keys` struct.
2. Confirm CVA6 vs Ibex with the matrix (0.2); record the decision.
3. Create the repo skeleton (0.3) as empty dirs with `.gitkeep` + READMEs.
4. Install & smoke-test Verilator + cocotb; build the stock CVA6 Verilator sim.
5. Install Spike/QEMU; confirm a hello-world RV64 binary runs.
6. Write down environment versions for reproducibility.

## Deliverables / artifacts

- This scope doc, ratified.
- Repo skeleton committed.
- A one-page "environment & versions" note (tool versions, core commit hash).

## Exit criteria

- Base core chosen with a recorded rationale (matrix above).
- **Parser-unit HDL chosen with a recorded rationale (ADR-002 §0.3).**
- Vertical slice + output struct fixed.
- Verilator/cocotb and Spike/QEMU installed and smoke-tested; stock CVA6 sim runs.

## Open questions

- **Decision:** dedicated packet buffer vs L1D for the packet window? (Deferred to
  Phase 4, but flag it now — it's Risk R1.)
- **TBD:** FPGA board (drives some memory/interface choices in Phase 4/8).
- Ibex fallback: do we keep the parser unit width-agnostic so it can drop into
  either core? (Recommended: yes.)

## References

See [references.md](references.md) — CVA6, Ibex, Verilator, cocotb, Spike/QEMU,
flow_dissector.
