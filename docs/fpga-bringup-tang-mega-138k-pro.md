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
| `uart_tx` | **P15** | FPGA → debugger. `DBG_UART.TX` → R128 (0 Ω) → `BL616_RX`. Confirmed by M0. |
| `uart_rx` | **N16** (unusable) | debugger → FPGA. `DBG_UART.RX` → R95 (0 Ω) → `BL616_TX`, but **N16 is a dedicated CPU pin** — GowinSynthesis PnR rejects it as fabric I/O (`PR2017 ... dedicated pin (CPU)`). So the debug UART is **fabric-TX-only**; the RX side is wired to the hardened Andes CPU, not the FPGA fabric. See M2 notes. |
| `rst` | U4 | active-high in `led/src/top.cst` |
| `rst_n` | K16 | active-low in `pro_ddr_test/src/pro.cst` — a **different** button |
| **M2 UART rx** | **C21** (PMOD2_IO0) | host → FPGA via an **external 3.3 V USB-TTL adapter** (the debug UART's RX is CPU-locked, above). Loopback-confirmed on the board 2026-09-07. |
| **M2 UART tx** | **B20** (PMOD2_IO1) | FPGA → host on the same adapter. |

> **External M2 UART — how to wire it.** The USB debug UART is transmit-only from
> fabric (N16 above), so host→FPGA injection uses a small 3.3 V USB-TTL serial adapter
> on **PMOD2**. The board silkscreens each PMOD pin with its FPGA **ball name**, so you
> wire by label, not pin number. **PMOD2 is the header at the top of the card, the one
> of the three closest to the DC power connector** (just left of `MIPI-CSI0`). Connect:
> adapter **TX → `C21`**, adapter **RX → `B20`**, adapter **GND → a `GND`** pin; leave
> **VCC/3V3 unconnected** and set the adapter's voltage switch to **3.3 V** (5 V or true
> RS-232 damages the FPGA). It enumerates as its own `/dev/ttyUSB*` (e.g. `ttyUSB2`).
> Confirm the link with `FPGA_UART=/dev/ttyUSB2 nix run .#fpga-m2-loopback-check` while
> the `m2loop` bitstream is loaded.

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
| **`add_file -type verilog` is Verilog, not SystemVerilog** | `logic` / `always_ff` are rejected in that mode. `add_file` *without* `-type` + `set_option -verilog_std sysv2017` makes GowinSynthesis *parse* SystemVerilog, but it then hits the `SP00018` bug below. Board designs stay Verilog-2001; the parser RTL reaches Gowin via sv2v→yosys |
| **`ERROR (SP00018) ... error bus name set`** on the parser RTL | A GowinSynthesis V1.9.12.03 front-end bug: it floods this on our parser logic in SystemVerilog **and** in sv2v-flattened Verilog, even on `parser_execute` alone. Workaround (M1): **sv2v → yosys `flatten` → Gowin** (`nix run .#fpga-m1-rtl`). See [phase-8-status.md](phase-8-status.md) #13 |
| **License looks for a server, not a file** | With no `gwlicense.ini` beside the binary, Gowin defaults to a license *server* and fails with "Connection timeout". The wrapper writes `[license] lic="/work/gowin"`. `LM_LICENSE_FILE` is **not** the hook — Gowin uses its own format, not FlexLM |
| **`gw_sh` needs a display** | It initialises a QApplication and aborts on the `xcb` plugin. `QT_QPA_PLATFORM=offscreen` |
| **sv2v output trips GowinSynthesis** | Raw `flat.v` fails on `$bits` (use the yosys-cleaned `flat_synth.v`); sv2v leaves `CVA6Cfg.{ASID_WIDTH,VMID_WIDTH,VpnLen,PtLevels}` as illegal dotted constants → substitute `16 / 14 / 27 / 3` |
| **yosys `flatten` needs `$paramod` names gone** | Gowin rejects yosys's `$paramod$…` module names; `flatten` to a single module before `write_verilog` |
| **A zero-init loop before `$readmemh` bakes an all-zero ROM under yosys** | yosys keeps the loop's zeros, not the file. Guard sim-only zero-init with `` `ifndef SYNTHESIS `` and run `sv2v --define=SYNTHESIS` (see `rtl/parser_cam.sv`, `rtl/parser_pktbuf.sv`, `tb/parser_top.sv`). `nix run .#fpga-m1-rtl` does this |
| **UART baud is 4x what you set** | A known debugger-firmware bug per the vendor FAQ. Relevant to the hello-world step, not to blinky |

