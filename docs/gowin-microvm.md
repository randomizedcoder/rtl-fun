# Gowin EDA feasibility microVM

**Purpose.** Answer the one gating pre-purchase question for the Sipeed Tang Mega 138K Pro
(Gowin **GW5AST-LV138FPG676A**): *does the obtained Education / NODELOCK Gowin license actually
permit synthesis + place-and-route for the GW5AST-138 part?* If yes, also capture real
utilization + Fmax for the CVA6 host core — all in software, **with no board attached**.

This is the ⚠️ open item from [fpga-platform-assessment.md](./fpga-platform-assessment.md) §4, and
the Experiment-1 step in [tang-mega-138k-pro-rtl-fun-plan.md](./tang-mega-138k-pro-rtl-fun-plan.md).

## Why a VM (and a specific MAC)

The Gowin license is **node-locked** to a MAC address (`HOST_ID` in the `./gowin` license file).
Gowin's licensing reads the MAC off a network interface and checks it against `HOST_ID`. Rather
than rebind the host's real NIC, a throwaway [microvm.nix](https://github.com/microvm-nix/microvm.nix)
guest presents *exactly* the licensed MAC on a QEMU user-mode interface — isolated, reproducible,
and it touches nothing on the host. The whole synth/PnR/timing flow runs in software, so the gate
is answerable before spending a cent on hardware.

`gw_sh` (the Gowin Tcl CLI) is a prebuilt x86-64 binary; its Gowin/Qt libraries are self-contained
via an rpath, and the guest's `programs.nix-ld` supplies the handful of extra system libs it needs
(zlib, libGL, the X11 client set, expat, fontconfig, NSS/NSPR — mostly dormant Qt5WebEngine
drag-ins for the headless CLI).

## Files

| File | Role |
|---|---|
| `nix/gowin-vm.nix` | The NixOS microVM (all VM logic; `flake.nix` just imports it) |
| `nix/gowin/local.example.nix` | Template for machine-local settings (committed) |
| `nix/gowin/local.nix` | **Gitignored** — the real MAC + host paths |
| `nix/gowin/blinky.v` | Tiny Verilog-2001 design-under-test for the Tier-1 gate |
| `nix/gowin/device-check.tcl` | **Tier-1** — license/device gate (GO / NO-GO) |
| `nix/gowin/cva6-util.tcl` | **Tier-2** — CVA6 utilization + Fmax (netlist/top via `CVA6_NETLIST`/`CVA6_TOP`) |

Nothing personal is committed: the licensed MAC and host paths live only in the gitignored
`nix/gowin/local.nix`, and the license file `./gowin` and installer blobs under `/downloads/` are
gitignored too. `flake.nix` reads the local config **impurely** (see below), so a pure `nix flake
check` on any other machine falls back to `local.example.nix` and still evaluates.

## One-time setup

1. Extract the Gowin EDA install somewhere on the host (the dir containing `IDE/bin/gw_sh`).
2. Create `nix/gowin/local.nix` from the template:

   ```nix
   {
     mac          = "AA:BB:CC:DD:EE:FF";   # your license HOST_ID, colon form (placeholder)
     gowinInstall = "/home/you/gowin-eda";  # dir containing IDE/bin/gw_sh
     repoRoot     = "/home/you/rtl-fun";     # this checkout (shared into the guest at /work)
   }
   ```

3. Keep the node-locked license file at the repo root as `./gowin` (already gitignored).

## Run

Because the machine-local config is not in git, the VM is built with `--impure` and the config
path in `$GOWIN_VM_LOCAL`:

```bash
GOWIN_VM_LOCAL="$PWD/nix/gowin/local.nix" nix run --impure .#gowin-vm
```

That boots the guest to a **root serial console**. Inside the guest the repo is at `/work`, the
Gowin install at `/opt/gowin`, and `gowin-check <script.tcl>` runs `gw_sh` fully set up: it writes
a node-locked `gwlicense.ini` (`lic="/work/gowin"`) next to the binary, sets `GOWIN_HOME` and
`QT_QPA_PLATFORM=offscreen` (headless Qt), then runs the script.

### Tier-1 — the license/device gate (the real deliverable)

```sh
mkdir -p /work/build/gowin && cd /work/build/gowin
gowin-check /work/nix/gowin/device-check.tcl
```

- `run syn` **and** `run pnr` complete for `GW5AST-LV138FPG676A` → **GO** (the license permits the
  part).
