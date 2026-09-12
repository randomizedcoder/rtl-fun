# Gowin BSRAM inference failure on CVA6 (challenge #16) — debug + reproducer

← [phase-8-status.md](./phase-8-status.md) challenge #16 · [fpga-platform-assessment.md](./fpga-platform-assessment.md) §5a · [gowin-microvm.md](./gowin-microvm.md)

**Purpose.** Capture, with a minimal self-contained reproducer, *why* GowinSynthesis
inferred **zero** block RAM when synthesizing the stock CVA6 core for the Tang Mega 138K Pro,
so that (a) we can pick the right fix and (b) this page can be sent to **Gowin support**
as-is if the vendor's inference behaviour turns out to be the blocker. Every claim below is
backed by a command you can re-run.

Append-mostly; date every entry; cite evidence.

---

## Bottom line (2026-09-09)

Stock CVA6 (`cv64a6_imafdc_sv39`, RV64GC) synthesized to completion under GowinSynthesis but
**mapped ~543 Kbit of cache/tag SRAM into flip-flops instead of BSRAM**, overflowing the
device ~4× (`ERROR (RP0001)`, 558,788 DFF > 139,140). The memory is BSRAM-friendly RTL
(registered read, byte-write-enable, no reset/init) and **survives cleanly as a `$mem_v2`
memory cell inside yosys**. The demotion happens at the **`write_verilog` → GowinSynthesis
re-read boundary**: yosys's Verilog backend lowers the byte-write-enable memory into **64
independent single-bit write conditionals** (`mem[addr][n:n] <= …`, one per data bit), and
GowinSynthesis cannot match that per-bit write-mask form to its BSRAM template, so it demotes
the whole array to registers.

**Fix (proven end-to-end): let yosys map the memories to hard Gowin BSRAM primitives**
instead of leaving the decision to GowinSynthesis inference. `synth_gowin -family gw5a`
maps the exact CVA6 RAM leaf to **`SPX9`** (the native gw5a single-port BSRAM-with-byte-write
primitive) — 2 blocks for a 256×64 cut. This does **not** require any change to CVA6's RTL.

**Confirmed through the real toolchain (2026-09-09):** the `SPX9` netlist was fed back to
**GowinSynthesis V1.9.12.03** in the licensed microVM (`nix run .#fpga-build -- m3-ramtest`),
and its resource report shows **`BSRAM = 2`, `REG = -` (zero registers), `LUT = 13`** for the
`tc_sram_wrapper` module — i.e. Gowin accepted the primitives and placed the memory in block
RAM, not flip-flops. Contrast the current-flow netlist, which the full CVA6 run put entirely
into flops (0 BSRAM). Both legs are reproducible nix targets (see *Minimal reproducer*).

## Update (2026-09-10): BSRAM SOLVED on the full core — new blocker is a GowinSynthesis LUT-mapper crash

The S2 netlist (coarse-minus-`alumacc` + hard-mapped SPX9; see below) was run through the
real fit `nix run .#fpga-build -- m3-core`. It synthesized cleanly for ~6 h with **no EX3937
and no SP00018**, through parser → device-independent optimization → inference → tech-mapping,
and GowinSynthesis **accepted the 4 SPX9 as block RAM** — the log shows `WARN (EX0346)` on the
SPX9 instances (`Instance "mem.0.0"/"mem.0.1" parameter "WRITE_MODE" … truncated to 2 bits`,
a benign 32→2-bit parameter-width cosmetic). **This closes the BSRAM-inference question
end-to-end on the full CVA6, not just the ram-test reproducer: the cache memory maps to BSRAM,
not flops.**

**However, gw_sh then aborted during LUT technical-mapping**, before any resource report:

```
[75%] Tech-Mapping Phase 2 completed
gw_sh: src/map/if/ifCut.c:1109: If_CutAreaDerefed:
       Assertion `aResult > aResult2 - 3*p->fEpsilon' failed.
