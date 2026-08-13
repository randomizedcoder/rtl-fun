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

### 0.3 Repo layout (target, created as phases land)

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

### 0.4 Toolchain prerequisites

- **Verilator** + **cocotb** (co-sim, Phase 6).
- **riscv-gnu-toolchain** or an LLVM RISC-V build (for `.insn`, Phase 7).
- **Spike** and **QEMU** (functional ISA reference, Phase 7).
- CVA6 checkout + its Verilator sim target.
- (Later) FPGA vendor flow — board **TBD** (Phase 8).

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
