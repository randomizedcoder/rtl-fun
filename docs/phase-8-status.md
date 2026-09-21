# Phase 8 — status and challenge log

← [Phase 8 plan](phase-8-fpga.md) · [Board manual](fpga-bringup-tang-mega-138k-pro.md) · [Docs index](README.md)

**The live progress tracker for Phase 8.** Same role as
[analysis/cva6-implementation-status.md](analysis/cva6-implementation-status.md)
plays for the in-core work: the plan lives in
[phase-8-fpga.md](phase-8-fpga.md), the durable board reference lives in
[fpga-bringup-tang-mega-138k-pro.md](fpga-bringup-tang-mega-138k-pro.md), and
everything that *changes as we execute* lives here.

Which document does a new fact belong in?

| Kind of fact | Goes in |
|---|---|
| What we intend to build, and in what order | [phase-8-fpga.md](phase-8-fpga.md) |
| A durable truth about the board or the tools ("LEDs are active low", "`--detect -f` erases SRAM") | [fpga-bringup-tang-mega-138k-pro.md](fpga-bringup-tang-mega-138k-pro.md) |
| A dated event, a measurement, or a problem we hit and solved | **here** |

Keep this file append-mostly. When a challenge yields a durable rule, write the
rule into the board manual and leave the *story* here.

## Milestones