… Aborted (core dumped)   gw_sh exit=134
```

`If_CutAreaDerefed` / `ifCut.c` is in the **embedded ABC** `if` (FPGA technology-mapping)
area-flow *cut* selection — a numerical-robustness assertion (referenced vs dereferenced area
diverging beyond `3·epsilon`). This is a **tool crash in GowinSynthesis V1.9.12.03**, distinct
from the earlier fit/overflow (`RP0001`) and front-end (`SP00018`, `EX3937`) failures; the
design never reached the utilization/timing report. It is deterministic.

**Workaround tried — `set_option -retiming 0` (2026-09-10): only DELAYED the crash.** Retiming
defaults ON and re-invokes the mapping/area passes, so disabling it is the standard first move
for GowinSynthesis mapper instability. It changed the mapping path — Tech-Mapping Phase 0 took
~2h13m instead of seconds — but gw_sh hit the **identical `If_CutAreaDerefed` assertion** ~76 min
into the phase-3 area recovery (same `[75%] Tech-Mapping Phase 2` → abort). The bug is therefore
**robust to mapping-effort perturbation**: a fundamental embedded-ABC defect on this netlist, not
a knob-tunable one. Two full ~6–7 h runs now crash identically.

**Remaining directions (all costly/uncertain):**
1. **yosys-side arithmetic decomposition** — the assertion is an area-flow divergence over a
   large combinational cone; the likely culprits are CVA6's 64×64 integer multiplier and the
   FPU mantissa multipliers, which GowinSynthesis expands into LUT logic (no DSP report was
   reached). Decomposing `$mul` in yosys (`booth`, or a targeted `$mul`→gates techmap that keeps
   `alumacc` out so no `EX3937`) would hand ABC smaller cones. Risk: LUT bloat / overflow, loss
   of DSP; ~6–7 h to validate; speculative on the exact cone.
2. **GowinSynthesis version bump** — this class of ABC assertion is fixed in later ABC releases;
   a newer Gowin EDA is the root-cause fix and the strongest tie to challenge #13. Only
   `1.9.12.03` (crashing) and older `1.9.11.03-edu` are installed, so this needs a newer release.
3. **Fallback ladder** (smaller config → Ibex → Xilinx) — premature, since the blocker is a tool
   crash, not a real fit failure (BSRAM inference and the front end are proven working).

A **faster repro loop** — synthesizing just the multiplier/FPU subtree — would confirm the
cone hypothesis without a 6–7 h full run, and doubles as the minimal testcase for Gowin support.
This `ifCut` assertion is itself a strong candidate to raise with Gowin support alongside the
coding-style question below.

---

## Environment

| Item | Value |
|---|---|
| Device | `GW5AST-LV138FPG676AC1/I0` (family GW5AST-138B, Arora V) |
| Device limits | 138,240 LUT4 · ~139,140 FF · 6,120 Kbit BSRAM (340 blocks) |
| Synthesis tool | **GowinSynthesis V1.9.12.03 (86714)** (`gw_sh`), commercial tree, licensed microVM |
| Front-end prep | yosys **0.68** (`slvgs8kvy4vxvf9li522vj6fp2iv4fsd-yosys-0.68`) + sv2v |
| Core | CVA6 v5.3.0, config `cv64a6_imafdc_sv39` (XLEN=64, RVH=0, **write-through cache**) |
| Flow entry | `nix run .#fpga-m3-core-rtl` (S1: sv2v → hierarchical yosys, no flatten) → `nix run .#fpga-build -- m3-core` |

---

## Symptom + evidence

From `build/fpga-m3-core-build.log` (the ~24 h S1 fit run; `Running inference` alone took
~14 h, [15722s]→[86215s]):

```
[87249.681921] ERROR (RP0001) : The number(558788) of DFF(DL) in the design exceeds the
                resource limit(139140) of current device(GW5AST-LV138FPG676AC1/I0)
               BUILD RESULT: FAIL
```

- **DFF: 558,788 vs 139,140 limit** — ~4× over.
- The strings `BSRAM` / `SSRAM` / `BRAM` / `block ram` appear **zero** times in the log
  (`grep -icE 'bsram|ssram|\bbram\b|block ram' build/fpga-m3-core-build.log` → `0`) — Gowin
  inferred no block RAM at all.
