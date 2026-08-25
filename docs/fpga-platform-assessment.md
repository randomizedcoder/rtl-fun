# FPGA Platform Assessment — pre-purchase feasibility for CVA6 + parser

← [Phase 8](phase-8-fpga.md) · [Tang Mega bring-up plan](tang-mega-138k-pro-rtl-fun-plan.md) · [Docs index](README.md)

> **Status: pre-purchase evaluation.** This document records a software-only feasibility
> study performed *before* committing to an FPGA board, to answer: **is the Sipeed Tang
> Mega 138K Pro (Gowin GW5AST-138) a sound target for CVA6 + the packet-parser extension,
> or is another board a better buy?** Everything here was determined on the NixOS
> workstation with no FPGA hardware. Date of study: 2026-08.

## 1. Question and method

The Phase 8 goal is to run CVA6-plus-parser on real hardware and parse Ethernet. Before
buying a board, we wanted to de-risk the two make-or-break questions cheaply:

1. **Capacity** — does CVA6 + the parser fit on the candidate device, with headroom for a
   packet buffer, counters, and (later) DDR / Ethernet?
2. **Toolchain** — can the design actually be built for the device with an available,
   reproducible flow?

**Method.** We reused the repo's existing `sv2v` + `yosys` machinery (already used by
`parser-formal`) to flatten SystemVerilog to Verilog-2005 and run **generic synthesis with
LUT4 mapping** (`synth -lut 4`), because the Gowin GW5AST is a **LUT4** architecture. This
gives a rough, vendor-independent gate estimate. We measured the **parser unit** directly,
and **attempted** the full CVA6 core (config `cv64a6_imafdc_sv39`, RV64GC with FPU).

**Tooling (pinned, reproducible):**

| Tool | Version / pin |
| --- | --- |
| nixpkgs | `867dcbc30bafe3c862ef88620f2e7a109d7d3be5` |
| yosys | 0.67 |
| sv2v | 0.0.13.1 (`haskellPackages.sv2v`) |
| CVA6 | v5.3.0 (`openhwgroup/cva6` rev `2ef1c1b…`), config `cv64a6_imafdc_sv39` |

> **Important caveat.** Generic yosys `synth -lut 4` is a *proxy*, not a verdict. It does
> not infer block RAM or DSPs (memory maps to flip-flops/LUTs), and its mapper differs from
> a vendor's. The authoritative area/timing numbers must come from the target vendor's
> synthesis tool. These estimates are for **relative sizing and a buy/no-buy call**, not
> sign-off.

## 2. Finding A — the parser add-on is negligible ✅

The parser datapath synthesizes cleanly. LUT4 mapping (generic yosys):

| Module | LUT4 | FF | Note |
| --- | ---: | ---: | --- |
| `parser_execute` (the functional unit) | ~4,148 | — | combinational compute; includes some standalone-synthesis latch inflation |
| `parser_cam` | ~1,676 | 1,696 | small CAM → **block RAM** on a real target |
| `parser_pktbuf` | ~19,432 | 2,048 | **misleading**: the 256-byte packet buffer maps to flip-flops here; → **1–2 block SRAMs** on a real target, LUTs collapse |
| `parser_decode` | 169 | — | trivial |

**Net logic footprint ≈ 6K LUT4 + a handful of block-SRAMs** once memory maps to BRAM
(as every real FPGA flow does). Against any mid-size FPGA this is a rounding error.

> **Conclusion:** the parser extension — the whole point of this project — is **not** the
> FPGA constraint. It is small and portable, and drops onto any host core. **The host core
> (CVA6) dictates the board.**

## 3. Finding B — CVA6 will not build through the open-source flow

Attempting the full `cva6` core through `sv2v → yosys` hit a **chain of seven distinct
failures**, each a different construct in CVA6's heavily machine-generated, hyper-parameterized
SystemVerilog:

1. `string` type in the simulation disassembly tracer
2. a `final` block (sim-only)
3. `$finish` used outside an `initial` block (sv2v-lowered assertions)
4. `$bits(type(...))` type-query operator
5. `AST_AUTOWIRE` sizing failure in the CV-X-IF example coprocessor's mega-expression
6. `AST_AUTOWIRE` sizing failure in the MMU/TLB's parameterized index expressions
7. a paramod generate-block port tied to constants in the FPU (`fpnew`)

Each is individually patchable, but they cascade; a clean whole-core open-source synthesis
would take substantial per-construct surgery — and would still not be authoritative.

> **Conclusion (a real finding, not just a nuisance):** **CVA6 is not friendly to the
> open-source synthesis flow.** It is developed and validated on **Xilinx/Vivado**, and that
> is by far the most trodden path. This has direct consequences for board choice (§5) and
> corroborates the Gowin tooling finding (§4).