- A license / "feature not found" / device error → **NO-GO** (decisive: don't buy the board for
  this flow, or obtain a commercial license).

> The exact `set_device -name … / -device_version` spelling for the 138 part may need adjusting on
> the first interactive run (the device data ships as `GW5AST-138B` and `GW5AST-138C`). The script
> reports precisely where it stops so the spelling can be pinned.

### Tier-2 — CVA6 utilization + Fmax (only if Tier-1 is GO)

> Note: the pinned CVA6 v5.3.0 ships **no 64-bit no-FPU (`cv64a6_imac`) config** — only
> `cv64a6_imafdc_sv39` (with FPU) and 32-bit `cv32a6_imac_*`. Tier-2 therefore ran the **existing
> with-FPU flatten** (`build/fpga-eval/flat_synth.v`, the yosys-cleaned variant — the raw `flat.v`
> is rejected by GowinSynthesis on `$bits`), the worst case, rather than authoring an `imac`
> config. See the Result section for the outcome.

Point the tcl at the flattened netlist (top module `cva6`) and run from a writable dir. The tcl
reads `CVA6_NETLIST` / `CVA6_TOP` from the environment and selects the device with the same
grade-suffixed candidate loop as Tier-1:

```sh
mkdir -p /work/build/gowin-cva6 && cd /work/build/gowin-cva6
CVA6_NETLIST=/work/build/fpga-eval/cva6_imafdc_flat.v CVA6_TOP=cva6 \
  gowin-check /work/nix/gowin/cva6-util.tcl
```

Or headless: drop a `RUN_CVA6` marker (`netlist=…`, `outdir=…` lines; both default to the imafdc
flatten) under `/work/build/gowin/` and boot the VM — the `gowin-gate` service runs it, tees to
`<outdir>/synth.log`, and powers off.

Best-effort — CVA6 is Xilinx-native. Two friction points had to be cleared before it would
elaborate: (a) the raw sv2v `flat.v` trips GowinSynthesis's Verilog dialect on `$bits` → use the
cleaned `flat_synth.v`; (b) sv2v leaves four config-struct constants as illegal dotted field
accesses (`CVA6Cfg.{ASID_WIDTH,VMID_WIDTH,VpnLen,PtLevels}`) instead of lowering them to
bit-slices — substitute the compile-time values (`16 / 14 / 27 / 3` for this config) to produce
`cva6_imafdc_flat.v`. With that, the full core elaborates and synthesizes.

## Result

| Check | Status | Notes |
|---|---|---|
| Tier-1 gate (GW5AST-138 under Education license) | ✅ **GO** (2026-08-25) | `set_device` + `run syn` + `run pnr` all OK; bitstream `blinky_gate.fs` produced |
| Tier-2 CVA6 (`cv64a6_imafdc`, with FPU) utilization / Fmax | ⚠️ **synthesizes, does not fit as-flattened** (2026-08-25) | Full core elaborates + synthesizes in GowinSynthesis (after the 4-const patch); aborts at the DFF resource check — **register-bound**, see below. A clean LUT/Fmax number was not reached. |

**Tier-1 GO — the decisive pre-purchase answer.** The Education / NODELOCK license **does**
permit synthesis *and* place-and-route for the Tang Mega 138K Pro part. Verified end-to-end in
the microVM: node-locked license validated (via `gwlicense.ini` → the shared file), device
selected as `GW5AST-138B / GW5AST-LV138FPG676AC1/I0`, and a blinky bitstream generated.
Utilization from the PnR report (blinky probe):

| Resource | Used | Total | % |
|---|---|---|---|
| Logic (LUT/ALU/ROM16) | 26 | 138,240 | <1% |
| Register (FF) | 26 | 139,140 | <1% |

Peak PnR memory ~1.2 GB. This resolves the ⚠️ in
[fpga-platform-assessment.md](./fpga-platform-assessment.md) §4 to **GO**.

**Tier-2 — CVA6 synthesizes but is register-bound on this part (measured).** After the two fixes
above, GowinSynthesis ran the *whole* `cv64a6_imafdc` core end-to-end — netlist conversion →
optimization → inference → tech-mapping (≈4 h, single-threaded; ~18 GB peak) — then stopped at a
**hard resource error**:

```
ERROR (RP0001): The number(558387) of DFF(DL) in the design exceeds
the resource limit(139140) of device GW5AST-LV138FPG676AC1/I0
```