- No `SP00018` — the parser-specific "error bus name set" front-end bug (challenge #13) does
  **not** trip on stock CVA6; the front end is clean. The failure is purely memory mapping.
- DFF count is within ~400 of the earlier full-flatten attempt (558,387), so
  hierarchy-vs-flatten made **no** difference — the demotion is systematic, not a flatten
  artifact, and not a host-memory problem (a bigger build host fails identically).

---

## Memory inventory — what *should* map to BSRAM

Config `cv64a6_imafdc_sv39` uses the **write-through (WT) cache** with `TechnoCut=0`, so every
L1 array routes `sram_cache → sram.sv → tc_sram_wrapper` (64-bit-wide cuts, 1 R/W port,
registered read, byte-we). (`hpdcache_sram*` / `SyncSpRamBeNx64` are compiled into the Flist
but **not instantiated** in this config — 0 bits.) The Gowin netlist contains 14
`tc_sram_wrapper` instances (`grep -cE 'paramod.*tc_sram_wrapper' build/fpga-m3-core-rtl/cva6_core.v`).

| Structure | Geometry (logical) | Bits | Share |
|---|---|---|---|
| D$ data | 2 banks × 512×256 | 262,144 (256 Kb) | ~47% |
| I$ data | 4 ways × 128×256 | 131,072 (128 Kb) | ~24% |
| D$ tag | 8 ways × 45×256 (pad→64) | ~92–128 Kb | — |
| I$ tag | 4 ways × 45×256 (pad→64) | ~46–64 Kb | — |
| **Total L1 SRAM** | | **~543 Kbit** | — |

That is only **~8.7 %** of the device's 6,120 Kbit / 340 BSRAM blocks *if mapped to block
RAM* — the design fits comfortably. It only overflows because the memory landed in flops.

---

## Root cause

### The RTL is BSRAM-friendly

The active leaf `tc_sram_wrapper` (M3a fill, `nix/cva6-fpga/tc_sram_wrapper.sv`) is a textbook
inferrable single-port RAM — registered (synchronous) read, byte-write-enable, no reset, no
initial contents:

```systemverilog
logic [DataWidth-1:0] mem [NumWords-1:0];
always_ff @(posedge clk_i)
  if (req_i[p]) begin
    if (we_i[p]) begin
      for (int b = 0; b < BeWidth; b++)
        if (be_i[p][b])
          mem[addr_i[p]][b*ByteWidth +: ByteWidth] <= wdata_i[p][b*ByteWidth +: ByteWidth];
    end else
      rdata_q <= mem[addr_i[p]];   // synchronous read
  end
assign rdata_o[p] = rdata_q;
```

Inside yosys this stays a single `$mem_v2` cell after the memory passes (WIDTH=64, SIZE=256,
1 read port, 1 write port with byte enables). yosys is **not** the one demoting it.

### The `write_verilog` boundary is where it breaks

The S1 flow emits the yosys result back to Verilog for GowinSynthesis
(`scripts/fpga-m3-core-rtl.sh`: `… memory_dff; memory_share; memory_collect; opt_clean;
write_verilog -noattr`). `write_verilog` lowers the `$mem_v2` back into behavioural Verilog —
and it renders the byte-write-enable as **64 separate single-bit write statements**:

```verilog
reg [63:0] mem [255:0];
...
  mem[addr_i][0:0]  <= _0881_;
  mem[addr_i][1:1]  <= _0882_;
  mem[addr_i][2:2]  <= _0883_;
  ...
  mem[addr_i][63:63] <= _0943_;
```

Each `_08xx_` is the per-bit byte-enable-masked write value. To GowinSynthesis this reads as
an array with an **arbitrary per-bit write mask** (64 independent 1-bit write-enables). Gowin
BSRAM supports **word or byte** write-enable, not a per-bit mask, so inference cannot match
its BSRAM template and the array is demoted to registers. No `$mem` cells or memory attributes
survive `write_verilog -noattr`, so GowinSynthesis has only this behavioural text to infer from.

The pre-existing S1 flow deliberately runs **no** yosys BRAM mapping (`memory_libmap` /
`memory_bram` / `synth_gowin`) — it hands the entire BRAM decision to GowinSynthesis, in the
one form that defeats it.

---

## The fix — map memories to Gowin BSRAM in yosys (proven)

yosys 0.68 ships a **gw5a-aware Gowin BRAM backend**
(`share/yosys/gowin/brams.txt`, cells `$__GOWIN_SP_` / `$__GOWIN_DP_` / `$__GOWIN_SDP_`;
techmap `brams_map_gw5a.v`). Running the Gowin RAM mapping makes yosys emit **hard `SPX9`
primitive instances** instead of behavioural per-bit writes. `SPX9` is a native gw5a BSRAM
primitive in Gowin's own library (`IDE/simlib/gw5a/prim_sim.v:1402`), so GowinSynthesis
consumes the instance and places it in BSRAM.

Two equivalent recipes, both verified on the reproducer:

- **Full:** `synth_gowin -family gw5a` → 256×64 cut becomes **2 `SPX9`**.
- **Targeted (preferred — keeps logic generic for GowinSynthesis):**
  `synth_gowin -family gw5a -run :map_ffs` (runs coarse + RAM mapping, stops before
  FF/LUT gate mapping) → **2 `SPX9`** + generic logic, no LUT mapping.

This targeted idea is what S2 injects into `scripts/fpga-m3-core-rtl.sh`: yosys maps only the
memories to `SPX9`, GowinSynthesis still does the logic synthesis, no CVA6 patch needed. On the
single-module reproducer the tidy `:map_ffs` recipe above works; on the **full hierarchical core**
neither `-run` stop point is usable as-is — see the two 2026-09-10 subsections below. The final S2
form runs `synth_gowin`'s gw5a coarse pass **with `alumacc` removed** (it fuses arithmetic into
un-renderable `$alu`/`$macc_v2` → `EX3937`) followed by `map_ram`.

