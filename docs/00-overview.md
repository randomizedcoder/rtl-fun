# Overview — Parser instructions for RISC-V

> The whole-project design doc. Read this first, then the phase docs in order.

---

## 1. Problem & motivation

Protocol parsing is the act of walking a **parse graph**: a packet is a chain of
headers (Ethernet → VLAN → IPv4 → TCP → …), and parsing visits one **parse node**
per header. Each node does two essential things:

1. **Header length** — how many bytes is *this* header? (fixed, or computed from a
   length field, or discovered via TLVs).
2. **Next protocol** — what header comes next? (looked up from an EtherType, IP
   protocol number, port, etc.).

Everything else (extracting metadata into a flow key, bounds-checking against the
end of the packet, handling optional fields) hangs off those two operations.

There are two conventional ways to do this, and both are unsatisfying:

- **Fixed-function hardware parsers** are fast but rigid. A new protocol or a
  tweak to an existing one can mean a respin or a config language with sharp
  limits.
- **Software parsing on a general CPU** is fully flexible but slow: each field is
  a `load; shift; mask; compare; branch`, and the work is dominated by memory
  access and branch overhead.

**Parser instructions** collapse that tension. They are domain-specific CPU
instructions — like vector instructions are for arithmetic — that implement the
parse-node flow chart directly in backend hardware logic, while remaining part of
a **Turing-complete, fully programmable** RISC-V core. You get hardware-speed
primitives you can freely intermix with ordinary integer instructions, reusing
existing assemblers, compilers, debuggers, and operational tooling.

Per the source blog, each parser instruction replaces ~5–300 integer instructions
(≈15:1 for typical Internet protocols), and although parser-instruction IPC is
lower (~0.4 vs ~1.4 for integer parsing on x86), the net throughput speedup is
~4.3× — with headroom to grow as pipeline IPC improves.

## 2. Goals & non-goals

**Goals**
- A precise **ISA specification** following **US Patent 12,461,885** — the full
  register file, two-level parsing model, and end-of-node semantics — using the
  blog's worked example as the on-ramp. (The docs were first drafted from the blog;
  see [`analysis/patent-conformance.md`](analysis/patent-conformance.md) for the gap
  analysis that expanded them to the patent's actual ISA.)
- A **golden software model** that defines the architecture independent of any
  implementation.
- A synthesizable **SystemVerilog** implementation integrated into a real,
  silicon-proven open core.
- **Co-simulation** proving RTL == golden model over a large corpus including
  malformed packets.
- An **FPGA prototype** that parses real Ethernet traffic, and a **benchmark**
  against plain RV64 code and a Linux `flow_dissector`-style baseline.

**Non-goals (for the first iteration)**
- Not a full offload NIC or a general-purpose packet-processing datapath.
- Not out-of-order / speculative integration (start in-order — far fewer
  rename/replay/retirement questions).
- Not a frozen, ratified extension — this is a research ISA we expect to revise.

**First vertical slice** (the concrete target the whole doc set optimizes for):

```
Ethernet ─┬─ VLAN ─┐
          │        │   (VLAN may stack)
          ▼◄───────┘
   IPv4 / IPv6 ── (IPv6 extension headers)
          ▼
   TCP / UDP
          ▼
   struct flow_keys { ip_version, ip_proto, src, dst, sport, dport, ... }
```

This lines up with the Linux `flow_dissector` problem and gives a tightly
constrained, meaningful benchmark.

## 3. Architecture at a glance

```
                         packet buffer / L1D or dedicated packet cache
                                        │  128 / 256-bit window
                                        ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  RISC-V core (CVA6, in-order, RV64)                           │
   │                                                              │
   │   IF ─► ID ─► ISSUE ─► EX ─────────────────────────► WB     │
   │                          │                                   │
   │                          ├─ ALU                              │
   │                          ├─ MUL/DIV                          │
   │                          ├─ LSU  ◄──── ordinary loads/stores │
   │                          └─ PARSER UNIT  ◄─── custom0..3     │
   │                               │  extract / bounds / length   │
   │                               │  CAM lookup / next-node      │
   │                               ▼                              │
   │   Parser registers:  pcurptr  pcurhdr  paccum  pnext         │
   │                       pktbase  pktlen   (metadata buffer)    │
   └──────────────────────────────────────────────────────────────┘
```

The **parser unit** is a new execution unit behind the `custom-0..3` opcodes. It
owns a small set of **parser registers** (the "cursor" state) and has efficient
access to a **wide window of packet bytes**. Whether that window comes from the
normal L1D or a dedicated packet buffer is the single most important
microarchitecture question (see Risk R1).

## 4. The three-layer discipline

We keep three layers strictly separate. Blurring them is the classic way these
projects go wrong.

```
   ISA semantics        ← what each instruction means (golden C model, Phase 1/2)
        │                 must NOT depend on cycle counts
        ▼
   microarchitecture    ← how we implement it: pipeline stages, packet window,
        │                 CAM structure, hazards (Phase 4)
        ▼
   RTL                  ← the actual SystemVerilog (Phase 5)
```

Rule: the ISA spec never says "this takes one cycle." Whether the first
implementation is 1-cycle, 3-cycle, or pipelined is a microarchitecture choice
that must not leak into program-visible semantics.

## 5. Key architectural decision (ADR-001): SystemVerilog + CVA6

**Decision:** implement in **SystemVerilog**, extending the **CVA6** core
(RV64GC, in-order, OpenHW Group). **Ibex** (RV32, lowRISC/OpenTitan) is the
documented lighter fallback. The base-core commitment is re-confirmed in Phase 0
with an explicit matrix.