## Deliverables / artifacts

- `nix run .#fpga-{detect,load,flash,build}` — the whole loop, from the flake.
- `.#gowin-eda-edu` / `.#gowin-eda` — the toolchain as store paths.
- `.#tang-mega-led-bitstream` — a hash-pinned known-good vendor bitstream.
- `fpga/tang-mega-138k-pro/` — our blinky, its constraints, and its Gowin script.
- This document, kept current.

## Exit criteria

All met for board bring-up as of 2026-09-07 — see
[phase-8-status.md](phase-8-status.md) for the evidence behind each.

## Status

Progress, measurements and the challenge log live in
**[phase-8-status.md](phase-8-status.md)** — this document is the board *manual*
(pin map, gotchas, how to run things) and deliberately does not churn.

## Open questions

- **UART RX pin — located but NOT fabric-usable** (2026-09-07). The board schematic
  (`downloads/TANG_MEGA-138K_Pro-Dock-4071f_Schematics.pdf`, USB-JTAG&UART sheet)
  shows `DBG_UART.RX` on ball **N16**, wired via R95 (0 Ω) to the debugger's TX
  (`BL616_TX`). The debugger is a **BL616** RISC-V MCU (it emulates the FT2232 the
  `0403:6010` VID/PID reports), interface B = the UART on `/dev/ttyUSB1`. **But N16 is
  a dedicated CPU pin:** a loopback bitstream constraining `uart_rx` to N16 fails PnR
  with `PR2017 ... the location is a dedicated pin (CPU)` (build `m2loop`, 2026-09-07).
  So the USB debug UART is **transmit-only from the FPGA fabric** — its RX is routed to
  the hardened Andes CPU, not the fabric. The AE350 demo's "UART2" pins (U16/V16) are
  **not** an alternative: on the Pro they are `SDRAM_D0/D1` (bank 2). Host→FPGA therefore
  needs one of: **JTAG injection** (user-JTAG register), an **external USB-UART dongle on
  a free PMOD pin**, or re-scoping M2 to a **ROM-baked whole-suite** run (no injection).
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

**Available:** hp5 has an **Intel X710 dual-port 10GbE SFP+** (`i40e`, fw 6.00),
**both cages populated**, plus two more optics spare and a **10GTek
CAB-ZSP/ZSP-P0.5M** passive SFP28 DAC (IEEE 802.3by / SFF-8402, 10–25G multi-rate,
so 10G-compatible; the board's transceivers top out at 12.5 Gbps, which covers
10.3125 Gbps and rules out 25G).

The installed optics, read with `sudo ethtool -m` (2026-09-07):

| Field | Value |
|---|---|
| Vendor / PN | **Intel Corp `AFBR-709DMZ-IN3`** rev G4.1 (Intel-coded Avago/Broadcom) |
| Type | **10GBASE-SR**, 850 nm multimode, LC duplex |
| Signalling | BR nominal **10300 MBd**, encoding **64B/66B** |
| Reach | OM3 300 m · OM2 80 m · OM1 30 m |
| Ports | `enp1s0f0np0` SN AA1824308S4 · `enp1s0f1np1` SN AD18233051C — identical PN/rev |
| DOM | **Supported** (Tx/Rx power, laser bias, temperature, voltage) |