### De-risk on the full CVA6 netlist (2026-09-09)

Before committing to a ~24 h Gowin fit, the mapping was dry-run on the **whole** derived core
(from the `elab.il` checkpoint) with `synth_gowin -noflatten -family gw5a -top cva6 -run
:map_ffram` (coarse + RAM mapping only; `-noflatten` gives the same per-`$mem` mapping outcome
without the heavy 500 MB flatten, and keeps the hierarchy that kept #13/SP00018 quiet). ~5 min,
peak RSS < 800 MB. Result:

- **Every cache/tag array maps to Gowin BRAM:** `memory_libmap` logs `mapping memory
  …tc_sram_wrapper.mem via $__GOWIN_SP_` for all `tc_sram_wrapper` geometries →
  **72 `SPX9`** design-wide (vs. 340 BSRAM blocks on the device — comfortable). This is the
  543 Kbit that previously demoted to flops.
- **Only 13 `$mem_v2` stay as logic**, and they are *not* cache RAM: all are
  `$auto$proc_rom` / `$auto$memory_bmux2rom` memories — small constant decode/ROM tables
  inferred from `case` statements in the FPU (`fpnew_*`) and LSU (`load_unit`, `store_unit`,
  `load_store_unit`, `control_mvp`). `memory_libmap` correctly maps these to logic; FF/LUT is
  the right target for them and they are negligible.

So the fix maps exactly what needs mapping and leaves alone what shouldn't be BRAM — the
partial-demotion risk does not materialize.

### Emit at scale settles the stop point: `:map_gates`, not `:map_ffs` (2026-09-10)

The de-risk above stopped at cell **counts** and never `write_verilog`'d the full netlist.
Emitting it at scale (from `elab.il`) before the real fit turned up a correction. The tidy
single-module recipe `-run :map_ffs` is **wrong for the full hierarchical (`-noflatten`) core**:
under `-noflatten`, `synth_gowin`'s `map_gates` step runs `iopadmap` on **every** module in the
preserved hierarchy, wrapping the internal module ports in `IBUF`/`OBUF` — **84,536 `IBUF` /
70,177 `OBUF` across all 139 modules** (212 MB netlist, 56 min, 42.7 GB peak). That is illegal
input for GowinSynthesis, which inserts pad buffers only at true device pins. The single-module
reproducer never exposes this because *its* ports are the top ports (so `:map_ffs` is fine there,
and is what the Gowin-confirmed `BSRAM=2` run below used).

The correct stop point is **`-run :map_gates`** — run coarse + `map_ram` (→ `SPX9`) +
`map_ffram` (small ROMs → logic), and stop **before** the gate techmap + `iopadmap`. The
surrounding logic then stays as coarse behavioral cells (`$add`/`$mux`/`$dff`) — exactly the S1
form GowinSynthesis already accepted, plus the RAM pre-mapped to `SPX9`. Emit-validated on the
full core from the checkpoint:

| Stop point | SPX9 | IBUF/OBUF | residual `$mem` | per-bit writes | time / peak / netlist |
|---|---|---|---|---|---|
| `:map_ffs` (wrong for -noflatten) | 72 | **84,536 / 70,177** | 0 | 0 | 56 min / 42.7 GB / 212 MB |
| **`:map_gates` (S2, correct)** | **72** | **0 / 0** | **0** | **0** | **4.5 min / 1.3 GB / 2.1 MB** |

### `:map_gates` also failed (EX3937) — the final S2 form is coarse *minus* `alumacc` (2026-09-10)

Feeding the `:map_gates` netlist to the real fit fast-failed in ~1 min:

```
ERROR (EX3937): Instantiating unknown module '$macc_v2'   (issue_read_operands, scoreboard)
```

Cause: `synth_gowin`'s `coarse` step runs **`alumacc`**, which fuses `$add`/`$sub`/`$mul`/compare
cells into the coarse macros **`$alu` (621) and `$macc_v2` (151)**. `write_verilog` cannot render
those, so it emits them as module instantiations — and GowinSynthesis has no such modules. There
is no clean inverse pass to un-fuse them, and a plain `techmap` over-lowers **all** arithmetic to
gates (destroying GowinSynthesis's own DSP inference and ballooning LUTs on 621 + 151 operators).

Fix: **never run `alumacc`.** S2 is now `synth_gowin`'s gw5a `coarse` pass with `alumacc` removed
and `flatten` skipped, followed by `map_ram`:

```
proc; opt_expr; opt_clean; check;
opt -nodffe -nosdff; fsm; opt; wreduce; peepopt; opt_clean; share;
opt; memory -nomap; opt_clean;
memory_libmap -lib +/gowin/lutrams.txt -lib +/gowin/brams.txt -D gw5a;
techmap     -map +/gowin/lutrams_map.v -map +/gowin/brams_map.v -D gw5a;
opt_clean; memory_collect; opt_clean;
write_verilog -noattr <out>
```

Arithmetic stays high-level (`+`/`-`/`*`), which is exactly what GowinSynthesis wants — yosys does
**not** run `mul2dsp`/`dsp_map` for gw5a, leaving `$mul` for the vendor tool's DSP inference.
Emit-validated on the full core from `elab.il`:

| form | SPX9 | `$alu`/`$macc` | IBUF/OBUF | residual `$mem` | per-bit writes | `+`/`-`/`*` |
|---|---|---|---|---|---|---|
| `:map_gates` (EX3937) | 4 | **621 / 151** | 0 | 0 | 0 | fused away |
| **coarse − `alumacc` (S2)** | **4** | **0 / 0** | **0** | **0** | **0** | **426 / 659 / 57** |

(The correct SPX9 count is **4**; the earlier ":map_ffram → 72 SPX9" de-risk count was wrong.)
The 13 memories left as behavioral arrays are all tiny (≤128 entries — branch-predictor counters,
fpnew lookup ROMs), clean inferrable style, so GowinSynthesis places them in LUTRAM/BSRAM (cheaper
on the FF budget than FF-mapping). The one residual — GowinSynthesis accepting the *full*
hierarchical `SPX9` + high-level-logic netlist — is only fully settled by the real fit run.

> **Note on `memory_libmap` standalone.** Running `memory_libmap -lib gowin/brams.txt` by hand
> after a manual `memory -nomap` leaves the memory unmapped ("logic fallback" only): the
> `$mem_v2` read port shows `RD_CLK_ENABLE=0` because `memory_dff` did not fold the
> `req_i`-gated output FF into the read port (it reports *"FF found, but with a mux select that
> doesn't seem to correspond to transparency logic"*). The Gowin SP candidate requires a
> **synchronous** read port and is pruned at the geometry stage. `synth_gowin`'s coarse
> optimizations run before `memory` and restructure the read mux so `memory_dff` folds the FF
> ("merging output FF to cell") — hence the SP mapping succeeds. **Takeaway:** use the
> `synth_gowin` flow (or replicate its coarse pre-pass), not a bare `memory_libmap`.

---

## Minimal reproducer (reproducible nix targets)

Self-contained; the yosys leg runs in ~1 s, the Gowin leg in a few minutes. Source is the
CVA6 RAM leaf reduced to a standalone module, committed at
`fpga/tang-mega-138k-pro/src/m3_ramtest.v` (module `tc_sram_wrapper`), elaborated at a
representative cut (256 words × 64 bits, 1 port, 8-bit bytes, latency 1). No hand-run
yosys/`gw_sh` — both legs are flake targets:

```sh
# yosys leg — emits both variant netlists + a summary (build/fpga-m3-core-rtl/diag/):
nix run .#fpga-m3-core-rtl -- diag
#   current_flow_per_bit_write_conditionals=64   (the demotion form)
#   axisA_SPX9_primitives=2                       (hard gw5a BSRAM)

# Gowin leg — feeds the SPX9 netlist to GowinSynthesis in the microVM and reads the report:
nix run .#fpga-build -- m3-ramtest
#   module = tc_sram_wrapper (.../diag/axisA_spx9.v)
#   REG=-  LUT=13  BSRAM=2
#   BUILD RESULT: PASS — GowinSynthesis mapped the SPX9 netlist to 2 BSRAM block(s)
```

Results:

| Variant | Path | Result |
|---|---|---|
| yosys memory model | after `memory_collect` | **1 `$mem_v2`** (memory intact) |
| (a) current S1 flow | `memory_collect; write_verilog -noattr` | **64 per-bit `mem[..][n:n] <=`** → GowinSynthesis infers **0 BSRAM** |
| (b) fix, targeted | `synth_gowin -family gw5a -run :map_ffs` | **2 `SPX9`** hard BSRAM + generic logic |
| (b) fix, full | `synth_gowin -family gw5a` | **2 `SPX9`** |
| **(b) through GowinSynthesis** | `nix run .#fpga-build -- m3-ramtest` | **`BSRAM=2`, `REG=-`, `LUT=13`** — Gowin places it in block RAM |

The `diag` mode and `m3-ramtest.tcl` are the reproducible harness; per-run artifacts land under
`build/fpga-m3-core-rtl/diag/` and `build/fpga-m3-ramtest/` (gitignored). The earlier ad-hoc
`build/fpga-m3-core-rtl/diag/ramtest/exp/` experiments (loose `.ys` files) are superseded by
these targets.

---

## Open question for Gowin support (if pursued)

Given a **registered-read, byte-write-enable, single-port RAM** written in the standard
inferrable style (the RTL shown above), GowinSynthesis V1.9.12.03 infers **no** BSRAM and
demotes the array to registers. Two questions:

1. Which coding style / template does GowinSynthesis gw5a BSRAM inference require for a
   registered-read **byte-write-enable** single-port RAM? (cf. **SUG550** GowinSynthesis User
   Guide, RAM-inference section; **SUG949** HDL Coding Guide; **UG300** Arora-V BSRAM & SSRAM.)
2. Why is a per-byte / per-bit write-mask form (as emitted by a standard Verilog memory
   backend) demoted rather than inferred, given the device BSRAM supports byte write-enable
   (`SPX9`, 9-bit-per-byte)? Is there a directive/attribute to force BSRAM inference?

(We have a **confirmed** working path — pre-mapping to `SPX9` in yosys, which GowinSynthesis
places in BSRAM: `BSRAM=2`, 0 registers on the reproducer — so the vendor question is only
needed if we prefer GowinSynthesis-native inference over yosys pre-mapping.)

---

## References (all local, Gowin install `…/gowin-eda-1.9.12.03/IDE/`)

- `doc/EN/UG300-1.3.6E_Arora V BSRAM & SSRAM User Guide.pdf` — device-specific BSRAM (primary).
- `doc/EN/UG285-1.4E_Gowin BSRAM & SSRAM User Guide.pdf` — general BSRAM.
- `doc/EN/SUG550-2.4E_GowinSynthesis User Guide.pdf` — RAM inference coding styles.
- `doc/EN/SUG949-2.2E_Gowin HDL Coding User Guide.pdf` — recommended HDL memory templates.
- `simlib/gw5a/prim_sim.v` — gw5a BSRAM primitive models: `SP`:1094, **`SPX9`:1402**,
  `SDPB`:1692, `SDPX9B`:1976, `DPB`:2219, `DPX9B`:2631, `pROM`:2999, `pROMX9`:3196.
- yosys gw5a BRAM backend: `<yosys-0.68>/share/yosys/gowin/{brams.txt,brams_map_gw5a.v}`.