i.e. **~558K flip-flops required vs 139,140 available (~4× over)** — a NO-GO on capacity *as
flattened*. **Important caveat:** that FF count is a **flatten-flow artifact, not CVA6's real
register count**. The synthesis log shows **no BSRAM/block-RAM inferred at all**, and ~558K ≈ the
bit-count of CVA6's on-chip memories (I$ 16 KiB + D$ 32 KiB ≈ 393K bits, plus TLBs / branch
predictor / regfile). In the monolithic sv2v-flattened netlist those arrays mapped to
**flip-flops instead of the device's 340 BSRAM blocks**; on Xilinx (with CVA6's SRAM macros / BRAM
inference) they are block RAM and the core's true FF count is ~40–90K.

What Tier-2 *did* establish, beyond the assessment's "won't build through open-source flow":
- The license synth path handles **full CVA6** — it elaborates and synthesizes (with a 4-constant
  patch), not just a blinky.
- Capacity on the flatten flow is **register/memory-bound**, dominated by memories → FF, **not** by
  the FPU. So a no-FPU `imac` config would overflow the same way; the real lever is **BRAM
  inference** (mapping CVA6's memories to Gowin BSRAM), which needs the proper FPGA flow / SRAM
  macros, not a monolithic flatten. Deferred — it reinforces the assessment's "highest integration
  effort" ranking for the Tang Mega, and that the low-risk CVA6 fit is a Xilinx board with the
  official CVA6 FPGA reference design.

Artifacts (gitignored `build/`): `build/gowin-cva6-imafdc-patched/synth.log` (the full run),
`build/fpga-eval/cva6_imafdc_flat.v` (the patched netlist), plus the raw/cleaned failure logs
(`synth-flatv-rejected.log`, `synth-cfgref-failed.log`).

## Notes / troubleshooting (what the first bring-up taught us)

- **License mechanism (solved):** Gowin picks node-locked (`GWLIC::check_from_local`) vs a license
  server (`check_from_server`) from a `gwlicense.ini` next to the binary. With **no** ini it
  defaults to *server* and fails with "License verification failed — Connection timeout". The
  `gowin-check` wrapper writes `[license] lic="/work/gowin"` (a filesystem path → node-locked file)
  into the install's `bin/` (writable share) or, if the share is read-only, into an overlay bin.
  `LM_LICENSE_FILE` is **not** the hook (the `gowin` file is Gowin's own format, not FlexLM).
- **Headless Qt (solved):** `gw_sh` links Qt and inits a QApplication; without a display it aborts
  on the `xcb` platform plugin. The wrapper sets `QT_QPA_PLATFORM=offscreen`.
- **`gw_sh` shared libs (solved):** the bundled Qt5WebEngine drags a large `NEEDED` closure; all of
  it is enumerated in `programs.nix-ld.libraries` in `nix/gowin-vm.nix`.
- **Device name:** the board's marketing name `GW5AST-LV138FPG676A` is **not** what `set_device`
  wants — use the full grade-suffixed order code, e.g. `set_device -name GW5AST-138B
  GW5AST-LV138FPG676AC1/I0` (also `C2/I1`; device_version B or C). `device-check.tcl` tries the
  candidate spellings and uses the first accepted.
- **SystemVerilog:** `add_file -type verilog` parses Verilog, not SV (`logic`/`always_ff` are
  rejected) — the blinky probe is plain Verilog-2001; the sv2v-flattened CVA6 netlist is already
  plain Verilog.
- **9p vs virtiofs** — the shares use **9p** (built into qemu, single self-contained process, no
  `virtiofsd`); switch to `proto = "virtiofs"` in `nix/gowin-vm.nix` for faster shares.
- **RAM** — `microvm.mem` defaults to 8 GiB (override `mem`/`vcpu` in `local.nix`); the blinky gate
  peaks at ~1.2 GB, a full CVA6 synth wants more.
- **MAC form** — the license `HOST_ID` (a bare 12-hex MAC, e.g. `AABBCCDDEEFF`) becomes colon
  form (`AA:BB:CC:DD:EE:FF`) in `local.nix`; it must equal your license's `HOST_ID` exactly.
- **Headless autorun** — a marker-gated `gowin-gate` service runs the Tier-1 gate at boot and powers
  off when `/work/build/gowin/RUN_GATE` exists (writing `gate.log` + `impl/` to the share); a normal
  `nix run` with no marker just boots to the shell.
