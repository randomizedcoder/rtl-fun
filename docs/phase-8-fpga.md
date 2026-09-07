# Phase 8 — FPGA prototype

← [Phase 7](phase-7-toolchain.md) · [Docs index](README.md) · [Phase 9 »](phase-9-benchmark.md)

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

### 8.4 Bring-up sequence

0. **Board bring-up** (prerequisite, split out of step 1): talk to the board over
   JTAG, program it, and run a self-built blinky — the repeatable
   edit→synth→program→observe loop. See
   [fpga-bringup-tang-mega-138k-pro.md](fpga-bringup-tang-mega-138k-pro.md).
1. Synthesize/P&R stock CVA6 on the board; boot, blink, UART hello.
2. Add the parser unit; run the Phase-6 directed vectors from on-chip memory
   (no MAC yet) and confirm `flow_keys` match the model.
3. Bring up the MAC in loopback; push known frames from a host; confirm parse.
4. Live traffic: parse real frames; log per-packet cycle counts.

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