> **`ethtool -m` mislabels these as "Transceiver type: Ethernet: 1000BASE-SX".**
> Ignore that line. It reports only one compliance code, but the raw
> `Transceiver codes : 0x10 0x00 0x00 0x01 ...` has **both** 10GBASE-SR (byte 3,
> `0x10`) and 1000BASE-SX (byte 6, `0x01`) — these are dual-rate modules with
> `RATE_SELECT implemented`. The `10300 MBd` nominal bit rate and 64B/66B encoding
> are the unambiguous tells that this is a 10G part.

**DOM is a real debugging asset** and worth using deliberately. With nothing
plugged in, both modules read Tx ≈ **−2.75 / −2.21 dBm** (healthy for SR) and Rx
≈ **−35 / −31 dBm** with `Laser rx power low warning: On` — i.e. transmitting
fine, receiving nothing, exactly as expected for dark fibre. Once a link is
attempted, `ethtool -m` distinguishes "no light arriving" (cabling, or the far end
not transmitting) from "light arriving but no link" (a PCS/encoding fault in our
RTL) — a distinction that is otherwise very hard to make from the FPGA side.

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

0. **Validate the test equipment first, with no FPGA involved.** Join the two X710
   ports to each other with an LC-LC multimode patch and confirm a 10G link comes
   up host-to-host. That proves the optics, the fibre and the NIC before any of
   them can be blamed on our RTL. Costs one cable and five minutes.
1. **Loopback, no NIC.** Tang SFP+ A ↔ Tang SFP+ B with the 0.5 m DAC — **no optics
   or fibre needed for this step**, which is why the DAC is the right tool here.
   Any failure is unambiguously ours. This is where the SerDes and its **156.25 MHz reference
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

## Demo and test options (sketch)

A rough plan, not a commitment — recorded so the shape of the endgame is agreed
before any of it is built. **Nothing here is close; UART hello world is next.**

### Why a transformation is the right demo

Sending packets hp5 → Tang → hp5 and counting them proves only that a datapath
exists. Having the Tang **modify a field it had to parse to find** is far stronger:
receiving the altered packet is direct evidence the parser located that header
correctly.

The critical qualifier: **the transformation must not be at a fixed byte offset.**
Rewriting byte 36 proves nothing. It is only a parser demo if it still lands
correctly across the corpus's header variation — VLAN and QinQ, IPv4 with options,
IPv6 with hop-by-hop / routing / fragment / dest-opts chains — where the UDP header
sits at a different offset in every case. That variation *is* the proof, and the
Phase-2 corpus already contains it.

### Transformation options

| # | What the Tang does | What it proves | Cost |
|---|---|---|---|
| 1 | **Pass-through**, unmodified | RX→TX datapath only. No parsing. | Lowest — but needs a full TX MAC |
| 2 | **Swap UDP src/dst ports** | Parser found the UDP header across varied encapsulation | + checksum handling |
| 3 | **Write a parse-derived value** into a field (e.g. a `flow_keys` hash into the UDP source port) | The *whole* parse, not just header location | + checksum handling |
| 4 | **Return a metadata frame** whose payload is the `flow_keys` struct | Everything, byte-for-byte, against the existing oracle | No checksum problem at all |
| 5 | **Classify and drop/forward** (e.g. forward only IPv4/TCP) | Parse + decision, and is trivially visible | Low |

**Recommendation: build 4 first, demo 2 or 3.** Option 4 is the rigorous one —
hp5 compares the returned `flow_keys` against `libparsermodel` for the same input,
which is *exactly* the Phase-6 comparison with Ethernet swapped in for Verilator
DPI. Same oracle, same corpus, same pass criteria, and no new correctness argument
to make. Options 2 and 3 are the better *demo*, and are cheap once 4 works.

> **Checksums are the trap.** Changing a UDP port invalidates the UDP checksum
> (and touching IP fields invalidates the IPv4 header checksum), so a naive
> rewrite produces frames the receiver silently discards — which looks exactly
> like "the parser didn't work". Three ways out: (a) **incremental update**
> (RFC 1624) — cheap in hardware, and itself good evidence we understood the
> packet; (b) **zero the UDP checksum** — legal in IPv4, **illegal in IPv6**;
> (c) **disable rx checksum validation on hp5** (`ethtool -K rx off`, or capture
> with `AF_PACKET` before the stack checks). Prefer (a) for the demo, (c) while
> bringing it up.