Plan and per-milestone risks: [phase-8-fpga.md §8.4](phase-8-fpga.md#84-incremental-plan).

| M | Milestone | Status |
|---|---|---|
| **M0** | Board bring-up — program, LEDs, UART | ✅ **Done** 2026-09-07 |
| **M1** | Parser unit alone on the FPGA | ✅ **Done** 2026-09-07 — `flow_keys` from ROM-baked packet == `libparsermodel` on the board (see [M1 log](#m1--parser-unit-alone-done)) |
| **M2** | Host → FPGA packet injection | ✅ **Done** 2026-09-07 — all 22 suite cases injected over UART parse on-board, `flow_keys` + code == `libparsermodel` (see [M2 log](#m2--host-packet-injection-done)) |
| **M3** | Stock CVA6 on the FPGA | ⛔ **M3a gate: does not fit the GW5AST-138** (2026-09-11) — RV64GC CVA6 is ~4.7× over on LUTs; BSRAM inference solved and the crash fixed, but LUT area is the wall. **Fallback triggered: move the host core to a Xilinx Kintex-7 board** (see [M3a fit verdict](#m3a--fit-verdict-cva6-does-not-fit-the-gw5ast-138--pivot-to-xilinx)) |
| **M4** | CVA6 + parser unit | ⏳ Not started |
| **M5** | Cycle counters → cycles/packet | ⏳ Not started |
| **M6** | Ethernet: loopback, then hp5 | ⏳ Not started (independent of M3/M4) |
| **M7** | The demo: transformation end to end | ⏳ Not started |
| **M8** | Phase 9 benchmark | ⏳ Not started |

## M0 — board bring-up (done)
Updated as the ladder is executed. **Verified** = actually run and observed here,
with the evidence in the Notes column. Note that step 4 is verified as a *toolchain*
result (real bitstream, real reports); nothing has yet been observed on the board
itself, because every on-board step is gated behind step 0.

| # | Step | Status | Notes |
|---|---|---|---|
| 0 | Host access (`dialout` + `plugdev` + udev) | ✅ **Verified** 2026-09-07 | `nixos-rebuild switch` + `udevadm trigger`; USB node became `root plugdev 0660`. See [gotchas](#the-two-steps-nobody-remembers) |
| 1 | `.#fpga-detect` — IDCODE | ✅ **Verified** 2026-09-07 | `idcode 0x1081b`, Gowin / GW5AST / GW5AST-138, irlength 8, JTAG @ 6.00 MHz |
| 2 | Vendor bitstream → SRAM | ⚠️ Programmed, not visually confirmed | Sipeed `led.fs` loaded 100% / `DONE`, so the *path* works — but no one watched the LEDs, and the board's factory image is easily mistaken for a demo. Re-do the visual check if it ever matters |
| 3 | Vendor bitstream → SPI flash | ⏳ Not yet run | |
| 4 | Our blinky: Gowin build | ✅ **Verified** 2026-09-07 | `BUILD RESULT: OK`. `nix run .#fpga-build` → `build/fpga-blinky/impl/pnr/blinky_top.fs`. See [build results](#first-build-results) |
| 5 | Our blinky: on hardware | ✅ **Verified** 2026-09-07 | Unison blink confirmed flashing by eye — **our RTL runs on the FPGA** |
| 6 | Edit → rebuild → reload round trip | ✅ **Verified** 2026-09-07 | `TICK_DIV` 25M→6.25M rebuilt + reloaded (`0x6957`), then the 6-pattern sequencer (`0x94D9`, 108 logic / 48 FF, TNS 0.000). Loop closed |
| 7 | **UART hello world** | ✅ **Verified** 2026-09-07 | `hello_top` (197 logic / 90 FF, TNS 0.000) emits `rtl-fun uart NNNN` twice a second on P15; read at **115200** on `/dev/ttyUSB1` via `nix run .#fpga-uart`, 100% printable, counter incrementing |

### First build results

`nix run .#fpga-build`, 2026-09-07 — our own Verilog, through Gowin, to a bitstream.

```
//Tool Version: V1.9.12.03 (86714)
//Device: GW5AST-138        //Device Version: B
//Part Number: GW5AST-LV138FPG676AC1/I0
//Device-package: GW5AST-138B-FCPBGA676A
```

| Resource | Used | Available | % |
|---|---|---|---|
| Logic (LUT/ALU/ROM16) | 62 (31 LUT, 31 ALU) | 138,240 | <1% |
| Register (FF) | **39** | 139,140 | <1% |
| I/O bank 3 (`led[5:0]`) | 6 | 50 | 12% |
| I/O bank 4 (`clk`) | 1 | 50 | 2% |
| PRIMARY global clock | 1 | 8 | 13% |
| GCLK_PIN | 1 | 24 | 5% |

Those numbers are for the v1 walker (32-bit `tick_cnt` + 6-bit `dot` + 1-bit `dir`
= 39 FF). The shipped **6-pattern sequencer builds to 108 logic / 48 registers**,
TNS 0.000 on setup and hold; the v3 unison blink was 45 / 33 and the v2 alternate
walker 59 / 36.

**Use the resource delta as a free sanity check.** When a visual is ambiguous, the
utilization report still tells you whether the bitstream on the board is the one
you just edited: each revision has a distinct logic/FF count, and the `.fs` header
carries a distinct `UserCode`/`CheckSum`. openFPGALoader cannot read the usercode
back from a Gowin part (`--read-register` is Xilinx-only), so this build-side
comparison is the next best thing.

**Timing closes comfortably** (this is the first real data against Phase-6's
deferred gap **G14**):

| Clock | Constraint | Worst setup slack | TNS | Failing endpoints |
|---|---|---|---|---|
| `sys_clk` | 20.000 ns (50 MHz) | **+15.833 ns** | 0.000 | 0 (setup and hold) |

4.17 ns of data path against a 20 ns period implies headroom to roughly ~240 MHz
for this trivial design. PnR took **21 s**, peak memory **1202 MB**.

> Two report quirks worth knowing. (1) The "Max Frequency Summary" table comes out
> **empty** — read `Slack` in §3.3.1 and the TNS table in §2.4 instead. (2) Routing
> emits `WARN (PR1014): Generic routing resource will be used to clock signal
> 'clk_d'`, but §6 of the PnR report then shows `clk_d` on a **PRIMARY** global
> clock — the warning is resolved by a later routing phase and is benign here.

### Findings so far

- **The documented 4x-baud firmware bug does NOT affect this board.** Sipeed's FAQ
  warns that "the actual baudrate is always four times the set baudrate", but our
  debugger firmware (`2025030317`, March 2025) is clean: a design transmitting at
  115200 reads correctly at 115200. `nix run .#fpga-uart` proves it rather than
  assuming it — it scores several candidate bauds by printable-ASCII ratio:

  ```
     115200 :  152 bytes, 100% printable   <- correct
      28800 :   40 bytes,  80% printable
     460800 :  317 bytes,  41% printable
  ```

  Keep the auto-detect anyway: it costs seconds and turns "the UART is garbage"
  into a specific, answered question.
- **Send a COUNTER, not a banner.** `hello_top` emits `rtl-fun uart 004d`,
  `004e`, ... A fixed string proves very little — it can be a stuck buffer, an
  echo, or a previously-flashed image. A monotonically incrementing sequence
  proves the design is live *and* that the baud is right. The LEDs mirror the low
  6 bits of the same counter, so the two output paths can be checked against each
  other.

- **Sipeed's `led` demo only animates while you HOLD the U4 button.** Its top level
  is `led led_inst(..., .rst_n(!rst))` with `rst` on U4 at `PULL_MODE=UP`, so
  untouched, `rst` is high, `rst_n` is low, the design sits in reset with
  `led_reg = 0` — and the LEDs being active-low, **all six are dark**. All-off is
  the correct *running* state, not a failed load. This briefly looked like a
  programming failure; knowing it saves debugging the wrong thing.

- **Board enumerates cleanly.** `journalctl -k` shows `idVendor=0403 idProduct=6010`,
  `SIPEED USB Debugger`, `ftdi_sio` attaching `ttyUSB0` + `ttyUSB1`, no errors.
- **Permissions are the only thing standing between us and JTAG.** Run before the
  NixOS switch, `.#fpga-detect` gets past its preflight (so the board *is* on the
  bus and the tooling *is* correct) and fails precisely at the libusb claim:

  ```
  === JTAG chain scan (board=tangmega138k, expecting 0x0001081b) ===
  + openFPGALoader -b tangmega138k --detect
  unable to open ftdi device: -4 (usb_open() failed)
  JTAG init failed with: unable to open ftdi device
  ```

  That is the expected pre-Step-0 signature, not a hardware problem.
- **The debugger is an emulated FT2232D** (BL616), not a real FTDI part.
- **The wiki's LED description is wrong** — plain GPIO, not WS2812.
- **Gowin EDA was never installed on hp5**; it existed only on `l`, described by no
  expression. Now a derivation (`nix/gowin-eda.nix`).
- **The commercial Gowin tree works, and the first `set_device` candidate is the
  right one.** `set_device -name GW5AST-138B GW5AST-LV138FPG676AC1/I0` was accepted
  immediately; the remaining five candidates in the loop were never needed. The
  bitstream header confirms `Tool Version: V1.9.12.03`.
- **A read-only `/nix/store` Gowin tree is fine.** The log shows
  `[gowin-check] using bin=/run/gowin-ide/bin` — the wrapper's overlayfs fallback
  engaged automatically so it could write `gwlicense.ini` beside the binary. No
  change was needed to make the store path work.
- **The Gowin edition question is settled: commercial.** `build/gowin/gate.log`
  carries no version banner, so this was read out of the shipped device databases
  instead. Education 1.9.11.03 has no `FPG676` order code in
  `data/device/device_info.csv` (only the 484-pin non-Pro part), while commercial
  1.9.12.03 has ten, including `GW5AST-LV138FPG676AC1/I0`. So the recorded Tier-1
  GO must have come from the commercial tree, and
  [`gowin-microvm.md`](gowin-microvm.md)'s "Education/NODELOCK" wording conflated
  the *license* type (NODELOCK, correct) with the *IDE edition*. Both docs are
  corrected.
- **nixpkgs' openFPGALoader 1.1.1 is sufficient.** Both it and the fork list
  `tangmega138k` and resolve IDCODE `0x0001081b`; the fork offers nothing extra
  today. Keep using the nixpkgs default.
- **The vendor `led.fs` targets part number `GW5AST-LV138FPG676AES`** (an
  engineering-sample suffix) while our `set_device` uses `...AC1/I0`. Same device
  (`GW5AST-138B`, version B) and same IDCODE, so it should load — worth watching if
  step 2 misbehaves.

### Exit criteria

- [x] `das` reaches the JTAG node without `sudo` (✅). UART untested — next step.
- [x] `.#fpga-detect` reports IDCODE `0x0001081b` (✅).
- [x] A vendor bitstream runs from SRAM (✅). Flash + power cycle: not yet run.
- [x] Our own `.v` → our own `.fs` → **LEDs visibly driven by our design** (✅).
- [x] Editing `TICK_DIV` visibly changes the board's behaviour (✅).
- [x] Utilization and timing reports captured from `impl/` (✅ see above).

## M1 — parser unit alone (done)

**2026-09-07 — ✅ our parser RTL runs on real silicon.** The M1 design (`m1_top`
wrapping the verified `parser_top` = a hardware `pm_run`) was synthesized, programmed to
SRAM, and its streamed `flow_keys` matched `libparsermodel` **byte-for-byte** on the
board:

```
$ nix run .#fpga-m1-check
=== reading /dev/ttyUSB1 at 115200 for 5s ===
  flow_keys MATCH (48 bytes)
  exit code MATCH (fffffffc)          # P_STOP_OKAY = -4
  live seq counter = 0046             # incrementing -> design live, baud correct
RESULT: PASS — M1 parsed the packet on the board == libparsermodel (baud 115200).
```

This is the M1 exit criterion, **observed** (not merely "programmed"): the parser
datapath parsed a ROM-baked eth/ipv4/tcp packet on the FPGA and produced exactly the
golden model's `flow_keys` + exit code. Utilization **2751 LUT / 688 FF / 0 latches**
(≈2% of the device), timing clean. The build path is `nix run .#fpga-m1-roms` →
`.#fpga-m1-rtl` → `.#fpga-build -- m1` → `.#fpga-load` → `.#fpga-m1-check`.

**How SP00018 was worked around.** GowinSynthesis V1.9.12.03 cannot synthesize our parser
RTL directly (challenge #13, below — it floods `SP00018` on both SystemVerilog and
sv2v-flattened Verilog, even on `parser_execute` alone). The route that works is
**sv2v → yosys `flatten` → GowinSynthesis** (`nix run .#fpga-m1-rtl`): sv2v converts the
SystemVerilog, yosys flattens to one clean module and re-emits plain Verilog that Gowin
accepts. Two sub-problems were solved to get a *correct* build (challenge #18): sv2v
couldn't slice an `int` loop var (→ sized cast), and yosys's memory-init bake was clobbered
by the sim-only zero-init loops (→ guarded with `` `ifndef SYNTHESIS ``, sv2v run with
`--define=SYNTHESIS`). All RTL edits are behaviour-neutral — the whole Phase-6 suite stays
green.

**Built and verified (in simulation):**
- **The M1 design.** `fpga/tang-mega-138k-pro/src/m1_top.sv` wraps the verified
  `tb/parser_top.sv` (the hardware `pm_run`) with a power-on reset, a readout FSM, and
  the M0 `uart_tx`; it emits `FK <96 hex = 48 flow_keys bytes> <8 hex code> <4 hex seq>`
  ~2×/s. Verilator-lint-clean. Constraints (`m1_top.cst`/`.sdc`) reuse the M0 pins.
- **Reproducible ROM images.** `nix run .#fpga-m1-roms` generates
  `roms/m1/{program,cam,pktbuf,params,expected}.hex` from the golden model (`gen_vectors`),
  with a `-- --check` drift guard — the same guarantee `parser-gen-check` gives Phase-7.
- **Host oracle.** `nix run .#fpga-m1-check` reads the UART and diffs the streamed
  `flow_keys` byte-for-byte against `expected.hex` + exit code against `EXP_CODE` — the
  Phase-6 oracle with the transport swapped from Verilator DPI to a wire.
- **Nix + docs.** New module `nix/fpga-m1.nix` (roms / rtl-flatten / check targets),
  wired into `flake.nix`, `rtl-help`, and `docs/nix.md`.
- **RTL correctness preserved.** All the RTL edits below are behaviour-neutral:
  `parser-lint`, `parser-sim`, `parser-sim-suite`, `parser-sim-decode` (22/22 each) and
  `parser-formal` all stay green.

**What the latch fixes bought us** (kept regardless — they are correct): the SV front end
no longer emits *any* `EX2420` latch warning on the parser, and #14 is resolved. They did
**not** clear SP00018, which proved separate (#13).

**Why this matters for M3.** The sv2v → yosys → Gowin route now has a *working, verified*
recipe (`nix run .#fpga-m1-rtl`), and the memory-init trick (`` `ifndef SYNTHESIS ``) is
exactly what a larger design needs. But note yosys `flatten` inlines everything into one
module, and for CVA6-scale memories that is the flatten that defeats BSRAM inference
([assessment §5a](fpga-platform-assessment.md)) — so M3 will likely need a *hierarchical*
yosys pass (keep RAMs as memory, avoid full flatten) rather than this exact recipe.

## M2 — host packet injection (done)

**2026-09-07 — ✅ the whole Phase-6 suite runs on real silicon over a wire.** M1 baked
one packet into ROM; M2 receives an *arbitrary* packet from the host over UART, loads it
into the packet buffer, runs the same baked parse graph, and streams `flow_keys` back —
so the host can drive the entire directed suite and diff every result against the model:

```
$ FPGA_UART=/dev/ttyUSB2 nix run .#fpga-m2-inject -- --suite
=== injecting 22 packet(s) on /dev/ttyUSB2 at 115200 ===
  01-eth-ipv4-tcp            PASS  code=-4
  ... (02–21) ...
  22-pkt-1byte               PASS  code=-14
--------------------------------------------------
M2 inject: 22 case(s), 0 failure(s)
```

All 22 cases — v4/v6, VLAN/QinQ, IPv6 ext-headers, the negative/error cases, and the
boundary cases (256 B, over-buffer, 1-byte) — parsed on the FPGA with `flow_keys` **and**
exit code matching `libparsermodel` byte-for-byte. This is the Phase-6 oracle with the
transport swapped from Verilator DPI to a real serial link. Utilization
**5306 LUT/ALU (5142 LUT + 164 ALU) / 2831 FF / 0 latches**, ~3.8 % of the device.

**Design.** `m2_top` (`fpga/.../src/m2_top.sv`) wraps the verified `parser_top` and adds
a `uart_rx` receiver + a small FSM. Wire framing host→FPGA is
`0x7E plen_hi plen_lo nbuf_hi nbuf_lo <nbuf bytes>`; the FSM holds the parser core in
reset while it writes the bytes into `parser_pktbuf` (whose write port is independent of
`rst_ni`), releases reset to run, then emits one `FK …` reply line (identical to M1's, so
the parse/oracle is shared). Program + CAM stay baked from ROM — they are **identical
across all 22 cases** (verified: 1 unique `program.hex`/`cam.hex`, 20 unique packets), so
only the packet needs injecting. Build path: `.#fpga-m1-roms` → `.#fpga-m2-rtl` →
`.#fpga-build -- m2` → `.#fpga-load` → `.#fpga-m2-inject`.

**The one behaviour-neutral RTL change:** `parser_top` gained 4 tie-off-able input ports
exposing `parser_pktbuf`'s existing write port (`pkt_wr_*`). ROM-only instantiations (M1,
the Verilator smoke tb) tie them to 0 — identical to the previous internal tie-off — so
sim/suite/formal stay 22/22 green.

**Return path — see challenge #15.** The USB debug UART is fabric-TX-only (its RX pin N16
is CPU-dedicated), so M2 uses an external 3.3 V USB-UART adapter on **PMOD2** (`uart_rx`
C21, `uart_tx` B20), confirmed first with a raw loopback (`m2loop` +
`.#fpga-m2-loopback-check`, 256/256 bytes echoed).

## M3a — fit verdict: CVA6 does not fit the GW5AST-138 → pivot to Xilinx

**Date: 2026-09-11. Decision: RV64GC CVA6 (`cv64a6_imafdc_sv39`) will not fit the
Tang Mega 138K Pro. Move the host core to a Xilinx Kintex-7 board.**

M3a asked the true project-gate question — *does a RV64 host core fit on this board at
all?* After solving BSRAM inference (challenge #16) and fixing the GowinSynthesis
LUT-mapper crash (wbuf-depth 8→2 patch), the answer is a clean **no**, and the reason is
not fixable by tooling:

| Resource | Depth-2 CVA6 (yosys good mapper) | GW5AST-138 | Verdict |
|---|---|---|---|
| **LUT-equiv** | **≈645,000** (487k LUT + 158k MUX2_LUT) | 138,240 | **4.7× over** |
| LUT (GowinSynthesis ABC) | 2,019,335 | 138,240 | 14.6× over (`RP0006`) |
| FF / DFF | 25,699 | 139,140 | fits |
| BSRAM (SPX9) | 72 | 340 | fits |
| DSP | 0 used | — | fits |

- **The wall is pure combinational LUT area**, not memory (BSRAM solved, only 72/340
  blocks) and not flops (25.7k/139k). No mapping strategy closes a 4.7× LUT gap — even
  yosys's clean gw5a mapping is 4.7× over before GowinSynthesis's ABC piles on.
- **The FPU is not the lever.** `fpu_wrap` (fpnew FMA + divsqrt + FP32/FP64 cast)
  flattens to **26,843 LUT-equiv (~4%, 0 DSP)**. Dropping it (`cv64a6_imac`) saves ~5%
  of a core that is 470% over — the documented fallback rung-1 is confirmed useless.
- **What was salvaged:** BSRAM inference is solved end-to-end (SPX9 hard-map), the
  ifCut crash is root-caused and fixed, and stock CVA6's front end is SP00018-clean
  (#13 is parser-specific). None of that survives the LUT-area overflow, but it retires
  the two open Gowin challenges for the host-core question.

### Recommended board: **Digilent Genesys 2 (Xilinx Kintex-7 `xc7k325tffg900-2`)**

This is **CVA6's own reference/development platform** — the switch buys turnkey, not a
second port. Evidence in the pinned tree (`build/cva6/corev_apu/fpga/`):

- Default part in `sourceme.sh` is `xc7k325tffg900-2`; `constraints/genesys-2.xdc`,
  `scripts/program_genesys2.tcl`, and `xilinx/xlnx_mig_7_ddr3/mig_genesys2.prj` (DDR3)
  are all present. `make` → `ariane_xilinx.bit` targets it directly.
- **Kintex-7 325T: 203,800 LUT6, 407,600 FF, 445×36 Kb BRAM (≈16 Mbit), 840 DSP.**
- **How big is CVA6 on Xilinx, really?** Published Vivado utilization (PERCIVAL, arXiv
  2111.15286, Vivado 2020.2, XC7K325T): bare CVA6 **28,950 LUT6 / 19,579 FF**; +FP32
  **+6,452 LUT** → full `cv64a6_imafdc` ≈ **40–50k LUT6**. That is **~22%** of the Kintex-7
  325T and **~33%** of an Artix-7 200T (134,600 LUT6) — **both fit comfortably; fit is not
  the differentiator.** (This also corrects an earlier draft estimate of ~110–130k LUT6,
  which was too high.)
- **Why the Gowin path looked 14–45× bigger:** our flow reported 645k LUT4 (yosys) /
  2.02M (GowinSynthesis) vs the real ~45k LUT6. The gap is **toolchain, not design** —
  (1) LUT4 vs LUT6 fabric (~2×), (2) multipliers built from LUTs because our gw5a flow had
  **no DSP mapping** (Xilinx sends them to DSP48), (3) sv2v packed-struct/config explosion
  that Vivado avoids by reading SystemVerilog natively, (4) GowinSynthesis's ABC being ~3×
  worse than yosys on the identical netlist. A well-mapped CVA6 is ~80–110k LUT4-equiv, so
  the GW5AST-138's 138k LUT4 was marginal even ideally, and the bad tools pushed it far over.
- **Reading the LUT numbers — three separate axes; don't conflate them.** The blow-up
  figures we quote come from three *independent* effects. Mixing them is what makes this
  confusing, so keep them straight. All CVA6 numbers below are the same design:

  | # | Axis (what changes) | Comparison | Factor | Same target? |
  |---|---|---|---|---|
  | 1 | **Input quality** — native SystemVerilog vs sv2v-flattened Verilog | native Vivado **48,217** → sv2v→Vivado **277,751** | ~5.8× | yes, both Xilinx LUT6 |
  | 2 | **Mapper quality** — Vivado synth vs open yosys/abc9 | sv2v→Vivado **277,751** → sv2v→abc9 (openXC7) **628,762** | ~2.3× | yes, both Xilinx LUT6 |
  | 3 | **Fabric** — Xilinx LUT6 vs Gowin LUT4 | different cell entirely | ~1.6–2× more LUT4s + no DSP mapping | **no** — unit mismatch |

  Takeaways:
  - **The one trustworthy CVA6 number is native Vivado: 48,217 LUT6 (~24% of the 325T).**
    Everything larger is an artifact of axis 1 and/or 2, not the design.
  - The eye-popping **"628k vs 48k" (~12×) headline is Xilinx-vs-Xilinx** — sv2v input
    (axis 1) *stacked with* the open abc9 mapper (axis 2). It says **nothing about Gowin.**
  - **Gowin-vs-Vivado is axis 3 and is a different, uncontrolled comparison.** You cannot
    compare a Vivado LUT6 count to a Gowin LUT4 count directly: a LUT4 fabric needs ~1.6–2×
    more cells for the same logic *even with a perfect tool* (a coarser cell, not a weaker
    algorithm). GowinSynthesis is *very likely* also algorithmically weaker than Vivado
    (Vivado is far more mature and multithreaded; GowinSynthesis is single-threaded), but we
    never captured a clean CVA6 GowinSynthesis LUT6-equivalent under controlled inputs, so
    treat "Gowin's mapper is weak" as **strongly indicated, not measured here.**
  - Practical rule: **feed Vivado native `.sv` (never sv2v)**; use sv2v only for the open
    tools (yosys/GowinSynthesis), which cannot read SystemVerilog directly.
- Board has DDR3 SODIMM (real DRAM via the in-tree MIG flow — M3b could use it instead
  of a BSRAM scratchpad), USB-UART, USB-JTAG, and **GTX transceivers (~12.5 Gb/s → true
  10GE)**. Needs Vivado (free ML Standard/WebPACK does **not** cover Kintex-7 325T; requires
  a paid/edu Vivado license — the one real cost).

**Alternatives considered:**

| Board | Part | 10GE? | Turnkey in CVA6 tree? | Vivado | Note |
|---|---|---|---|---|---|
| **Genesys 2** *(chosen)* | Kintex-7 XC7K325T | ✅ GTX ~12.5G | ✅ xdc + program + MIG | paid/edu | CVA6 reference; ~22% LUT6; DDR3; the only 10GE-capable option |
| KC705 (Xilinx dev kit) | Kintex-7 XC7K325T | ✅ GTX | ✅ (kc705.xdc, MIG) | paid/edu | Same silicon, pricier/older, often EOL |
| Nexys Video | Artix-7 XC7A200T | ❌ GTP ~6.6G | ✅ (nexys_video.xdc, MIG) | **free** | Fits comfortably (~33% LUT6); turnkey; but GbE-only, no SFP, **no 10GE** |
| Puzhi PZ-A7200T | Artix-7 XC7A200T | ❌ GTP ~6.6G | ❌ (write your own .xdc/MIG) | **free** | Cheapest ($398), 2×SFP + 2×GbE, DDR3; but custom bring-up + vendor risk; **no 10GE** |
| VC707 | Virtex-7 XC7VX485T | ✅ GTX | ✅ (vc707.xdc, MIG) | paid/edu | Bigger/overkill, expensive |
| Alinx AX7325B | Kintex-7 XC7K325T | ✅ GTX | ❌ (write your own .xdc/MIG) | paid/edu | Same silicon as Genesys 2, cheaper, but no turnkey constraints |

**Decision (user, 2026-09-12): Genesys 2 (Kintex-7 XC7K325T).** Since all candidates fit
CVA6 comfortably, fit is not the driver — **10GE is a hard project requirement** (Phase-9
benchmark + the installed 10G optics), and **only the Kintex-7's GTX transceivers reach
10 Gb/s**; Artix-7's GTP caps at ~6.6 Gb/s. Genesys 2 is also the exact part CVA6 is built
and regression-tested on (turnkey xdc/MIG/program scripts). Cost: a paid/edu Vivado license.

**Verify-before-buy (user requirement):** confirm the footprint on our *actual* RTL —
and that it *routes* — before purchasing hardware, using the fully open-source **openXC7**
flow, no Vivado / no license / no board. Productized as one reproducible target:

```
nix run .#fpga-m3-core-rtl -- s2       # produce build/fpga-m3-core-rtl/elab.il (elaborated cva6)
nix run .#fpga-m3-xilinx-fit           # chipdb -> synth_xilinx -> nextpnr-xilinx -> verdict
```

(`nix/fpga-m3-xilinx.nix` + `scripts/fpga-m3-xilinx-fit.sh`, pinning yosys + nextpnr-xilinx +
pypy3 from nixpkgs). It synthesizes `fpga/genesys2/cva6_fit_top.v` — a register-ring harness
that wraps stock `cva6`, folds its 8347 IO bits down to 4 device pins, and leaves the
6905-bit `rvfi_probes_o` trace port unconnected so DCE prunes it (matching CVA6's real
`corev_apu/fpga` SoC → a *deployment-faithful* footprint). Two results:

1. **`synth_xilinx -family xc7`** → the definitive LUT6 / FF / DSP48 / RAMB count on our RTL.
   The 7-series LUT6 fabric is identical across Artix/Kintex, so the count certifies the
   Genesys 2 fit directly.
2. **`nextpnr-xilinx`** place-and-route on the real `xc7k325tffg900-2` chip database → a routed
   `fasm` + achieved Fmax. This is stronger than a count alone: it proves the core actually
   *places and routes* on the target, i.e. that a bitstream is buildable once the hardware
   arrives. (The raw core cannot be routed standalone — 8347 IO bits ≫ ~500 pins — which is
   why the harness exists.)

**Result (run completed 2026-09-16 after ~4.5 days) — the open flow is NOT a reliable LUT
oracle for CVA6; treat it as a FF/DSP/BRAM check only.** `synth_xilinx` mapped stock CVA6 to:

| Resource | Count | vs xc7k325t (407,600 FF / 203,800 LUT6 / 840 DSP / 445 RAMB36) | Fits? |
|---|---|---|---|
| **LUTs (total)** | **628,762** (LUT2 186,780 · LUT5 124,433 · LUT6 114,959 · LUT3 114,599 · LUT4 87,677 · LUT1 314) | nextpnr packed to **640,815 / 407,600 SLICE_LUTX = 157%** | ❌ overflow |
| FF (FDCE 24,105 · FDPE 44 · FDRE 69) | 24,218 | ~6% | ✅ |
| DSP48E1 | 71 | of 840 | ✅ |
| RAMB36E1 | 36 | of 445 | ✅ |
| CARRY4 | **1,629** | — | ⚠️ far too few for a 64-bit core |

**nextpnr-xilinx PnR: failed to place** — `ERROR: no Bels remaining of type 'SLICE_LUTX'`
(157% over). No route, no Fmax produced.

**This 628k-LUT figure is a yosys/abc9 mapping-quality artifact, ~12× CVA6's true Vivado
size — not a real fit failure.** Three proofs: (1) PERCIVAL measured `cv64a6_imafdc` at
**28,950 LUT6 + ~6.5k FP ≈ 40–50k LUT6** on this exact part (~22% of the 325T); Tom Herbert's
Rocket cross-check (AWS F2, Vivado) is ~50k LUT6 too. (2) It is essentially the **same
≈630–645k** the Gowin open flow produced (645k LUT4-equiv) — two independent open ABC-based
mappers landing at ~640k while Vivado gives ~50k is a *mapper* signature, not a *design* one.
(3) The **1,629 CARRY4** is the tell: Vivado maps CVA6's many 64-bit adders/comparators onto
carry chains, but yosys+abc9 here largely did not, so wide arithmetic ballooned into LUTs
(also the cause of the ~108 CPU-hour ABC9 runtime). The FF / DSP48 / RAMB counts, by contrast,
are reliable and all fit comfortably.

**Bottom line for verify-before-buy:** the openXC7 flow is a good *FF/DSP/BRAM* sanity check
and a reproducibility artifact, but it **cannot confirm the LUT fit** for an arithmetic-heavy
core like CVA6 — it over-reports LUTs ~12×. The definitive LUT check is **Vivado** (free
WebPACK targeting XC7A200T certifies the identical 7-series fabric with no board/license, or
the edu license on the 325T), which agrees with PERCIVAL + Tom that CVA6 uses ~22% of the
Genesys 2. **The buy decision is unchanged** (Vivado-grade evidence says it fits; 10GE forces
Kintex GTX regardless) — what we learned is *which tool* can certify the fit.

##### The definitive Vivado LUT check is now a reproducible target

To close the LUT thread on our *own* RTL (not just PERCIVAL's/Tom's cores), the Vivado
check is productized the same way as everything else — one `nix run` target, no ad-hoc host
steps:

```
nix run .#fpga-m3-vivado-fit             # Vivado synth-only -> util.rpt -> fit verdict
nix run .#fpga-m3-vivado-fit -- report   # re-print utilization + verdict from util.rpt
```

`nix/fpga-m3-vivado.nix` + `scripts/fpga-m3-vivado-fit.sh` + `fpga/genesys2/m3-vivado-fit.tcl`.
It runs Vivado `synth_design -mode out_of_context` on the **same** `cva6_core_sv2v.v` input the
openXC7 flow used (+ the `cva6_fit_top` harness) — so the Vivado-vs-abc9 delta is
apples-to-apples on identical RTL — and prints LUT6 / FF / DSP48 / RAMB36 / CARRY4 against the
325T budget. Default part is **XC7A200T** (`xc7a200tsbg484-1`): the largest **free**-tier
7-series part, with the *identical* LUT6 fabric to the Genesys 2's 325T, so an A200T count
certifies the Kintex with **no board cost**. (The free Basic tier actually covers the 325T too —
see licensing note below — so `XILINX_PART=xc7k325tffg900-2` also works for the exact part.)

**Host-tool dependency (documented impurity, like the Gowin path):** Vivado is not in nixpkgs;
install it (free tier covers the 7-series — see licensing note below) and put `vivado` on `PATH`
(source `settings64.sh`) or export `$VIVADO`. Synth-only, so this runs in minutes-to-an-hour, not
the openXC7 days.

**Licensing reality (changed in 2026.1 — our earlier "no license cost" assumption was wrong).**
Vivado **2026.1** moved to a **tiered licensing model** (Basic / Core / Pro / Enterprise / Gold).
The old "Standard Edition needs no license" rule ended: even the **free "Vivado Basic" tier now
requires a generated license file** — `synth_design` errors `valid license was not found` without
one (proven here: a trivial 2-gate synth fails identically on xc7a35t, xc7a200t, *and* xc7k325t,
so it is a license-**file** gate, not device-tier, not the sandbox). Two silver linings: (1) the
free **Basic tier covers all 7-series** — Artix-7 **and** Kintex-7, so we can synth the exact
`xc7k325t`, not just the A200T proxy; (2) our synth-only utilization flow is Basic-tier
functionality (the tier-gating hits impl/timing-closure/DFX/encrypted-bitstream, which we do not
run). The Basic license is FlexLM **node-locked to a NIC MAC** (host ID) — so, like Gowin, the free
tier is effectively MAC-locked. Get it free from AMD Product Licensing (account login) against the
recorded MAC below.

**On NixOS:** Vivado ships as pre-built FHS binaries (its installer JRE and the tools link
`libX11.so.6` / `libstdc++` / … at `/usr/lib` paths NixOS lacks — the raw `.bin` dies with
`libX11.so.6: cannot open shared object file`, and the 98 GB SFD tar has the identical problem
since it uses the same `xsetup`/JRE). Run both the installer and the tools inside a `buildFHSEnv`
sandbox — the reproducible NixOS analogue of the Gowin microVM (`nix/vivado-fhs.nix`):

```
nix run .#vivado-fhs                 # interactive FHS shell — run the installer here (needs a display)
#   inside: ./FPGAs_..._Lin64.bin  -> Vivado -> Vivado ML Standard (free) -> 7-Series only
export VIVADO_SETTINGS=/path/to/Xilinx/<ver>/Vivado/settings64.sh
export VIVADO="$(nix build --no-link --print-out-paths .#vivado-fhs-vivado)/bin/vivado"
nix run .#fpga-m3-vivado-fit         # the `vivado` wrapper re-enters the sandbox automatically
```

*(On hp5 the hardened `vivado-box.nix` variant is used instead — confined FHS with a private home
and read-only host. For the fit run its isolation hides the repo, so inputs are staged into the box
home; the permissive `vivado-fhs` above is the general path.)*

**Portable free license via a fixed, repo-recorded MAC.** Because the free Basic license is
node-locked to a NIC MAC, locking to a *physical* NIC means a separate license per machine. Instead
we record **one** MAC in the repo and make it present on every machine, so a **single** license is
portable. `nix/vivado-license-mac.nix` holds it — **`02:ca:6f:00:00:01`** (host ID `02ca6f000001`;
locally-administered + unicast, cannot collide with a real NIC). Creating an interface with a chosen
MAC is blocked in unprivileged user namespaces on this kernel (`ip link add` → `Operation not
permitted`), so the MAC is established at the system layer by a NixOS module,
`nix/vivado-license-netdev.nix` (flake output `nixosModules.vivado-license-netdev`): it brings up a
dummy NIC `vivadolic` with that MAC via a stack-agnostic systemd oneshot (adds a NIC, never touches
real ones). The Vivado box shares the host network namespace, so FlexLM inside it sees `vivadolic`.

```
# in each machine's NixOS config:
imports = [ /path/to/rtl-fun/nix/vivado-license-netdev.nix ];   # or inputs.rtl-fun.nixosModules.vivado-license-netdev
sudo nixos-rebuild switch
ip link show vivadolic                                          # confirm the fixed MAC is up
# then: AMD Product Licensing -> free node-locked "Vivado Basic" for host ID 02ca6f000001
#       -> drop the .lic at the box home ~/.Xilinx/  (or export XILINXD_LICENSE_FILE)
```

(Caveat: node-locking to a `dummy`-type interface is a common FlexLM-in-VM/container trick but is
unverified until a `.lic` is in hand; if FlexLM rejects it, fall back to a per-machine license
against a real NIC MAC.)

**★ Result (2026-09-19): CVA6 FITS the xc7k325t at 23.7% LUT — verify-before-buy CLOSED on our own RTL.**
Free Vivado 2026.1 (Basic tier, node-locked; run on hp5 in the NixOS FHS box) synthesized the **native
CVA6 SystemVerilog** (top `cva6`, `cv64a6_imafdc_sv39`, the resolved `files.txt` flist — *not* sv2v)
`-mode out_of_context -flatten_hierarchy none` on the actual Genesys 2 part `xc7k325tffg900-2`:

| Resource | Native Vivado | 325T budget | Util | |
|---|---|---|---|---|
| **Slice LUTs (LUT6)** | **48,217** | 203,800 | **23.7%** | ✅ |
| Slice Registers (FF) | 22,204 | 407,600 | 5.4% | ✅ |
| DSP48E1 | 27 | 840 | 3.2% | ✅ |
| Block RAM (RAMB36) | 36 | 445 | 8.1% | ✅ |
| CARRY4 | 1,831 | — | — | |

**FITS with ~4× LUT headroom** (conservative — `rvfi_probes_o` kept + hierarchy unflattened both only
add LUTs). This lands exactly on the two independent Vivado datapoints (PERCIVAL ~40–50k same part;
Tom ~50k Rocket). **Same RTL, three tools:** native Vivado **48.2k** → sv2v+Vivado **277.8k (5.8×)** →
sv2v+abc9/openXC7 **628.8k (13×)**. The 13× openXC7 figure was *two* compounding artifacts — the abc9
mapper (~2.3×) on top of the **sv2v input** flattening (~5.8×) — never the design; FF/DSP/BRAM were
trustworthy in every flow. **Lesson: Vivado is SystemVerilog-native — feed it CVA6's real `.sv`, never
sv2v** (sv2v is only for the open tools). Memory gotcha: raw `cva6` with rvfi outputs kept OOMs >61 GB
under default whole-core flattening; `-flatten_hierarchy none` cut peak to ~2.3 GB and finished in ~22 min.
Reports: `build/fpga-m3-vivado/util_native_k325t.rpt` (+ `_hier`, + `util_sv2v_k325t.rpt` for the contrast).
The buy decision (Genesys 2) now rests on a first-party Vivado measurement of *our* RTL, not just external
datapoints. (Productization TODO: a native-flist `nix run` target — the current `fpga-m3-vivado-fit`
reads the sv2v file and so reports the inflated 277.8k; a follow-up target should read `files.txt`+incdirs
natively with `-flatten_hierarchy none`, top `cva6`.)

#### Candidate boards — 10 GbE-capable Kintex-7 (fit is settled; the differentiator is 10G I/O + bring-up cost)

CVA6 fits any of these (48,217 LUT6 is 24% of the xc7k325t; LUT/FF/DSP/RAMB counts are
package-independent, so every xc7k325t board is equivalent on *fit*). The real selection
axes are **onboard SFP+ cages wired to GTX at 10G** (for the installed 10G optics — the
whole reason for Kintex over Artix), **DDR3 for the CVA6 SoC**, and **board-support bring-up
cost** (CVA6 ships turnkey files only for the Genesys 2).

**All three boards carry the identical silicon** — `XC7K325T-2FFG900` (same die, same FFG900
package, same speed grade **-2** we measured against; the ALINX parts are the industrial-temp
`…FFG900I`, 16 GTX). So *fit is identical across all three*; the choice is purely 10G wiring
+ DDR3 + bring-up cost. Verified below against the ALINX user manuals
(`downloads/AX7325B_User Manual.pdf`, `downloads/AV7K325_User_Manual.pdf`, ALINX 2022).

| Board | Vendor | Part (all -2 FFG900, 16 GTX) | Onboard SFP+ (→GTX) | Other 10G/serial | DDR3 | CVA6 board support | Cost |
|---|---|---|---|---|---|---|---|
| **Genesys 2** | Digilent | xc7k325t-2ffg900 (comm) | **None onboard** — GTX exit on the FMC HPC; 10G needs an FMC→SFP+ mezzanine | PCIe (FMC) | 1 GiB | **Turnkey** (`genesys-2.xdc`, `mig_genesys2.prj`, `program_genesys2.tcl` in `corev_apu/fpga`) | ~$999 edu / ~$1,199 |
| **ALINX AX7325B** | ALINX | xc7k325t-2ffg900I (ind) | **4× SFP on BANK117 GTX, refclk 156.25 MHz → native 10G-ready** | **QSFP+ 40G** (BANK118, 4×GTX); PCIe x8 Gen2 | **2 GiB** (4×512 MB, 64-bit) + SODIMM expansion | **None** — port `.xdc` + MIG DDR3 + SFP+/QSFP constraints | cheaper |
| **ALINX AV7K325** | ALINX | xc7k325t-2ffg900I (ind) | **4× SFP on BANK117 GTX, refclk 125 MHz → native 1.25G** (10G needs a 156.25 MHz refclk supplied) | 2× HDMI; PCIe x8 Gen2 | **2 GiB** (4×512 MB, 64-bit) | **None** — same porting as above | cheaper |

**The decisive 10G detail (from the datasheets):** both ALINX boards route 4× SFP to a full
GTX quad on BANK117, but only the **AX7325B** clocks that bank at **156.25 MHz** — the
reference 10GbE line-rate clock — and it adds a **40G QSFP+** on BANK118. The **AV7K325**
clocks its SFP bank at **125 MHz** (native 1.25 GbE); its GTX are 10G-capable silicon, but
you'd have to supply a 156.25 MHz reference to run them at 10G, and it swaps the QSFP for
2× HDMI. **For a 10G packet-parser host, AX7325B is the clear ALINX pick.** Both ALINX
boards carry 2 GiB DDR3 (double the Genesys 2's 1 GiB) and a PCIe x8 Gen2 edge.

Links — [AX7325B](https://www.en.alinx.com/Product/FPGA-Development-Boards/Kintex-7/AX7325B.html)
· [AV7K325](https://www.en.alinx.com/Product/FPGA-Development-Boards/Kintex-7/AV7K325.html)
· [K7 line index](https://www.en.alinx.com/Product/FPGA-Development-Boards/Kintex-7.html)
· AMD embedded-partner listing (contact request submitted 2026-09-20):
<https://www.amd.com/en/search/partner/embedded-partner-solutions.html/5974>.

**Trade-off in one line:** Genesys 2 = turnkey CVA6 software but 10G needs an FMC SFP+ card
(and only 1 GiB DDR3); **AX7325B** = onboard 4× 10G SFP + 40G QSFP + 2 GiB DDR3, cheaper, but
we write the board support (`.xdc`, MIG, SFP+/QSFP pinout) ourselves. All three are the exact
`xc7k325t-2ffg900` we measured, so none changes the fit verdict — the decision is **turnkey
bring-up (Genesys 2) vs. onboard 10G + more DDR3 for less money (AX7325B)**.

#### What it takes to run CVA6 on the ALINX AX7325B (porting scope + risk)

Onboard 10G/40G is the lower-risk path to the *end goal*: it replaces an open-ended
integration problem (Genesys 2 needs an FMC→SFP+ mezzanine, plus sourcing a 156.25 MHz
GTX reference clock onto the right FMC pins) with a **bounded, mostly-mechanical board
port**. The AX7325B has a **1:1 equivalent for every peripheral CVA6's Genesys 2 flow
uses**, and — critically — the 10G/40G reference clocks are already on the board:

| CVA6 needs | AX7325B provides | Pin(s) / bank |
|---|---|---|
| 200 MHz sys clock (MIG) | 2× 200 MHz differential | `SYS_CLK` AE10/AF10 |
| 10G refclk | **156.25 MHz** wired to SFP bank | BANK117 |
| 40G refclk | 125 MHz wired to QSFP bank | BANK118 |
| DDR3 | **2 GiB** (4× MT41K256M16, 64-bit) | HP banks 32/33/34 |
| Console UART | USB-UART bridge | AJ26/AK26 *(verify — see caveat)* |
| Boot media | Micro SD slot | ✓ |
| Config | 10-pin JTAG (openFPGALoader / Vivado) | ✓ |
| Status / input | 6 LEDs (4 user) + 2 buttons | ✓ |

**Porting checklist** — CVA6 ships board support in `corev_apu/fpga` for `BOARD=genesys2`;
the port = creating the ALINX equivalent of each piece:

| Piece | Genesys 2 (exists) | AX7325B (we create) | Effort / risk |
|---|---|---|---|
| Pin constraints | `constraints/genesys-2.xdc` | `fpga/ax7325b/ax7325b.xdc` — **first draft done** (clk, rst, UART, SD, JTAG, LED) | mechanical — **LOW** (pinout in hand) |
| DDR3 MIG | `mig_genesys2.prj` | `fpga/ax7325b/mig_ax7325b.prj` — **first draft done** (64-bit, 2 GiB, 4× MT41K256M16, banks 32/33/34) | **the real work — MEDIUM** (needs MIG-regen verify) |
| Clocking | clk wizard @ Genesys 2 | retarget to AX7325B 200 MHz `SYS_CLK` | **LOW** |
| Top-level board select | `ariane_xilinx` `GENESYS2` ifdef | add an `AX7325B` variant | LOW–MEDIUM |
| Programming | `program_genesys2.tcl` | JTAG via openFPGALoader / Vivado | **LOW** |

**The 10G/40G MAC itself is Phase-9 work, identical on either board** — likely the
open-source **verilog-ethernet (Forencich) 10G/25G MAC + PCS/PMA on GTX** (avoids Xilinx's
licensed 10G IP). The AX7325B advantage is that the SFP+ cage and its 156.25 MHz refclk are
already wired and proven by ALINX's own demo; the Genesys 2 would need the FMC mezzanine +
refclk sourced first.

**Progress (drafted this session, in `fpga/ax7325b/`):**
- `ax7325b.xdc` — board I/O constraints (see checklist above).
- `mig_ax7325b.prj` — the 64-bit DDR3 MIG config (see checklist above).
- `ax7325b.svh` — board-defines header (`\`define AX7325B` + `\`KINTEX7`), the anchor for
  the `ariane_xilinx` port; mirrors `genesysii.svh`.

**`ariane_xilinx` AX7325B variant — exact change-list (the remaining RTL work).** This is
a CVA6 patch (applied via nix, like `nix/cva6-parser/m3a-wbuf-depth.patch`), NOT an edit to
`build/`. It needs the full Vivado SoC build to validate, so it is scheduled for board-in-hand
/ first-SoC-build time. Against `corev_apu/fpga/src/ariane_xilinx.sv` (add `\`elsif AX7325B`
branches next to the existing `\`ifdef GENESYSII`):
- **Port list** (the `\`ifdef GENESYSII` block, ~L16): keep `sys_clk_p/n`, `cpu_resetn`,
  JTAG (`trst_n/tck/tms/tdi/tdo`); **widen DDR3 to 64-bit** (`ddr3_dq[63:0]`,
  `ddr3_dqs_p/n[7:0]`, `ddr3_dm[7:0]` — matching `mig_ax7325b.prj`); **narrow `led` to
  `[3:0]`**; **drop the 9 `eth_*` RGMII ports**, `sw[7:0]`, and `fan_pwm` (no board
  equivalents).
- **Ethernet MAC** (`ariane-ethernet`, instantiated in the body + wired in
  `ariane_peripherals_xilinx.sv`): the AX7325B has no onboard 1G PHY, so guard the RGMII
  MAC out for this board (or stub its AXI port). 1G Ethernet is not part of the 10G goal;
  the SFP+/GTX 10G MAC is separate Phase-9 work.
- **DDR3 / clocking**: reuse the shared `\`ifdef KINTEX7` MIG/clock branch (~L1162) that
  GENESYSII already uses — `mig_ax7325b.prj` drives it; no new logic expected there beyond
  the wider data bus.
- **led/sw fan-out**: tie off internal references to the removed `sw`/`fan_pwm` and the
  upper `led` bits.
- **Build wiring**: a `BOARD=ax7325b` path (Makefile/tcl) selecting `ax7325b.xdc`,
  `mig_ax7325b.prj`, `ax7325b.svh`, and a `program_ax7325b.tcl` (openFPGALoader or Vivado
  over the board's standard JTAG), then re-export as a reproducible `nix run` target.

#### Phase-9 test topology + the QSFP reference-clock gotcha

Planned bring-up assets (user, 2026-09-20): SFP+ and QSFP fiber optics/DACs inserted when
needed; possibly **2× AX7325B for FPGA-to-FPGA back-to-back**; plus host **10GE and QSFP
NICs**. Testing against a real NIC (not just board-to-board) is the stricter, better target:
it forces the FPGA path to be **standards-compliant** — 10GBASE-R (64b/66b PCS, 10.3125
Gbps) for SFP+, 40GBASE-R4 for QSFP — which the open **verilog-ethernet (Forencich)** MAC
provides. Back-to-back is more forgiving (both ends agree on a rate), so it's the easy first
milestone; NIC interop is the compliance gate.

**Gotcha — the AX7325B GTX reference clocks are fixed crystals, and the two banks differ**
(datasheet Part 6/8/9, confirmed): SFP+ **BANK117 = 156.25 MHz** (native 10GBASE-R — clean
for the 10GE NICs), but QSFP **BANK118 = 125 MHz**. 125 MHz cleanly makes 1.25/2.5/5/10.0G,
**not** the 10.3125 Gbps/lane that standard **40GBASE-R4** (and a 40GbE NIC) needs — GTX QPLL
integer-N can't synthesize 10.3125G from 125 MHz. Consequences + options for the 40G path:
- **Preferred:** route BANK117's 156.25 MHz `MGTREFCLK` into the QSFP quad (BANK118). A
  Kintex-7 GTX quad can source its refclk from an adjacent quad (±1), so if 117/118 are
  neighbours this needs only refclk-routing constraints, no board change. **VERIFY quad
  adjacency** (117↔118) in the 7-series transceiver user guide / floorplan.
- **Alternative:** use **4× SFP+ as the 40G aggregate** — all four lanes are already on the
  156.25 MHz BANK117 clock, and a 40GbE NIC's QSFP breaks out to 4× 10G anyway.
- **Board-to-board only:** two AX7325Bs over QSFP could run a non-standard 10.0G/lane (both
  ends agree), but that won't interop with a NIC — so don't rely on it for the NIC leg.
The SFP+ 10G path has no such issue; it is the primary target and is clock-ready as wired.

**Best de-risking step:** download ALINX's **AX7325B example-design / documentation package**
(separate from the user manual + PCB `.rar`) — it contains working **DDR3-MIG memtest** and
**SFP/QSFP GT loopback** demos, which hand us a proven MIG `.prj` and a GT wrapper with the
correct pin/clock settings to copy. That turns the one MEDIUM item (DDR3) into "replicate
ALINX's known-good config."

**Risks / caveats on the ALINX side:**
- **Docs are template-reused across ALINX's Zynq + Kintex lines** — e.g. the manual lists the
  UART on `PS_MIO12/13` (Zynq PS naming) on a chip with *no* PS. **Verify every pin against the
  schematic, not just the manual** before trusting the `.xdc`.
- **No CVA6 community precedent** on this board (Genesys 2 is CVA6's reference) — we'd be first,
  so less help if something is odd.
- **DDR3 SI/timing:** trust that ALINX laid out DDR3 correctly — their shipped memtest demo
  proves it, so replicate their MIG config rather than deriving one.
- Vivado licensing unchanged — the **free Basic tier covers xc7k325t** (validated this session).

**Assessment:** for the 10G/40G end goal, the AX7325B is genuinely lower-risk — a *bounded*
port (realistic bring-up ~days: clock→UART→LED, then DDR3 memtest, then drop in CVA6) with a
proven reference for the one hard part, vs. the Genesys 2's *open-ended* FMC 10G integration.
The cost is that we own the board support. Board-bring-up files will live under
`fpga/ax7325b/` (starting with `ax7325b.xdc`).

#### Pre-purchase gateware+software validation (prove we can build it, before buying)

The AX7325B is not turnkey for CVA6, so the risk is "can we create the gateware/software?",
not "does it fit". Nearly all of that is provable **now on hp5, with no board**, using the
installed Vivado (FHS box) + the reproducible `nix run` flow. Only silicon bring-up (DDR3
calibration, GTX link SI to a real NIC, real throughput, final timing sign-off) needs
hardware. Staged as reproducible targets; results recorded here as they land.

**A1 — Vivado license boundary: FULL flow is free on the 325T (2026-09-20).** New target
`nix run .#fpga-vivado-license-check` (`nix/fpga-vivado-license-check.nix`,
`scripts/fpga-vivado-license-check.sh`, `fpga/vivado/license-probe.tcl`) pushes a trivial
design through synth → place → route → `write_bitstream` on a part and reports which license
features Vivado grants. **Result on the free "Basic" tier, `xc7k325tffg900-2`:** both
`Vivado_Synthesis` *and* `Vivado_Implementation` granted; `write_bitstream completed
successfully` (11.4 MB `.bit`). So — correcting the earlier "synth-only" assumption — **a
complete routed bitstream + timing on the exact AX7325B die is free-tier; no edu license
needed.** This unblocks the full-SoC impl proofs below at zero license cost.

**A2 — turnkey full SoC build: CVA6+DDR3 routes and CLOSES TIMING on the die (2026-09-20).**
New target `nix run .#fpga-soc-vivado` (`nix/fpga-soc-vivado.nix`, `scripts/fpga-soc-vivado.sh`)
materializes the pinned CVA6 tree, applies a board-file-free source-prep, and drives CVA6's
turnkey `make fpga BOARD=genesys2` (bootrom → 8 IPs incl. the DDR3 MIG → synth → impl →
`write_bitstream` → `write_cfgmem`) on `xc7k325tffg900-2` inside the FHS-boxed free-Basic
Vivado. **Result: 0 errors, `ariane_xilinx.bit` (11 MB) + `.mcs` produced; timing MET.**

| metric | value | note |
|---|---|---|
| worst-path slack (WNS) | **+0.065 ns (MET)** | the critical path is *inside the DDR3 MIG* (a 200 MHz `clk_pll_i` write path), not CVA6 logic |
| CVA6 core clock | 50 MHz (20 ns) | ample margin; MIG PHY is the timing-critical block, as expected for DDR3 |
| SoC LUTs (`ariane_xilinx`) | **75,267 = 37% of 325T** | whole SoC: core + DDR3 MIG + peripherals + debug |
| CVA6 core LUTs (`i_ariane`) | 49,571 | cross-checks the 48,217 synth-only fit (A200T oracle) — consistent |
| FF / RAMB36 / DSP | 45,930 / 50 / 27 | leaves headroom for the 10G MAC + parser |

This is the strongest single pre-buy datapoint: our boxed Vivado drives the **entire** flow
(MIG IP gen, `read_ip`, place, route, bitstream) and the full CVA6 SoC + DDR3 **routes and
meets timing** on the exact AX7325B die. Three integration issues were fixed reproducibly in
the target (fresh throwaway tree, no upstream edit): bootrom `main.c` vs modern GCC (compile
with `-std=gnu17`); `gen_rom.py` exec bit lost under `cp --no-preserve=mode` (preserve mode +
`chmod u+w`); and — key for the AX7325B — **`board_part` not found** (Digilent board files
aren't installed), fixed by making the flow **board-file-free / part-only**, which is exactly
what an ALINX board (not in Vivado's board store) requires anyway.

**B3 — AX7325B DDR3 MIG pinout is LEGAL on the die (2026-09-20).**
New target `nix run .#fpga-mig-check -- ax7325b` (`nix/fpga-mig-check.nix`,
`scripts/fpga-mig-check.sh`, `fpga/vivado/mig-check.tcl`) generates a MIG 7-series
controller from `fpga/ax7325b/mig_ax7325b.prj` (2 GiB / **64-bit** DDR3, 8 byte lanes,
sys_clk AE10/AF10) targeting `xc7k325tffg900-2`, board-file-free, and OOC-synthesizes it.
**Result: `MIG_GENERATE_OK` + `MIG_SYNTH_OK` (synth_design Complete!, 100%)** — the 64-bit
byte-lane / bank grouping is legal on the exact AX7325B die with **no board and no full SoC**.
This retires the MEDIUM-risk DDR3 item from the plan: the datasheet-derived memory pinout is
validated pre-buy, isolated from CVA6 so a pin/bank error surfaces here rather than in a
multi-hour SoC impl.

**B4 — AX7325B `ariane_xilinx` port BUILDS + FITS on the die (2026-09-20).**
`nix run .#fpga-soc-vivado -- ax7325b` applies the AX7325B CVA6 port
(`nix/cva6-fpga/ax7325b-board.patch` + `fpga/ax7325b/{ax7325b.svh,ax7325b.xdc,
mig_ax7325b.prj}`) to a throwaway tree and runs a synth-only build-check (STAGE=synth)
on `xc7k325tffg900-2`. **Result: synthesis finished with 0 errors, 0 critical
warnings** — the new board variant elaborates and synthesises cleanly.

| metric (post-synth) | value | note |
|---|---|---|
| SoC LUTs (`ariane_xilinx`) | **80,251 = ~39% of 325T** | synth-stage estimate; impl trims (cf. A2 post-impl 75,267 = 37%) |
| CVA6 core LUTs (`i_ariane`) | 50,091 | within ~1% of A2's 49,571 (genesys2) — consistent |
| FF / RAMB36 / RAMB18 / DSP | 49,795 / 40 / 2 / 27 | `InclEthernet(1'b0)` drops the 1G RGMII MAC, as intended (no on-board PHY) |

The port is delivered as a reproducible CVA6-tree patch (applied to the throwaway
copy, no upstream edit): Makefile `BOARD=ax7325b` + a general `FPGA_TARGET` knob;
`run.tcl` xdc/svh branches + a `STAGE=synth` early-exit; a `synth` target in
`corev_apu/fpga/Makefile`; and in `ariane_xilinx.sv` an `` `elsif AX7325B `` port
block (64-bit DDR3, `cpu_resetn`, `led[3:0]`, no eth/sw/fan_pwm), reset-polarity
branch, `InclEthernet(1'b0)` reordered ahead of `KINTEX7`, guarded eth connections,
and a `led`/`dip_switches` tie-off. Impl/pin sign-off is a deliberate board-in-hand
residual — the `ax7325b.xdc` pins carry `#VERIFY` markers, so B4 validates
build+fit pre-buy and leaves place/route to hardware.

**AX7325B pre-buy verdict: GO.** A2 proved the die/flow/timing (turnkey Genesys 2,
same `xc7k325tffg900-2`); B3 proved the 64-bit DDR3 pinout; B4 proves the AX7325B
CVA6 port itself builds + fits. The three risks that could have been discovered only
after purchase are retired on `hp5` with no board.

**Aside — KCU1500 / Kintex UltraScale KU115 evaluated + rejected (2026-09-20).** A
cheap ($495) 2×QSFP28 KCU1500 (`XCKU115-2FLVB2104E`, `xcku115-flvb2104-2-e`) was
considered. Rejected: (1) KU115 is Vivado ML **Enterprise-only** — our free **Basic**
tier (which A1 proved does the 325T end-to-end) does not cover it; (2) the boxed
Vivado is a 7-series-only install (`fpga-vivado-license-check` on the part →
`[Device 21-436] No parts matched`), so even evaluating it needs a much larger
re-install; (3) an UltraScale CVA6 port (DDR4 controller, GTH, new clocking) plus a
headless PCIe-accelerator form factor are far larger efforts than the 7-series
AX7325B path. Staying with the AX7325B.

**C5 — 10G MAC BUILDS + FITS + meets Fmax on the die (2026-09-20).**
`taskset -c 2-7 nix run .#fpga-10g-fit` (stage `all`) synthesizes + OOC-places-and-routes
Alex Forencich's verilog-ethernet `eth_mac_10g` (64-bit XGMII, AXI-Stream fabric side —
the 10G sibling of the 1G MAC already vendored under `corev_apu/fpga/src/ariane-ethernet/`)
on `xc7k325tffg900-2`. The DUT is pinned as the flake input `verilog-ethernet-src`
(rev `77320a9`, `flake=false` — same convention as `openfpgaloader-src`). It is synthesized
directly as an `out_of_context` top (no fit harness — OOC ports are primary I/O and are not
constant-folded, the same faithful idiom as `fpga-m3-vivado-fit-native.tcl`), with both MAC
clock domains constrained at 6.400 ns (156.25 MHz) and split into async clock groups.

| Metric (post-route) | Value | Note |
|---|---|---|
| LUT6 | **1,489** / 203,800 (0.7%) | plain framing MAC (PTP/PFC/LFC off) — trivially small |
| FF | 577 / 407,600 (0.1%) | |
| DSP48 / RAMB36 | 0 / 0 | pure logic; no DSP or block RAM |
| WNS @ 156.25 MHz | **+2.081 ns** | meets timing with ~2 ns slack (implied Fmax ≈ 230 MHz) |

**Result:** the 10G MAC datapath BUILDS, FITS and closes timing on the 325T fabric with
huge margin. Combined with B4 (SoC 80,251 LUT ≈ 39%), **CVA6 + a 10G MAC comfortably
co-reside** on the die — 1,489 + 80,251 ≈ 40% of the 325T's LUT6. The **GTX / 10GBASE-R
PCS-PMA transceiver** leg (BANK117 156.25 MHz refclk + serdes SI) is deliberately *not*
built here: it is the board-in-hand residual (see §"Out of scope"). This is a fabric-fit +
Fmax feasibility check, not a bitstream.

**D6 — in-core NIC ring driver parses the WHOLE corpus == the golden model, on Spike AND QEMU (2026-09-20).**
`taskset -c 2-7 nix run .#cva6-parser-nic-cosim` builds **one** bare-metal ELF that parses the
entire pinned xdp2 corpus in a **single re-arming run** — no per-packet reboot — and byte-compares
every result against the reference model. Where `cva6-parser-cosim` / `parser-spike` / `parser-qemu`
boot one ELF per packet (each a fresh one-shot parse), D6 proves the *multi-packet* datapath: a NIC
RX descriptor-ring driver (`tests/cva6-parser/nic_ring.c` + `nic_ring_asm.S`) DMAs each frame into
the `0x5000_0000` packet MMIO, writes `ParseLen` to (re-)arm, runs the in-core parse block, then
compares `flow_keys` (META) and the exit code against the baked-in golden. `tohost=1` iff **every**
packet matched (fesvr / QEMU `-M spike` exit 0 ⇒ PASS; else fail code 3=keys / 5=code / 7=no-exit).

The re-arm is a small, **fidelity-preserving** addition to the two functional device models only:
`parser_shared.rearm` (in `nix/{spike-tandem,qemu-parser}/parser_shared.h`) is set on every
`ParseLen` (0x100) store and consumed by the arm gate (`parser_ext.cc` / `parser_helper.c`), so a
new `ParseLen` re-binds the model to the next packet — `pm_init` zeroes `ps` (done=0) and the meta
frame, matching a fresh golden init, while the CAM (programmed once) persists. A single-shot ELF
writes `ParseLen` exactly once, so the gate reduces to the old `!armed` behaviour and every existing
one-shot target is byte-identical. The corpus + per-packet golden `flow_keys`/exit-code are baked
into one C header by a new generator mode, `gen_parser_rom --corpus-blob` (`verif/gen/gen_parser_rom.c`).

| Leg | Result | Note |
|---|---|---|
| corpus blob | **306** Ethernet packets (72 non-Ethernet skipped) | emitted from the golden model, `META_LEN=48` |
| Spike (primary) | **PASS** — all 306 == golden across a re-arming run | standalone parser Spike (`spike-parser`) |
| QEMU (secondary) | **PASS** — all 306 == golden across a re-arming run | patched `qemu-system-riscv64 -M spike` |

**Result:** the parser **software/logic is correct across a real, multi-packet re-arming run** —
the whole corpus parses identically to the reference model on two independent ISA simulators, with
no board and no per-packet reboot. This retires the Phase-8 pre-buy *functional* risk. Plan:
`~/.claude/.../plans/ok-in-this-folder-jolly-perlis.md`.

**D6 Increment 2 — the RTL parser FU itself re-arms; a multi-packet run through the CVA6 core == the golden model (2026-09-20).**

Increment 1 re-armed only the two *functional* device models (Spike/QEMU). Increment 2 gives the
**RTL functional unit** the same capability, so a single booted program parses many packets through
the real CVA6 pipeline + `cva6_parser_wrap` — the hardware datapath, not a model. A new
`parse_rearm_i` input (driven by the ParseLen-store strobe `parser_wr_plen`, threaded
`ariane_testharness → ariane → cva6 → ex_stage → wrap`) re-initialises the parse state
(`reset_state()`, the pend/CAM queues, the exit latches) and zeroes the metadata frame on each
ParseLen store, while the CAM (a separate module, programmed once) persists — matching the golden
model's per-packet `pm_init` memset. On a single-shot ELF the strobe fires once at reset, so the
behaviour is bit-identical to the old one-shot FU (a fidelity no-op).

New reproducible target — `nix run .#cva6-parser-rearm` — boots **once** and drives the *same*
`nic_ring.c` NIC-ring driver as the Spike/QEMU leg over the `0x5000_0000` MMIO window through the
CVA6 core, re-arming the FU between packets and comparing the committed flow_keys + exit code to the
golden model baked in at build time.

| Check | Result |
|---|---|
| `cva6-parser-rearm` (RTL, 8 corpus packets in ONE boot) | **PASS** — all 8 == golden across 7 re-arms (68,631 cycles; verified to 32 packets / 31 re-arms during bring-up) |
| `parser-wrap-test` (I1–I5 commit/flush/MMIO invariants) | **PASS** — the re-init block + TB tie-off regress nothing |
| `parser-formal` (k-induction, `parse_rearm_i` a *free* input) | **PASS** — the updated `a_arch_committed` invariant holds under adversarial re-arm timing |
| `cva6-parser-cosim` (single-shot in-core fidelity) | **PASS** — 22/22, the one-shot path is unchanged |
| `cva6-parser-tandem` (RVFI-vs-Spike lock-step) | **PASS** — 22 cases, 0 mismatches, base-ISA + parser-op lock-step clean |

One subtlety surfaced and fixed here: the RTL MMIO slave returns the flow_keys frame as an
**8-aligned 64-bit word at the request offset** (`parser_mmio.h`: "read, 8-aligned `ld`"), so a
sub-word (byte) load lands on the wrong byte lane. Increment 1's `nic_ring.c` read the frame
byte-by-byte — tolerated by the byte-addressable Spike/QEMU models but wrong on the RTL peripheral;
the driver now reads aligned 64-bit words, mirroring `cosim_main.S` (correct on all three sims).

**Result:** the parser **re-arms and parses a multi-packet stream correctly in real RTL** through
the CVA6 core, provably safe under formal, with the functional (Spike/QEMU) and single-shot in-core
paths all still green. This retires the remaining Increment-2 hardware-path item; the RTL FU is no
longer one-shot.

#### Pre-purchase validation — consolidated verdict: **GO** (2026-09-20)

With D6 Increment 2 landed, every item of the A–D pre-purchase plan is complete. All of it is
reproducible from `flake.nix` (`nix run .#<target>`) on `hp5`, with **no board**.

| # | Item | Target | Result |
|---|---|---|---|
| A1 | Vivado license boundary on the 325T | `fpga-vivado-license-check` | **PASS** — free **Basic** does synth → place → route → `write_bitstream` on `xc7k325t`; no edu license needed |
| A2 | Turnkey CVA6 SoC + DDR3, die/flow/timing | `fpga-soc-vivado` (genesys2) | **PASS** — full impl on `xc7k325tffg900-2` **routes and closes timing** (core ~49.6k LUT / SoC 75,267 = 37%) |
| B3 | AX7325B 64-bit DDR3 pinout | `fpga-mig-check -- ax7325b` | **PASS** — MIG 7-series generates + OOC-synths clean; byte-lane/bank grouping legal |
| B4 | AX7325B CVA6 port builds + fits | `fpga-soc-vivado -- ax7325b` | **PASS** — synth 0 errors / 0 crit-warns; SoC 80,251 LUT ≈ 39% |
| C5 | 10G MAC datapath on the die | `fpga-10g-fit` | **PASS** — builds + OOC-routes + meets 156.25 MHz (WNS +2.081 ns); 1,489 LUT (0.7%) |
| D6·1 | Whole corpus == golden, functional sims | `cva6-parser-nic-cosim` | **PASS** — 306 pkts, one re-arming boot, on Spike **and** QEMU |
| D6·2 | RTL parser FU re-arms through the CVA6 core | `cva6-parser-rearm` (+ wrap-test / formal / cosim / tandem) | **PASS** — multi-packet run == golden in real RTL, proved safe under formal |

**Gateware + software risk is retired.** CVA6 + a 10G MAC co-reside (~40% LUT), the AX7325B port
builds/fits, the DDR3 pinout is legal, the flow+license close a real bitstream+timing on the exact
die, and the parser software/logic parses the real corpus == the golden model — functionally (Spike/
QEMU) and in cycle-accurate RTL through the core.

**Strictly board-in-hand residual** (cannot be done pre-buy, deferred to Phase 9): DDR3 calibration
on silicon; GTX/10GBASE-R PCS-PMA link-up + serdes SI to a real 10GE/QSFP NIC; real throughput &
latency; final on-hardware timing sign-off; the AX7325B `#VERIFY` pin sign-off (place/route on the
board); the physical back-to-back 2× AX7325B bring-up. **Recommendation: purchase the AX7325B.**

#### openXC7 flow — runtime & observations log (for re-run estimation)

Whole-flow CVA6-on-openXC7 is **long** and **memory-heavy** — the numbers below let a
re-run be planned rather than watched. Host: 61 GB RAM, run 2026-09-12; wall-clock and RSS
are the two things worth budgeting. Watch `build/fpga-m3-xilinx/synth.log`, not the process
(gotcha #12) — yosys sits in state `S` waiting on its `yosys-abc` child through all of ABC9.

| Phase | Wall-clock | Peak RSS | Notes / gotchas |
|---|---|---|---|
| **chipdb** (pypy3 `bbaexport.py` + `bbasm`) | ~minutes (one-off) | ~7 GB (transient) | `xc7k325tffg900.bin` is **460 MB**; cached in `build/fpga-m3-xilinx/chipdb/` and skipped on re-run (`rm` to force). Only the first run pays this. |
| **synth, pre-ABC** (`read_rtlil` elab.il → `synth_xilinx` coarse → `memory_bram` → DSP infer → XAIGER export) | **~1h21m** | ~a few GB | RAMB36E1 + DSP48E1 cells appear here — the memories map to block RAM and multipliers to DSP48 *before* LUT mapping. Ends with "Extracted **5.19M AND gates**, 26,429 inputs / 49,350 outputs" — that network size is what makes the next phase slow. |
| **ABC9** (LUT6 technology mapping, `4.46.17.5`) | **≈107 h (~4.5 days!)** — 09-12 10:36 → 09-16 22:18, the dominant cost by far | grew 0.9 → **~1.8 GB** (abc child) + **~32 GB** (parent yosys holding the design) | **Single-threaded** — pinned one core at ~100% the entire time (cumulative CPU ≈ wall, no I/O wait — real work, not hung). RSS crept slowly the whole run (still exploring mappings). More cores do not help, only clock speed does. The 5.19M-gate *flattened* AIG is why abc9 took days; `-flatten` on a whole RV64 core is close to worst-case input. |
| **write_json + stat** | ~2 min (right after ABC9) | — | `cva6_fit_top.json` is **679 MB**; counts in `cva6_fit_top.stat.txt`. |
| **nextpnr-xilinx** PnR | ~2 min, then **hard-failed placement** | — | `SLICE_LUTX 640,815/407,600 = 157%` → `ERROR: no Bels remaining` — the 12×-inflated LUT count doesn't fit; no route/Fmax. `pnr.log` is 202 MB (mostly negative-timing-budget spam). |

**Total wall-clock ≈ 4 days 13 hours** (yosys 09-12 09:15 → 09-16 22:18), ABC9 ≈ 107 h of it.

**Estimation + method takeaways for next time:** (1) **Do not repeat this exact flow for CVA6.**
`-flatten` + full `-abc9` on a whole RV64 core = ~108 CPU-hours single-threaded AND a ~12×-inflated
LUT count that fails PnR — the worst of both. (2) ABC9 dominates (~99% of wall); everything before
it is ~1.5 h. It is single-core, so pick the fastest-clocked host, not the most cores; keep ≥ 32 GB
free. (3) chipdb is a 460 MB one-off — don't delete it between runs. (4) **For a real LUT verdict,
use Vivado, not this flow** (see the result box above — the open ABC mapper doesn't use CARRY4
chains and over-reports LUTs ~12×). If the open flow is ever rerun, it is only a FF/DSP/BRAM check;
use `abc9 -fast` / drop `-flatten` (per-module mapping) to cut the runtime from days to hours.

## Challenges and how they were resolved

Every one of these cost real time. Symptom first, because that is how you will
meet them again.

| # | Symptom | Cause | Resolution |
|---|---|---|---|
| 1 | `set_device` rejects the board's part number | The **Education** Gowin edition's `device_info.csv` lists only `GW5AST-LV138PG484AC1/I0` — the 484-pin non-Pro package — with no `FPG676` order code at all | Use the **commercial** 1.9.12.03 tree. Sipeed's "commercial IDE 1.9.9+" requirement is correct; our docs had said otherwise |
| 2 | Tools still get "permission denied" after `nixos-rebuild switch` | udev does **not** retroactively apply rules to an already-attached device, **and** a shell that predates the switch keeps its old groups | `sudo udevadm trigger --action=add --subsystem-match=usb --attr-match=idVendor=0403` (or replug), then a fresh login or `sg plugdev -c '...'` |
| 3 | `.#fpga-detect` said `UNEXPECTED` although the board answered perfectly | openFPGALoader prints the IDCODE **without leading zeros** (`0x1081b`); our check string-matched `0001081b` | Compare **numerically** (`$((found)) -eq $((expected))`). A false negative on first hardware contact is exactly what sends you chasing cables |
| 4 | Our LED design looked identical to the board doing nothing | The board's **factory flash image also ping-pongs a dot**. We had chosen a pattern distinct from Sipeed's demo, but never from the board's *default* | Use a **changing sequence** of patterns. A signal that evolves needs no spatial comparison. Two hardware round trips lost to this |
| 5 | Sipeed's `led.fs` loaded but all LEDs stayed dark — looked like a failed load | Its top is `.rst_n(!rst)` with `rst` on U4 `PULL_MODE=UP`, so it sits in **permanent reset** unless you hold the button; LEDs being active-low, reset = all dark | All-off *is* the correct running state. Hold U4 to see it animate. The visible change is what proved SRAM programming works |
| 6 | A freshly loaded design vanished, board reverted to its flash image | `openFPGALoader --detect -f` begins with an **`Erase SRAM`** | Never probe the flash between loading a bitstream and looking at the board |
| 7 | No way to ask the part which bitstream it is running | Gowin has **no usercode readback**; `--read-register` is Xilinx-only | Distinguish revisions by **utilization counts** and the `.fs` header `CheckSum`. v1 62/39, v2 59/36, v3 45/33, sequencer 108/48 |
| 8 | First `.#fpga-build` on a machine appeared to hang for tens of minutes | It builds the whole microVM guest, including **QEMU from source** (`qemu-host-cpu-only-for-vm-tests`), before any Gowin work starts | Expect it once per machine. Watch `build/fpga-*/gowin.log`, not process names — see #12 |
| 9 | Expected the UART to need a 4× baud correction | Sipeed's FAQ documents a firmware bug where actual baud is 4× the configured one | **Not present** on firmware `2025030317`. 115200 reads 115200, 100% printable. `.#fpga-uart` scores candidate bauds rather than assuming either way |
| 10 | Verilator refused to build `uart_tx` | `baud_cnt` was 16-bit but `DIV` was a 32-bit localparam | Size the divider explicitly. Part-selecting an **identifier** (`DIV32[19:0]`) is the Verilog-2001-legal form; you cannot part-select an expression |
| 11 | Believed Gowin could not read our SystemVerilog at all | `add_file -type verilog` **forces** Verilog mode. Its own help: *"automatically judge the file's type by it extension name. This option can override it."* | `set_option -verilog_std sysv2017` (**not** `sysv_2017`) + `add_file` with **no** `-type`. Gowin then parses and compiles `parser_execute`. See #13 |
| 12 | Killed a healthy build after wrongly reporting the VM had booted | A monitor used `pgrep -f 'qemu-system-x86_64'`, which **matched its own command line** | Never key progress on process names that contain the pattern you are matching. Watch for artifacts the job actually produces (`gowin.log`, a `.fs`) |
| 14 | `WARN (EX2420) : Latch inferred` on `always_comb` temporaries (`src[63]`, then `camr[31]`, `ok`, `next_pos[1]` as each was fixed) | GowinSynthesis applies its whole-`always_comb` latch analysis to block-local **and** arm-local temporaries; any temp written on only some `case` paths and left undefaulted reads as a held latch (Verilator/formal are clean because it is never read off those paths — a false latch) | Default every such temp unconditionally in the defaults block, and hoist arm-local decls to the top (`rtl/parser_execute.sv`, `rtl/parser_decode.sv`). Behaviour-neutral; sim + formal stay green. **All parser latch warnings gone** — but it did **not** clear #13, which proved to be a separate, deeper bug |
| 18 | The yosys-flattened M1 built OK but used only 270 LUT / 138 FF and parsed an empty packet | Two yosys-bake bugs: (a) `$paramod$…`-mangled submodule names Gowin rejects; (b) the sim-only memory **zero-init loop before `$readmemh`** clobbers the file init, so every `prog_rom`/`mem`/`entry` cell baked to zero and `opt` then constant-folded the whole parser away | (a) `flatten` to one module; (b) guard the zero-init loops with `` `ifndef SYNTHESIS `` and run `sv2v --define=SYNTHESIS` (`rtl/parser_cam.sv`, `rtl/parser_pktbuf.sv`, `tb/parser_top.sv`). ROMs then bake correctly (53 words / 28 bytes / 13 CAM), utilization jumps to 2751 LUT, and the on-board `flow_keys` matches the model |
| 19 | sv2v aborts flattening `parser_top`: *"can't determine the type of `i[...]` because the inner type int can't be indexed"* | sv2v 0.0.13.1 cannot bit-slice an `int` loop variable (`i[META_OFF_W-1:0]` in the metadata scatter) | Use a sized cast `META_OFF_W'(i)` instead of a slice (`tb/parser_top.sv`). Identical for `i`∈0..7; Verilator-clean; sim stays 22/22 |

### Open challenges

| # | Problem | Status |
|---|---|---|
| 13 | GowinSynthesis floods `ERROR (SP00018) ... error bus name set` during synthesis of the parser RTL | **Open (worked around for M1).** *Not* the latches (#14) and *not* packed structs: it fires on `parser_execute` alone in SV after every latch was cleared, on the full M1 in SV, **and** on the full M1 as sv2v-flattened plain Verilog. Every module compiles first; the flood comes at elaboration with no actionable message — a GowinSynthesis V1.9.12.03 front-end bug on our parser logic, independent of the SV surface. Reproduce: `nix run .#fpga-build -- sv-probe`. **Workaround (M1):** sv2v → yosys `flatten` → Gowin (`nix run .#fpga-m1-rtl`) re-emits Verilog Gowin accepts. Still worth a real fix (a Gowin-version bump, or isolating the exact construct) before M3, since flatten hurts BSRAM inference at CVA6 scale |
| 15 | UART **RX** pin (host → FPGA) unknown | **Located, but the debug UART is fabric-TX-only** (2026-09-07). The schematic (`downloads/TANG_MEGA-138K_Pro-Dock-4071f_Schematics.pdf`, USB-JTAG&UART sheet) puts `DBG_UART.RX` on ball **N16**, via R95 (0 Ω) to the debugger's TX (`BL616_TX`); the debugger is a **BL616** MCU emulating the FT2232 the `0403:6010` reports. **But N16 is a dedicated CPU pin:** a loopback bitstream (`m2loop`) constraining `uart_rx` to N16 fails PnR with `ERROR (PR2017) ... the location is a dedicated pin (CPU)` — the debug UART's RX is wired to the hardened Andes CPU, not the fabric. The AE350 demo's U16/V16 "UART2" are `SDRAM_D0/D1` on the Pro, so not an alternative. **Resolved:** M2 uses an **external 3.3 V USB-UART adapter on PMOD2** — `uart_rx`=C21 (PMOD2_IO0), `uart_tx`=B20 (PMOD2_IO1), on its own `/dev/ttyUSB*`. Confirmed by a raw loopback (`m2loop`, 256/256 bytes) then the full injection suite (22/22). Recorded in the [board manual](fpga-bringup-tang-mega-138k-pro.md) pin map |
| 16 | **BRAM inference** for CVA6's SRAM macros onto Gowin BSRAM | **Open — root-caused 2026-09-09; fix proven, not yet wired in.** M3a S1 (sv2v → hierarchical yosys, no flatten) synthesized to completion but inferred **0 BSRAM**: `ERROR (RP0001)` 558,788 DFF > 139,140 (~4× over), ~543 Kbit of I$/D$ data+tag landed in flops. No `SP00018` (stock CVA6's front end is clean — #13 is parser-specific). **Cause:** the memory RTL is BSRAM-friendly and stays a `$mem_v2` inside yosys, but `write_verilog -noattr` lowers the byte-write-enable into **64 per-bit write conditionals** (`mem[a][n:n] <=`), which GowinSynthesis reads as an arbitrary per-bit write mask and cannot match to its BSRAM template → demoted to registers. The S1 flow runs **no** yosys BRAM mapping, so the whole decision falls on Gowin inference in the one form that defeats it. **Fix (proven end-to-end):** map memories in yosys — `synth_gowin -family gw5a -run :map_ffs` emits hard **`SPX9`** gw5a BSRAM primitives (a native Gowin cell, `prim_sim.v:1402`); no CVA6 patch needed. **Confirmed through GowinSynthesis V1.9.12.03 (2026-09-09):** `nix run .#fpga-build -- m3-ramtest` synthesizes the SPX9 netlist and its resource report shows **`BSRAM=2`, `REG=-` (0 registers), `LUT=13`** — the memory lands in block RAM, not flops. Both legs are reproducible nix targets (`nix run .#fpga-m3-core-rtl -- diag`; `-- m3-ramtest`). **S2 wired + emit-validated at scale (2026-09-10):** `scripts/fpga-m3-core-rtl.sh` s2 runs `synth_gowin`'s gw5a **coarse pass with `alumacc` removed** + `map_ram` (s1 kept as the 0-BSRAM FAIL for the record). Two `-run` stop points were tried and rejected first: `:map_ffs` inserts ~155k illegal internal IBUF/OBUF under `-noflatten`; `:map_gates` fast-failed the fit with `ERROR (EX3937): Instantiating unknown module '$macc_v2'` because `alumacc` fuses arithmetic into un-renderable `$alu`/`$macc_v2` macros. Removing `alumacc` (there is no clean inverse; full `techmap` over-lowers to gates) keeps `+`/`-`/`*` high-level for GowinSynthesis's own DSP inference. Emit-validated on the full core from the checkpoint: **4 SPX9, 0 `$alu`/`$macc`, 0 IBUF/OBUF, 0 residual `$mem`, 0 per-bit writes**, 139 modules. Full diagnosis + reproducer: [gowin-bsram-inference-debug.md](gowin-bsram-inference-debug.md). **1st full fit (2026-09-10): BSRAM inference SOLVED end-to-end** — the flake netlist (`nix run .#fpga-m3-core-rtl -- s2`) synthesized clean for ~6 h with **no EX3937, no SP00018**, and GowinSynthesis processed the 4 SPX9 as block RAM (`EX0346` `mem.0.x` `WRITE_MODE` notes) — vindicating the hard-map vs S1's 0-BSRAM. **But a new blocker surfaced:** gw_sh **aborted at `[75%] Tech-Mapping`** with an embedded-ABC assertion `If_CutAreaDerefed` (`ifCut.c:1109`, SIGABRT) — a numerical-robustness bug in GowinSynthesis V1.9.12.03's LUT-mapper, *not* a fit/overflow (no resource report reached). 2nd run with `set_option -retiming 0` (2026-09-10) **only delayed the identical crash** (Tech-Mapping Phase 0 took ~2h13m, then the same `If_CutAreaDerefed` abort ~76 min into phase-3 area recovery) — the ABC bug is robust to mapping-effort perturbation. **Two full ~6–7 h runs crash identically. Blocker escalated:** the remaining directions are (a) yosys-side decomposition of the big arithmetic cones (likely the 64×64 MUL + FPU mantissa mults; risk of LUT bloat, ~6–7 h/attempt), (b) a **GowinSynthesis version bump** (root-cause fix for the embedded-ABC defect; needs a newer Gowin EDA — ties to #13), or (c) the fallback ladder (premature — the blocker is a tool crash, not a fit failure; BSRAM + front end are proven). BSRAM inference itself is **SOLVED end-to-end**. **Crash root-caused + fixed, then the true wall revealed (2026-09-11):** the `If_CutAreaDerefed` abort was localized to `wt_dcache_wbuffer`'s fully-associative coalescing cone; reducing `CVA6ConfigWtDcacheWbufDepth` 8→2 (patch `nix/cva6-parser/m3a-wbuf-depth.patch`) **stopped the crash** — the full fit then ran all Tech-Mapping phases 0–4 to completion, no SIGABRT. But it overflowed: GowinSynthesis mapped the depth-2 core to **2,019,335 LUTs** (`RP0006`, 14.6× the 138,240-LUT device). An independent yosys reference on the same netlist (`synth_gowin -family gw5a` coarse, `-noflatten`) gives **≈645k LUT-equiv** (487,138 basic LUT + 158,396 MUX2_LUT), 8,754 ALU, 25,699 DFF, 72 SPX9 — **still 4.7× over even under the good mapper**. The FF and BSRAM budgets both fit; the wall is pure combinational **LUT area**. The FPU is **not** the lever — `fpu_wrap` flattens to only 26,843 LUT-equiv (~4%, 0 DSP), so `cv64a6_imac` saves ~5% of a core that is 470% over. **Verdict: RV64GC CVA6 cannot fit the GW5AST-138 by any mapping trick.** Fallback ladder triggered at the documented M3a gate → **pivot the host core to a Xilinx Kintex-7 board** (CVA6's turnkey reference platform). See [M3a — fit verdict](#m3a--fit-verdict-cva6-does-not-fit-the-gw5ast-138--pivot-to-xilinx). #16 (BSRAM) and #13 (parser-only SP00018) are both **moot for the Gowin host-core path** — they do not arise on Xilinx |
| 17 | **GAO** (Gowin's on-chip logic analyzer) is GUI-bound, our microVM is headless | **Open.** It captures hundreds of internal nets over JTAG — far beyond what LEDs or UART reach. Needs an X11 path into the VM. Until then, on-board debug is LEDs + UART |

## Conventions for updating this file

- **Append, don't rewrite.** The record of what went wrong is the point.
- Date entries, and cite evidence — a log line, a utilization number, a checksum.
- When a challenge produces a durable rule, put the *rule* in the
  [board manual](fpga-bringup-tang-mega-138k-pro.md) and leave the *story* here.
- Mark a milestone ✅ only for something actually observed, and say how it was
  observed. "Programmed successfully" and "seen working on the board" are
  different claims — #5 and #6 are why.