**Deciding axis — "appropriate for the likely chip manufacturers."** A NIC/DPU
silicon vendor taping this out lives in a SystemVerilog + commercial-EDA world
(Synopsys/Cadence lint, CDC, synthesis, DFT). That dominates the choice.

| Option | HDL | Pros | Cons |
|--------|-----|------|------|
| **CVA6 + SV** ✅ | SystemVerilog | Industry-standard flow, RV64 (64-bit fields), taped-out silicon, EDA-friendly | Verbose; manual decode/exec wiring |
| Ibex + SV | SystemVerilog | Tiny, in-order, real silicon (OpenTitan), simplest integration | RV32 (32-bit regs awkward for 64-bit keys) |
| VexRiscv + SpinalHDL | Scala | Plugin model is *ideal* for a new exec unit | Scala/SpinalHDL curve; less standard for tape-out |
| Rocket + Chisel (RoCC) | Scala | RoCC purpose-built for custom0-3 accelerators | Heavy build; RoCC is loosely-coupled, not tight ISA integration |

Rationale detail lives in [Phase 0](phase-0-scope-and-stack.md). RV64 is chosen
because packet keys (IPv6 addresses, 64-bit accumulators) fit registers cleanly.

## 6. Phase roadmap

| # | Phase | Objective | Primary deliverable | Exit criteria |
|--:|-------|-----------|---------------------|---------------|
| 0 | [Scope & stack](phase-0-scope-and-stack.md) | Lock goals, base core, first slice | Scope doc + core decision | Core chosen w/ matrix; slice defined; toolchain installs |
| 1 | [ISA spec](phase-1-isa-spec.md) | Define registers + instruction semantics | ISA spec | Every instruction has unambiguous semantics + worked example |
| 2 | [Reference model](phase-2-reference-model.md) | Golden C model + corpus | `libparsermodel` + corpus | Model parses corpus incl. malformed inputs; is the source of truth |
| 3 | [Encoding](phase-3-encoding.md) | Allocate opcodes & formats | Encoding table | Every instr has a bit-accurate encoding + `.insn` mapping |
| 4 | [Microarch](phase-4-microarchitecture.md) | Datapath + integration design | Microarch doc | Datapath, packet-window source, CVA6 hook points decided |
| 5 | [RTL](phase-5-rtl.md) | SystemVerilog implementation | `parser_*` SV modules | Lints clean; runs the slice in sim |
| 6 | [Verification](phase-6-verification.md) | Co-sim vs golden model | cocotb testbench + CI | RTL == model over full corpus; coverage target met |
| 7 | [Toolchain](phase-7-toolchain.md) | Assembler → compiler → sims | Intrinsics + binutils/LLVM/Spike/QEMU | Parser written in C compiles & runs on Spike/QEMU |
| 8 | [FPGA](phase-8-fpga.md) | Hardware prototype | Bitstream + bring-up | Real Ethernet frames parsed on-board |
| 9 | [Benchmark](phase-9-benchmark.md) | Measure the win | Results report | cycles/packet vs RV64 & flow_dissector baseline |

Phases are mostly sequential, but 2 (model) and 3 (encoding) can proceed in
parallel once 1 is stable, and 7 (toolchain) can start as soon as 3 is fixed.

## 7. Risk register

| ID | Risk | Impact | Mitigation |
|----|------|--------|------------|
| **R1** | **Packet-memory bandwidth dominates.** If every parser instr does an ordinary CPU load, you cut instruction count but stay memory-bound. | The advertised speedup evaporates. | Design a wide (128/256-bit) packet window feeding the parser unit; measure cycles/packet with and without it (Phase 4/9). This is *the* make-or-break decision. |
| **R2** | Parser register state is **large** — the patent defines 32 × 64-bit `p`-regs (operational + config + target), so context-switch / ABI / debugger cost is real, not hypothetical. | Adoption pain. | Minimize *in-use* state for the first slice (single encap level, no runthread); specify save/restore (CSR or shadow block) in Phase 1/4. |
| **R3** | Opcode budget: only `custom-0..3` available. | Run out of encoding space. | Use funct3/funct7 sub-encoding; keep the instruction set small & Herbert-shaped (Phase 3). |
| **R4** | Malformed / adversarial packets cause wrong parses or hangs. | Security + correctness. | Bounds checks are first-class in the ISA; the corpus is malformed-input-heavy; fuzz RTL vs model (Phase 2/6). |
| **R5** | ISA/microarch bleed together and freeze bad decisions. | Rework. | Enforce the three-layer discipline (§4); the C model is the only semantic authority. |
| **R6** | Wrong instruction granularity (too small = no win; too big = fixed-function). | Misses the point of the project. | Mirror the blog's medium-grained set; revisit only with benchmark data (Phase 1/9). |

## 8. Success metrics

- **Primary:** cycles per packet for the first vertical slice, three ways —
  (a) idiomatic RV64 C, (b) hand-optimized RV64, (c) parser instructions — plus a
  Linux `flow_dissector`-style baseline for context.
- **Secondary:** static instruction count per parsed header (reference target
  ≈15:1 vs integer code), measured IPC, and area/timing of the parser unit on
  FPGA.
- **Correctness gate (non-negotiable):** RTL output is bit-identical to the golden
  C model across the entire corpus, including every malformed case.

## 9. Glossary & references

See [glossary.md](glossary.md) and [references.md](references.md).

---

Next: **[Phase 0 — Scope & stack »](phase-0-scope-and-stack.md)**