### Test ladder

Each rung is independently verifiable, and failures stay attributable:

| | Test | Transport | Oracle |
|---|---|---|---|
| A | Packets injected over **UART/JTAG**, `flow_keys` read back | no Ethernet at all | `libparsermodel` |
| B | FPGA transmits to **itself** (Tang A ↔ Tang B, DAC) | SerDes/PCS only | frame integrity |
| C | hp5 → Tang → hp5, **pass-through** | full wire path | byte-identical echo |
| D | hp5 → Tang → hp5, **`flow_keys` metadata frame** | wire path + parser | `libparsermodel` |
| E | hp5 → Tang → hp5, **transformed packet** | the demo | expected transform |
| F | **Rate + cycles/packet** | benchmark | Phase 9 |

**A comes before any Ethernet work** and is the natural successor to UART hello
world: it exercises the parser on real silicon with the MAC entirely out of the
picture, so a mismatch is unambiguously the parser's.

### Tooling on hp5

- **Generate:** `scapy` (already in the dev shell) for correctness work;
  `tcpreplay` to replay the pinned xdp2 `proto_audit` corpus; a
  pktgen/DPDK-class generator only for rung F.
- **Capture and verify:** `tcpdump` / `AF_PACKET`, diffed against
  `libparsermodel` run over the same input — the identical oracle used in
  simulation, which is the point.
- **Two ports, one machine:** hp5 both generates and verifies, so the loop closes
  without a second host or manual comparison.
- hp5 will likely need **promiscuous mode** (or the Tang must write a dst MAC hp5
  accepts) for returned frames to reach userspace.

### An architectural fork to decide later

Two very different designs can carry this demo:

1. **CVA6 + parser unit, software-driven** — frames land in the packet buffer, the
   core runs the Phase-7 slice program. This is the project's actual thesis
   (CPU-in-the-datapath), and the only version that measures **cycles/packet**, the
   headline metric. Throughput is modest by construction.
2. **Parser unit as a standalone streaming block**, no CPU. Much faster, and a
   flashier line-rate demo — but it demonstrates a fixed-function parser, *not* an
   ISA extension, so it does not support the thesis.

**Take (1).** The demo is about correctness and cycles/packet, not saturating the
link — a ~100 MHz CVA6 cannot parse 64 B frames at 10G line rate (14.88 Mpps) and
is comfortable near 1500 B (~820 Kpps). The value of a real 10G link is a genuine
datapath to measure *against* wire rate, not to fill it.

## What comes next

**Rung A of the packet ladder: inject a frame over UART/JTAG, read the `flow_keys`
back**, and diff against `libparsermodel`. No Ethernet, no MAC, no SerDes — so any
mismatch is unambiguously the parser's. The UART transport that this needs now
exists and is verified. See [Demo and test options](#demo-and-test-options-sketch).

Two things still open before that:

- **The USB debug UART is fabric-TX-only.** Its RX net is on N16 (schematic), but N16
  is a dedicated CPU pin the FPGA fabric cannot use (see the pin map and Open questions
  above). So host→FPGA over `/dev/ttyUSB1` is not available to our fabric design. The
  return path M2 needs is therefore one of: JTAG injection (user-JTAG register over the
  ttyUSB0 side), an external USB-UART dongle wired to a free PMOD pin, or re-scoping M2
  to run the whole 22-case suite from on-chip ROM (no host injection at all).
- **A bigger design.** `hello_top` is 197 LUT. CVA6 plus the parser is four orders
  of magnitude larger, and the known blocker is BRAM inference — mapping CVA6's
  SRAM macros onto Gowin BSRAM (see
  [fpga-platform-assessment.md](fpga-platform-assessment.md) §5a).

### Older notes

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