## 4. Finding C — open-source tooling does not cover the GW5AST-138

The open-source Gowin flow is **yosys (`synth_gowin`) → nextpnr-himbaechel-gowin → Project
Apicula (`gowin_pack`) → openFPGALoader**. Apicula's device coverage, as of this study
(Aug 2026):

- **Production-ready:** older/smaller **LittleBee (GW1N) and GW2A** families (Tang Nano
  9K/20K, Tang Primer 20K).
- **GW5A / Arora-V:** **experimental, actively reverse-engineered** (clock routing, ALU,
  memory, DCS/OSC have landed) but incomplete, and focused on the **small** GW5A parts.
- **GW5AST-LV138 (the Tang Mega 138K Pro's device):** one of the **largest** Arora-V parts,
  with hardened RISC-V/DDR3/SerDes — **not usably supported**. A design as large as CVA6
  needs mature, complete device support that does not exist open-source for this part.

**Consequences:**

- For the Tang Mega 138K Pro, **Gowin EDA is required** to produce a bitstream. (`openFPGALoader`
  can still *program* a Gowin-produced `.fs`, and Verilator/yosys remain useful for
  simulation and estimates — but not bitstream generation.)
- Gowin EDA runs **synthesis + place-and-route + timing in software with no board attached**
  — so exact fit/Fmax for GW5AST-138 is answerable **pre-purchase**, for the price of a free
  Gowin EDA download.
- ⚠️ **Open question for the Education license:** Sipeed states the 138K Pro wants Gowin
  **commercial** IDE 1.9.9+, not Education. Confirm `GW5AST-LV138FPG676A` is a selectable
  device under the obtained Education/STD license **before** buying the board — a five-minute
  check in the device selector, and a gating one.

Sources: [Project Apicula](https://github.com/yosyshq/apicula) ·
[GW5A support issue #204](https://github.com/YosysHQ/apicula/issues/204) ·
[Apicula supported boards](https://github.com/YosysHQ/apicula/wiki/Nextpnr%E2%80%90Himbaechel-Gowin) ·
[Arora V family](https://www.gowinsemi.com/en/product/detail/60/)

## 5. Finding D — CVA6 capacity estimate (from published data)

Since the direct synthesis did not converge (§3), we bound CVA6's size from its **published
Xilinx FPGA utilization** and convert to LUT4-equivalent (LUT6→LUT4 typically inflates
~1.4–1.8×, since a 6-input LUT packs more logic than a 4-input one):

| Config | Est. LUT6 (Xilinx, core+caches) | Est. LUT4-equiv | Fit on GW5AST-138 (138,240 LUT4)? |
| --- | --- | --- | --- |
| `cv64a6_imafdc` (RV64GC **with FPU**) | ~80–110K | **~120–180K** | **At the edge or over** — little room for parser + buffer, none for DDR/SFP+ later |
| `cv64a6_imac` (no FPU) | ~60–80K | **~90–130K** | **Fits with headroom** — the parser (~6K) drops in comfortably |

The **FPU is the swing factor** (~20–30K LUT6 ≈ 30–50K LUT4), and **the parser does not need
it**. So a leaner core is a perfectly reasonable prototype target.

> These are estimates with real uncertainty, but the **qualitative** conclusion is robust:
> full RV64GC-with-FPU is tight-to-over on a 138K-LUT4 part; a no-FPU config fits comfortably.

## 6. Recommendations — top 5 FPGAs for this project

Deciding factors, in priority order: **(1)** toolchain maturity for *CVA6* (Xilinx-first),
**(2)** capacity for CVA6 + parser + headroom, **(3)** a real Ethernet MAC/PHY + DDR for the
parsing endgame, **(4)** openness / cost.

| # | Board / FPGA | Logic | Ethernet / DDR | Toolchain | CVA6 fit | Key trade-off |
| --- | --- | --- | --- | --- | --- | --- |
| **1** | **Digilent Genesys 2** — Kintex-7 XC7K325T | ~203K LUT6 | **GbE + SFP+**, DDR3 | Vivado (license needed for 325T; academic pricing) | Full RV64GC+FPU, huge headroom | *The* official CVA6 FPGA target — SoC/DDR/MAC already wired. **Lowest-risk path.** Cost + paid Vivado. |
| **2** | **Artix-7 XC7A200T** — Alinx AX7203 / QMTECH (or Nexys Video) | ~134K LUT6 | GbE + DDR3 (Alinx/QMTECH; Nexys Video has no RJ45) | **Vivado WebPACK — free** | Full CVA6 (tight-ish w/ FPU, comfortable trimmed) | **Best value + free vendor tools.** Port the CVA6 SoC from Genesys2 (Xilinx→Xilinx, moderate). ~$250–350. |
| **3** | **Xilinx Zynq UltraScale+** — Kria KV260 / ZCU104 | Large | Hardened GbE, DDR4 | Vivado | Full CVA6 + room | Hardened **ARM + Linux** to drive/benchmark the parser realistically. Pricier. |
| **4** | **Lattice ECP5** — ULX3S-85F (logic) / Colorlight 5A-75 (ethernet) | ~84K LUT4 | Colorlight: **2× GbE PHY**, cheap; ULX3S: none built-in | **Fully open — yosys + nextpnr + Trellis, no vendor software** | **Trimmed CVA6 (no FPU) or Ibex** + parser | The **100%-open** option. Cost: smaller core, no full RV64GC. Colorlight ~$20–40. |
| **5** | **Sipeed Tang Mega 138K Pro** — Gowin GW5AST-138 | 138K LUT4 | **2× SFP+ (10GbE)**, DDR3, PCIe | Gowin EDA required (open flow immature for GW5A) | Trimmed likely; full is tight | **Best raw I/O for the 10GbE endgame** and cheap — but **highest integration effort** (no CVA6 ref design, Gowin-only, SV-compat risk). |

### Guidance by priority

- **Least pain / most likely to just work → Genesys 2 (#1).** CVA6's home board; DDR + GbE +
  SFP+ done. Buy if academic Vivado is acceptable.
- **Best value with free tools → Artix-7 A200T (#2).** Free Vivado, fits CVA6, 1GbE + DDR3,
  ~⅓ the price; a little Xilinx-to-Xilinx porting.
- **Avoiding vendor software is the priority → ECP5 (#4).** Fully open, but commit to a
  leaner core (no-FPU CVA6 or Ibex) — which §5 shows is a reasonable prototype.
- **10GbE line-rate parsing is the whole point / you enjoy the integration → Tang Mega (#5).**
  Great I/O, cheap; expect to build the CVA6 SoC integration yourself under Gowin EDA.

## 7. Decision framework

```
              Do you need full RV64GC + FPU?
                        |
          +-------------+-------------+
          | yes                       | no (parser needs no FPU)
          v                           v
   Big Xilinx (Genesys 2         Fits ~90–130K LUT4:
   / A200T / Zynq US+)           many options open up
          |                           |
   Vendor tools OK? --- no ---> ECP5 (open) w/ trimmed CVA6 or Ibex
          | yes                       |
          v                           v
   Genesys 2 (#1) / A200T (#2)   ECP5 (#4), or Tang Mega (#5)
                                 if 10GbE endgame + Gowin OK
```

**Regardless of board, the parser is portable** — the width-parameterized unit drops onto
CVA6 *or* Ibex — so the board decision is really "how much host core do I want, and how
open/cheap/wired-for-Ethernet."

## 8. Next steps (all pre-purchase, no board required)

1. **Tang Mega, if still a candidate:** once Gowin EDA is installed, (a) confirm
   `GW5AST-LV138FPG676A` is selectable under the Education license (§4), then (b) run a
   software-only Gowin synth of `cv64a6_imac` and `cv64a6_imafdc` → exact utilization + Fmax.
   That is the real go/no-go, and it costs nothing but compute.
2. **Xilinx path:** the CVA6 `corev_apu/fpga` reference design targets Genesys 2 directly; a
   free-Vivado A200T build is a modest port. This is the lowest-risk route to a working
   CVA6 + parser + 1GbE demo.
3. Whichever board: build **stock CVA6 first** (baseline), then add the parser unit, then the
   MAC→buffer path — per [phase-8-fpga.md](phase-8-fpga.md) §8.4.

## Appendix — reproducing the estimates

```bash
NP=github:NixOS/nixpkgs/867dcbc30bafe3c862ef88620f2e7a109d7d3be5
# parser datapath, LUT4 mapping:
nix shell "$NP#haskellPackages.sv2v" -c sv2v -I rtl --write=parser_dp.v \
  rtl/parser_pkg.sv rtl/parser_cam.sv rtl/parser_pktbuf.sv rtl/parser_decode.sv rtl/parser_execute.sv
nix shell "$NP#yosys" -c yosys -p \
  "read_verilog parser_dp.v; synth -lut 4 -top parser_execute; stat"
```

**Caveats:** generic yosys LUT4 mapping does not infer BRAM/DSP (memory shows as
flops/LUTs); standalone module synthesis can infer latches that inflate combinational-only
blocks; the CVA6 whole-core synthesis does **not** complete on this flow (§3). Treat all
CVA6 numbers as published-data estimates (§5), to be confirmed by the target vendor's tool.
