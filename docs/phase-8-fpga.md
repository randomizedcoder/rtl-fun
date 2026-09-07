# Phase 8 — FPGA prototype

← [Phase 7](phase-7-toolchain.md) · [Docs index](README.md) · [Phase 9 »](phase-9-benchmark.md)

> **This is the plan.** Live progress, measurements and the challenge log are in
> **[phase-8-status.md](phase-8-status.md)**; the board's pin map, gotchas and
> tooling are in
> **[fpga-bringup-tang-mega-138k-pro.md](fpga-bringup-tang-mega-138k-pro.md)**.

## Objective

Get CVA6-plus-parser onto real silicon-adjacent hardware and parse **real
Ethernet traffic**, so the benchmark ([Phase 9](phase-9-benchmark.md)) measures
cycles/packet on an actual pipeline rather than in a simulator.

## Inputs / prerequisites

- Phase 5 RTL, lint-clean and passing Phase 6 co-sim.
- Phase 7 toolchain (a runnable slice-parser binary).
- An FPGA board — **Sipeed Tang Mega 138K Pro** (decided; see 8.1).

## Design detail

### 8.1 Target platform (Decision)

**Decided: the Sipeed Tang Mega 138K Pro** (Gowin `GW5AST-LV138FPG676AC1/I0`,
1 GB DDR3, 2× SFP+). Selected in
[fpga-platform-assessment.md](fpga-platform-assessment.md); the board arrived and
was powered up on **2026-09-07**.

> **Start here for anything hands-on:**
> **[fpga-bringup-tang-mega-138k-pro.md](fpga-bringup-tang-mega-138k-pro.md)** —
> the standing reference for how to use this board: pin map, the two USB ports,
> the programming ladder (`nix run .#fpga-{detect,load,flash,build}`), the Gowin
> gotchas, and a live record of what does and does not work.

The assessment's verdict stands: this is the **endgame** board (best I/O for the
10 GbE target), not the low-risk prototyping board — the cost is integration
effort, chiefly mapping CVA6's SRAM macros onto Gowin BSRAM. A documented Xilinx
fallback (Alinx AX7325B / Genesys 2) remains if that proves intractable.

The older, pre-purchase experiment ladder is in
[tang-mega-138k-pro-rtl-fun-plan.md](tang-mega-138k-pro-rtl-fun-plan.md): a NixOS
toolchain (open-source yosys / nextpnr-gowin / apicula where possible, Gowin EDA for
hard IP), the go/no-go feasibility questions (does CVA6 synthesize/fit/route on Gowin),
and a staged experiment ladder (smoke → LED → CVA6 baseline → BRAM packet window → one
custom instruction end-to-end → counters → baseline-vs-custom benchmark → DDR3 → 10GbE).
The **pre-purchase feasibility gate** — does the Education/NODELOCK Gowin license actually
permit synth+PnR for `GW5AST-LV138FPG676A`? — is automated in a reproducible microVM:
[gowin-microvm.md](gowin-microvm.md) (`nix run .#gowin-vm`). See also the platform
comparison in [fpga-platform-assessment.md](fpga-platform-assessment.md).

### 8.2 Block design

```
                         FPGA
 ┌──────────────────────────────────────────────────────┐
 │                                                       │
 │   CVA6 core ──┬── ALU/MUL/LSU                         │
 │               └── PARSER UNIT ──┐                     │
 │                                 │                     │
 │                         packet BRAM / buffer          │
 │                                 ▲                     │
 │                                 │  (fill path)        │
 │                          Ethernet MAC ── RX FIFO      │
 │                                 │                     │
 └─────────────────────────────────┼─────────────────────┘
                                   │
                             PHY ── RJ45 / SFP ── traffic source
```

- **RX path:** MAC → RX FIFO → packet buffer (the Phase-4 window). A simple DMA/
  fill engine moves a frame into the buffer and hands the core `pktbase/pktlen`.
- **Core:** runs the Phase-7 slice parser, writes `flow_keys` to memory.
- **Readout:** cycle counters + results over UART/JTAG or to a memory-mapped log.

### 8.3 Memory / interconnect

