# Tang Mega 138K Pro — board bring-up

← [Phase 8](phase-8-fpga.md) · [Docs index](README.md) · [Gowin microVM](gowin-microvm.md)

**This is the standing reference for how to use this FPGA.** It is a *living*
document: each step below records what actually happened, not what should happen.
When something does not work, the finding goes in the [status table](#status)
rather than being fixed silently.

## Objective

Prove the board end to end — talk to it, program it, and run **our own** RTL on it
— and leave behind a repeatable `edit → synth → program → observe` loop. This is
the foundation the rest of [Phase 8](phase-8-fpga.md) stands on.

Scope ends at a **blinky we built ourselves**. UART hello world is the next step
and is deliberately not covered here yet.

## Inputs / prerequisites

- Board powered from its 12 V supply, power switch on.
- USB cable in the **USB JTAG&UART** port. (The second, "SOFT-USB", port is driven
  by the FPGA fabric — see [Two USB ports](#two-usb-ports).)
- The node-locked Gowin license at `./gowin` (gitignored).
- `nix/gowin/local.nix` (gitignored) — see [Gowin EDA](#gowin-eda-in-the-microvm).

## The board

**Gowin `GW5AST-LV138FPG676AC1/I0`** (Arora V, 22 nm, LUT4 architecture):
138,240 LUT4, 138,240 FF, 6,120 Kbit BSRAM (340 blocks), 298 18x18 multipliers,
12 PLLs, 8 transceivers (270 Mbps–12.5 Gbps), a PCIe 3.0 hard core, and a hardened
Andes A25 / AE350 RISC-V SoC. Board: 1 GB DDR3 (2x512 MB @1333), 2x SFP+, RJ45
GbE, 2x DVI/HDMI in + out, PCIe slot, SD card, 3x PMOD, 128 Mbit x2 SPI flash.

### Pin map

Transcribed from Sipeed's own `led/src/top.cst` and `pro_ddr_test/src/pro.cst` in
the **pinned** vendor examples (`nix build .#tang-mega-examples`). Everything here
is a **3.3 V** bank — the wiki is emphatic that overvoltage permanently damages
the part.

| Signal | Pin | Notes |
|---|---|---|
| `clk` | **P16** | **50 MHz** (vendor `led.v` divides by `50000000`) |
| `led[5:0]` | **N23, N21, M25, L20, R26, J14** | **Active low** (`assign led = ~led_reg`) |
| `uart_tx` | **P15** | FPGA → debugger. RX pin **TBD** — not in any example we have |
| `rst` | U4 | active-high in `led/src/top.cst` |
| `rst_n` | K16 | active-low in `pro_ddr_test/src/pro.cst` — a **different** button |

> **Correction to the vendor wiki.** Its peripheral table lists the user LEDs as
> "6x WS2812 addressable RGB". They are not — they are six plain GPIO pins, one
> per LED, as the constraint files show. A WS2812 chain would have made blinky a
> serial-protocol exercise; it is not.

> **Unresolved: which button is reset.** The two vendor examples disagree on both
> pin and polarity. `blinky_top.v` sidesteps this by having no reset input at all.
> Settle it empirically when a design needs a button.

### Two USB ports

There are two USB connectors and they are not interchangeable.

**USB JTAG&UART** — one FTDI-compatible device, `0403:6010`, presenting *two*
interfaces off the same cable:

```
0403:6010  "SIPEED USB Debugger"   serial 2025030317
  ├── interface A → /dev/ttyUSB0 → JTAG   (openFPGALoader claims this via libftdi)
  └── interface B → /dev/ttyUSB1 → UART   (serial console)
```

Prefer the stable paths, which survive renumbering:
`/dev/serial/by-id/usb-SIPEED_USB_Debugger_<serial>-if00-port0` (JTAG) and
`-if01-port0` (UART).

It is **not a real FTDI part**: it is a Bouffalo **BL616 emulating an FT2232D**
(`bcdDevice 5.00`, and the "serial number" is a date-coded firmware version). So
MPSSE is a firmware emulation — if JTAG is flaky, lower the clock (`FPGA_FREQ=1M`)
before suspecting the hardware.

**SOFT-USB** — wired to FPGA fabric, not to a controller, and it cannot power the
board. It **will not enumerate at all** until a design implementing a USB2 soft
PHY is loaded (see the vendor `usb2_soft` example). A dark SOFT-USB port on a
freshly powered board is expected, not a fault.

## Design detail

### Host access (hp5)

`hp5` is the machine cabled to the board, so it owns the permissions. Configured
by **`~/nixos/hp/hp5/fpga.nix`**:

- creates the `plugdev` group (NixOS has none by default),
- adds `das` to `dialout` (the ttyUSB nodes) and `plugdev` (the raw USB node),
- installs udev rules for `0403:6010` — nixpkgs' `openfpgaloader` package ships
  none, so they are written out explicitly.

The rules set **both** `GROUP=` and `TAG+="uaccess"` on purpose: `uaccess` only
grants access to a user with an active *local* seat, and this box is normally
driven over SSH, where only the group membership works.

> **hp5's MAC address does not need changing.** The Gowin license is node-locked
> to `HOST_ID = E04F43E628EF`, but that is checked against the NIC of the **microVM**
> that runs Gowin, not the host: `nix/gowin-vm.nix` presents it on a QEMU user-mode
> interface, and `nix/gowin/local.nix` already carries the colon form. The license
> therefore works on any host. Do not touch host networking for this.

After `sudo nixos-rebuild switch` you must **replug the board** (udev applies rules
on the next add event) and start a new login session (for the group membership).

### Gowin EDA, in the microVM

Bitstreams for this part can only come from **Gowin EDA**.
[`fpga-platform-assessment.md`](fpga-platform-assessment.md) §4 established that
the open-source flow (yosys → nextpnr-himbaechel-gowin → Apicula) has no usable
GW5AST-138 support, so nextpnr and Apicula are deliberately **absent** from the
flake. openFPGALoader is still used — it programs a Gowin-produced `.fs` happily.

Gowin runs inside the licensed microVM ([`gowin-microvm.md`](gowin-microvm.md)).
The toolchain itself is now a derivation rather than a hand-extracted directory:

```
nix build .#gowin-eda         # V1.9.12.03 commercial  <-- USE THIS
nix build .#gowin-eda-edu     # V1.9.11.03 Education   (cannot target this board)
```

> **You need the commercial edition.** Education 1.9.11.03's
> `data/device/device_info.csv` lists only `GW5AST-LV138PG484AC1/I0` — the 484-pin
> **non-Pro** package — and contains no `FPG676` order code, so `set_device
> GW5AST-LV138FPG676AC1/I0` has nothing to resolve. (Confusingly it *does* ship the
> Pro's pin data at `data/device/GW5AST-138B/FCPBGA676A.json`; only the order-code
> index is missing.) Commercial 1.9.12.03 carries the part as row
> `gw5ast138b-007`. Sipeed's "138K Pro needs the commercial IDE 1.9.9+" is correct.

Both use `requireFile`, so the first build prints the one command to run per
machine:

```
nix-store --add-fixed sha256 downloads/Gowin_V1.9.12.03_linux.tar.gz
```

Then point `gowinInstall` in `nix/gowin/local.nix` at the resulting store path.

### The programmer

`nix run .#fpga-*` wraps **openFPGALoader**, from nixpkgs (**1.1.1**, released
2026-03-11). That release is new enough for this board on three counts: the
`tangmega138k` board entry (2023-10), the `GW5AST-138` IDCODE `0x0001081b`
(`src/part.hpp`), and the Arora-V fix `ab8d8fc` "fix SRAM erase/load when flash is
blank and timeout bit is set" (2025-03-06).

Verified on this machine (2026-09-07), before any board contact:

```
$ openFPGALoader --list-boards | grep tangmega
tangmega138k               ft2232             Undefined
$ openFPGALoader --list-fpga | grep GW5AST
0x0001081b  Gowin         GW5AST          GW5AST-138
```

Our fork (`randomizedcoder/openFPGALoader`, master `f6a678b`) is pinned as a flake
input and builds as `.#openfpgaloader-fork` — it reports the same `--list-boards`
entry, so there is currently **no reason to prefer it**. It is **not** the default
and **not** in the dev shell.
Swap it in for one run when chasing a suspected programmer bug:

```
OPENFPGALOADER=$(nix build --no-link --print-out-paths .#openfpgaloader-fork)/bin/openFPGALoader \
  nix run .#fpga-detect
```

## Step-by-step tasks

Each step gates the next. Do not advance past a red one.

### 0. Host access

```
sudo nixos-rebuild switch --flake ~/nixos/hp/hp5#hp5

# Apply the new rules to the ALREADY-attached board (or just replug it):
sudo udevadm trigger --action=add --subsystem-match=usb --attr-match=idVendor=0403

# The node must now be group plugdev, not root:
ls -l /dev/bus/usb/001/$(lsusb | awk '/0403:6010/{print $4}' | tr -d :)
#   crw-rw---- 1 root plugdev ...
```

Then use a **fresh login**, or prefix commands with `sg plugdev -c '...'` in an
existing one. Both are needed; see [the two steps](#the-two-steps-nobody-remembers).

### 1. Detect — first hardware contact

```
nix run .#fpga-detect
```

Expect IDCODE **`0x0001081b`** → Gowin GW5AST GW5AST-138, IR length 8. This one
command proves permissions, cable selection, MPSSE, and the part all at once.

When it fails, work the suspects in this order:

1. **Permissions** — by far the most likely. Re-check step 0, including the replug.
2. **`ftdi_sio` holding interface A.** libftdi auto-detaches given write access to
   the USB node; without it, nothing else matters.
3. **MPSSE clock** — it is an emulated FT2232D. `FPGA_FREQ=1M nix run .#fpga-detect`.
4. **Debugger firmware** — last resort. Ours is `2025030317` (Mar 2025), which is
   recent, and Sipeed's own "update the debugger" wiki page is literally **TBD**.

### 2. Program a vendor bitstream to SRAM

```
nix run .#fpga-load -- "$(nix build --no-link --print-out-paths .#tang-mega-led-bitstream)/led.fs"
```

Sipeed's prebuilt demo, pinned by hash. Because *we did not build it*, this
separates "our programming path works" from "our RTL works". Six LEDs fill
progressively. Volatile — gone on power cycle.

### 3. Program to SPI flash

```
nix run .#fpga-flash -- "$(nix build --no-link --print-out-paths .#tang-mega-led-bitstream)/led.fs"
```

Power-cycle; the design should return unaided. This is where the Arora-V
erase/load quirk lives, so it is the step most likely to want the fork.

### 4. Build and run our own blinky

```
nix run .#fpga-build
nix run .#fpga-load -- build/fpga-blinky/impl/pnr
```

> **The first `.#fpga-build` on a machine takes a long time and looks like a hang.**
> It builds the whole microVM guest — a NixOS system closure, an initrd, and then
> **QEMU from source** (`qemu-host-cpu-only-for-vm-tests`, not a cache hit) — before
> any Gowin work starts. Expect tens of minutes with no Gowin output at all. Do not
> judge progress by whether a `qemu-system-*` process exists yet; watch the console
> log, or `build/fpga-blinky/gowin.log`, which the guest creates as soon as the
> `gowin-gate` service reaches the Tcl run. Subsequent runs reuse the store and are
> fast.

Six patterns, ~3.75 s each, looping forever: **all-flash → walk up → ping-pong →
filling bar → odd/even → two dots converging**.

> **Pick a signal the board cannot already produce.** This took four attempts and
> two wasted hardware round trips (2026-09-07):
>
> 1. **A dot ping-ponging across all six LEDs.** Chosen because it looks nothing
>    like Sipeed's `led.fs` (a filling bar). But **the board's factory image in SPI
>    flash also ping-pongs**, so "our design is running" was indistinguishable from
>    "the board was power-cycled". The comparison that mattered was against the
>    board's *default*, not against some other design.
> 2. **A dot over alternate LEDs (0, 2, 4).** Still reads as a ping-pong to the
>    eye — and the LEDs are **not in index order physically** (`led[0]`=J14,
>    `led[1]`=R26, `led[2]`=L20, `led[3]`=M25, `led[4]`=N21, `led[5]`=N23), so
>    "every second index" need not be evenly spaced on the PCB.
> 3. **All six in unison.** Unmistakable, and confirmed on the board.
> 4. **A cycling SEQUENCE** — what the design ships as, and the genuinely robust
>    answer. The factory image ping-pongs forever and `led.fs` fills a bar forever,
>    but **neither ever changes to something else**. A signal that *changes* needs
>    no careful spatial comparison at all.
>
> The lesson generalises past LEDs: a bring-up signal must be distinguishable from
> *the board doing nothing*, which is not the same as differing from some other
> design — and a signal that evolves over time beats a static one that merely
> differs.

Then close the loop: change `TICK_DIV` in
[`fpga/tang-mega-138k-pro/src/blinky_top.v`](../fpga/tang-mega-138k-pro/src/blinky_top.v),
rebuild, reload, and confirm the speed changes. **That round trip is the actual
deliverable.**

## Host-access gotchas

### The two steps nobody remembers

`sudo nixos-rebuild switch` alone is **not enough**, and this cost real time:

1. **udev does not retroactively apply rules to an already-attached device.**
   After the switch, the USB node kept its original `root root 0644` from when the
   board was first plugged in. Either replug, or re-trigger without walking to the
   board:

   ```
   sudo udevadm trigger --action=add --subsystem-match=usb --attr-match=idVendor=0403
   ```

   It should then read `crw-rw---- root plugdev` — that is the check that matters.

2. **A running shell keeps the groups it started with.** Any session that predates
   the switch still lacks `plugdev`, so tools fail with a permission error even
   though `getent group plugdev` lists you. A fresh login fixes it; so does
   `sg plugdev -c '<command>'` without logging out, since `sg` reads `/etc/group`
   live.

## Programming gotchas

- **`--detect -f` ERASES SRAM.** Probing for the SPI flash starts with an
  `Erase SRAM`, so it wipes whatever design you just loaded and the FPGA falls
  back to its flash image. Do not run it "just to check" between loading a
  bitstream and looking at the board — that alone can make a working load look
  like a failed one. (It does report the flash usefully: `JEDEC ID: 0xef4018`,
  `Winbond W25Q128, 256 sectors, 128 Mb`.)
- **There is no usercode readback on Gowin.** `--read-register` is Xilinx-only, so
  you cannot ask the part which bitstream it is running. Distinguish revisions by
  their utilization numbers and `.fs` header `CheckSum` instead.

## Gowin gotchas

Every one of these has already cost time. Collected here so they cost it once.

| Gotcha | What to do |
|---|---|
| **`set_device` rejects the marketing name** | `GW5AST-LV138FPG676A` fails; the DB keys the grade-suffixed order code `GW5AST-LV138FPG676AC1/I0`. Reuse the candidate loop in `blinky.tcl` / `device-check.tcl` |
| **`add_file -type verilog` is Verilog, not SystemVerilog** | `logic` / `always_ff` are rejected. Board designs are Verilog-2001; the parser RTL reaches Gowin via sv2v |
| **License looks for a server, not a file** | With no `gwlicense.ini` beside the binary, Gowin defaults to a license *server* and fails with "Connection timeout". The wrapper writes `[license] lic="/work/gowin"`. `LM_LICENSE_FILE` is **not** the hook — Gowin uses its own format, not FlexLM |
| **`gw_sh` needs a display** | It initialises a QApplication and aborts on the `xcb` plugin. `QT_QPA_PLATFORM=offscreen` |
| **sv2v output trips GowinSynthesis** | Raw `flat.v` fails on `$bits` (use the yosys-cleaned `flat_synth.v`); sv2v leaves `CVA6Cfg.{ASID_WIDTH,VMID_WIDTH,VpnLen,PtLevels}` as illegal dotted constants → substitute `16 / 14 / 27 / 3` |
| **UART baud is 4x what you set** | A known debugger-firmware bug per the vendor FAQ. Relevant to the hello-world step, not to blinky |

## Deliverables / artifacts

- `nix run .#fpga-{detect,load,flash,build}` — the whole loop, from the flake.
- `.#gowin-eda-edu` / `.#gowin-eda` — the toolchain as store paths.
- `.#tang-mega-led-bitstream` — a hash-pinned known-good vendor bitstream.
- `fpga/tang-mega-138k-pro/` — our blinky, its constraints, and its Gowin script.
- This document, kept current.

## Exit criteria

- [x] `das` reaches the JTAG node without `sudo` (✅). UART untested — next step.
- [x] `.#fpga-detect` reports IDCODE `0x0001081b` (✅).
- [x] A vendor bitstream runs from SRAM (✅). Flash + power cycle: not yet run.
- [x] Our own `.v` → our own `.fs` → **LEDs visibly driven by our design** (✅).
- [x] Editing `TICK_DIV` visibly changes the board's behaviour (✅).
- [x] Utilization and timing reports captured from `impl/` (✅ see above).

## Status

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

## Open questions

- **UART RX pin.** `uart_tx` is P15; no vendor example we have drives RX. Needed
  for the hello-world step. **TBD** — likely needs the board schematic.
- **Which reset button.** U4 (active-high) vs K16 (active-low). **TBD.**
- **GAO** (Gowin Analyzer Oscilloscope, the on-chip logic analyzer) is the real
  hardware debugger for this part, but it is GUI-bound (`gw_ide`) and our microVM
  is headless. Using it needs an X11 path into the VM — **not attempted**. Until
  then, on-board debugging means LEDs and (soon) UART.
- **Programming the hardened Andes A25** is untouched, as is OpenOCD/GDB over JTAG
  for a fabric CVA6.

## The 10 GbE test harness (hardware on hand)

Not built yet, but the hardware exists, which de-risks the Phase-9 endgame. Recorded
here so the topology and its ordering are not re-derived later.

**Available:** hp5 has an **Intel X710 dual-port 10GbE SFP+** (`i40e`, fw 6.00) —
one cage appears already populated with a 10GBASE-SR optic (its `ethtool` link
modes are narrowed to `1000baseX` + `10000baseSR`, while the empty port advertises
the NIC's full `10000baseT/SR/LR` set). Plus 4× Intel optics and a **10GTek
CAB-ZSP/ZSP-P0.5M** passive SFP28 DAC (IEEE 802.3by / SFF-8402, 10–25G multi-rate,
so 10G-compatible; the board's transceivers top out at 12.5 Gbps, which covers
10.3125 Gbps and rules out 25G).

**Target topology — DUT in the middle**, so one machine both generates and verifies:

```
  hp5 port0 ──fibre──► Tang SFP+ A        traffic in
                          │
                    CVA6 + parser unit     parse -> flow_keys
                          │
  hp5 port1 ◄──fibre──  Tang SFP+ B        results / forwarded frames out
```

The oracle is unchanged from simulation: compare against `libparsermodel` over the
same corpus. Only the transport differs (Verilator DPI → Ethernet).

**Bring it up in this order.** Each link costs a full 10G PCS/MAC in fabric, so
two links doubles the work before anything is proven:

1. **Loopback, no NIC.** Tang SFP+ A ↔ Tang SFP+ B with the 0.5 m DAC. Any failure
   is unambiguously ours. This is where the SerDes and its **156.25 MHz reference
   clock** get sorted — on this board the refclk comes from two onboard **MS5351**
   programmable clock generators, themselves configured over UART. Start from
   Sipeed's `sfp+` example (10GbE UDP, marked verified).
2. **One link to hp5.** Proves interop with a real MAC and real frames.
3. **Both links.** The topology above, for the Phase-9 benchmark.

**Module compatibility notes.** The FPGA never reads a module's vendor EEPROM — it
just drives the SerDes — so anything fits the Tang side. The risk is Intel-side
only: Intel NICs have historically rejected third-party optics (the strict
whitelist and `allow_unsupported_sfp` belong to the older X520/`ixgbe`; X710 is
generally permissive with passive DACs). **Intel optics in the X710 sidesteps this
entirely**, so the optics are the lower-risk choice there and the DAC is best used
for the board-to-board loopback in step 1. Optics also need **LC-LC multimode
(OM3/OM4) patch cables**, which a DAC does not — a DAC is one integrated assembly.

**Expectation setting.** A ~100 MHz CVA6 cannot parse 64 B frames at 10G line rate
(14.88 Mpps); it is comfortable near 1500 B (~820 Kpps) — see
[fpga-platform-assessment.md](fpga-platform-assessment.md). The link exists to give
the parser a *real* datapath to be measured against wire rate, not to saturate it.

## What comes next

**UART hello world** — the other half of
[`phase-8-fpga.md`](phase-8-fpga.md) §8.4 step 1: a design that prints over
`uart_tx` (P15) at a known baud, read on `/dev/ttyUSB1`. Watch for the 4x-baud
firmware bug noted above. After that, the minimal CVA6 + BRAM + UART SoC, whose
known blocker is BRAM inference — mapping CVA6's SRAM macros onto Gowin BSRAM
(see [`fpga-platform-assessment.md`](fpga-platform-assessment.md) §5a).

## References

- [Sipeed Tang Mega 138K Pro wiki](https://wiki.sipeed.com/hardware/en/tang/tang-mega-138k/mega-138k-pro.html)
- [sipeed/TangMega-138KPro-example](https://github.com/sipeed/TangMega-138KPro-example) — pinned as `.#tang-mega-examples`
- [openFPGALoader](https://github.com/trabucayre/openFPGALoader) — our fork is pinned as a flake input
- [`gowin-microvm.md`](gowin-microvm.md) · [`fpga-platform-assessment.md`](fpga-platform-assessment.md) · [`phase-8-fpga.md`](phase-8-fpga.md)
