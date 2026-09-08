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
| **M3** | Stock CVA6 on the FPGA | ⏳ Not started (BRAM inference is the risk) |
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
| 16 | **BRAM inference** for CVA6's SRAM macros onto Gowin BSRAM | **Open.** The known headline risk for M3; see [assessment §5a](fpga-platform-assessment.md). May be reduced or removed by #13 |
| 17 | **GAO** (Gowin's on-chip logic analyzer) is GUI-bound, our microVM is headless | **Open.** It captures hundreds of internal nets over JTAG — far beyond what LEDs or UART reach. Needs an X11 path into the VM. Until then, on-board debug is LEDs + UART |

## Conventions for updating this file

- **Append, don't rewrite.** The record of what went wrong is the point.
- Date entries, and cite evidence — a log line, a utilization number, a checksum.
- When a challenge produces a durable rule, put the *rule* in the
  [board manual](fpga-bringup-tang-mega-138k-pro.md) and leave the *story* here.
- Mark a milestone ✅ only for something actually observed, and say how it was
  observed. "Programmed successfully" and "seen working on the board" are
  different claims — #5 and #6 are why.