- AXI (or CVA6's native) interconnect between core, packet buffer, and DDR.
- Decide packet buffer width (128/256-bit) per Phase 4; this is where the
  bandwidth thesis (Risk R1) gets tested on real hardware.

### 8.4 Incremental plan

The ordering principle: **each milestone should fail for exactly one reason.**
Cheap milestones that de-risk our own RTL come before the expensive one that
depends on CVA6 fitting, so a failure is always attributable.

| M | Milestone | Proves | Main risk |
|---|---|---|---|
| **M0** | **Board bring-up** — program, LEDs, UART | ✅ **Done** 2026-09-07 | — |
| **M1** | **Parser unit alone on the FPGA**, packet from on-chip ROM, `flow_keys` out over UART | ✅ **Done** 2026-09-07 — on-board `flow_keys` == model | (Gowin SV front end — worked around via yosys, [status #13](phase-8-status.md)) |
| **M2** | **Host → FPGA packet injection**, run the 22-case suite / corpus | The Phase-6 oracle works over a wire | No known UART RX pin |
| **M3** | **Stock CVA6 on the FPGA**, boots, prints from software | The host core fits and runs | **BRAM inference** — the big one |
| **M4** | **CVA6 + parser unit**, runs the Phase-7 slice from on-chip memory | The actual thesis, in hardware | Timing on the FU (G14) |
| **M5** | **Cycle counters** → cycles/packet | The headline metric | — |
| **M6** | **Ethernet**: SFP+ loopback, then one link to hp5 | A real datapath | 10G PCS + MS5351 refclk |
| **M7** | **The demo**: hp5 → Tang → hp5 with a parse-driven transformation | End to end | Checksums |
| **M8** | **Phase 9 benchmark** vs `flow_dissector` | The project's claim | — |

**M1 is ✅ done** (2026-09-07). It is deliberately small: no CPU, no MAC, no DDR. It
instantiates the existing parser datapath (`tb/parser_top.sv`, a hardware `pm_run`),
feeds it one eth/ipv4/tcp packet baked into on-chip ROM, and streams the resulting
`flow_keys` over the M0 UART — which the host (`nix run .#fpga-m1-check`) diffs against
`libparsermodel`. On the board it matched **byte-for-byte** (48 bytes + exit code), so
our RTL is proven on silicon. **2751 LUT / 688 FF / 0 latches**, ~2% of the device. The
full build path and challenge story are in [phase-8-status.md](phase-8-status.md).

> **M1's gating question — can Gowin synthesize our RTL? Answered: not directly, but
> yes via yosys.** GowinSynthesis V1.9.12.03 floods `ERROR (SP00018) ... error bus name
> set` on our parser logic in **every** form tried — SystemVerilog (`set_option
> -verilog_std sysv2017` + `add_file` without `-type`), sv2v-flattened plain Verilog,
> and even `parser_execute` alone. It is a Gowin front-end bug, not a SystemVerilog-
> surface problem (reproduce: `nix run .#fpga-build -- sv-probe`). The route that works
> is **sv2v → yosys `flatten` → GowinSynthesis** (`nix run .#fpga-m1-rtl`), the repo's
> `flat_synth.v` technique. Caveat for **M3**: a full yosys flatten is exactly what
> defeats BSRAM inference at CVA6 scale ([§5a](fpga-platform-assessment.md)), so M3 will
> want a *hierarchical* yosys pass, or a fix/upgrade of the Gowin front end.
>
> The same push resolved the old latch note (`EX2420` on `src[63]` etc.): they were
> false latches from undefaulted `always_comb` temporaries; defaulting them cleared
> every parser latch warning without changing behaviour (Verilator/formal stay green).

**M2 is blocked on a return path.** `uart_tx` is P15; no vendor example we have
drives an RX pin, so the link is transmit-only today. Either find RX in the board
schematic, or inject over JTAG instead (openFPGALoader only programs, so that
means OpenOCD or a user-JTAG register). Until then M1 can still run from a
ROM-baked packet.

**M3 is the expensive one** and the only milestone likely to force a fallback: if
CVA6 cannot be made to fit with BSRAM properly inferred, the documented options are
a smaller CVA6 config, **Ibex** (Phase 0's fallback — the parser unit is
width-parameterized), or the Xilinx board in
[fpga-platform-assessment.md](fpga-platform-assessment.md). Nothing in M1/M2/M6
depends on M3, so it can be attacked in parallel rather than blocking everything.

**M6 is independent of M3/M4** and could proceed in parallel — Sipeed ships a
verified `sfp+` example to start from. Sequencing within it, and the demo options
for M7, are in
[fpga-bringup-tang-mega-138k-pro.md](fpga-bringup-tang-mega-138k-pro.md#demo-and-test-options-sketch).

### 8.5 Instrumentation

- Hardware cycle counter around the parse routine (start at node entry, stop at
  parse-exit) → **cycles/packet**, the headline metric.
- Optional: instruction-retire counters to compute IPC on-chip.
- Capture timing/area/utilization reports from the vendor flow (feeds Phase 9 and
  the "manufacturer-appropriate" story).

## Step-by-step tasks

1. Choose the board (8.1); import its RISC-V + Ethernet reference design.
2. Integrate `cva6_parser_wrap` into the SoC; build stock-CVA6 baseline first.
3. Implement the MAC→buffer fill path and the `pktbase/pktlen` handoff.
4. Bring up in the order of 8.4 (mem-only → loopback → live).
5. Add cycle/IPC counters and a results readout path.
6. Collect timing/area/utilization reports.

## Deliverables / artifacts

- A bitstream for CVA6 + parser unit + MAC + packet buffer.
- On-board demo parsing live Ethernet into `flow_keys`.
- Cycle/IPC counters and vendor timing/area reports.

## Exit criteria

- Real Ethernet frames are parsed on-board, results match the model.
- Per-packet cycle counts are measurable and logged.
- Timing closes at a documented clock; utilization recorded.

## Open questions

- **Decided:** board (8.1). **TBD:** MAC IP selection.
- **Decision:** packet-buffer fill — simple DMA vs. streaming into a wide window.
- If CVA6 is too large for the chosen board, fall back to **Ibex** (Phase 0) —
  the width-parameterized parser unit should drop in.

## References

CVA6 FPGA targets; board/MAC reference designs (TBD). See [references.md](references.md).
