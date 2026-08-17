# Testing overview — how the parser is tested

← [Docs index](README.md)

> **New here? This is the map.** "How do I know the parser works?" is answered in
> **four layers**, each with its own `nix run .#<app>` command, all green today. This
> page shows what each layer proves, where it lives, and — the key idea — how a
> **single generator** turns the golden C model into the vectors that drive *both* the
> standalone RTL suite and the in-core co-simulation, so RTL and model can never
> silently drift.

## The one invariant: golden-model-first

The C reference model (`model/libparsermodel`) is the **single source of truth**.
Every test's *expected* output — flow_keys bytes, exit code — is produced by the
model on the same input, never hand-authored. One generator,
[`verif/gen/gen_parser_rom.c`](../verif/gen/gen_parser_rom.c), runs the model over a
table of packet cases (`suite[]`) and emits the vectors; adding coverage means
adding a row, not writing a new testbench. See the design rationale in
[analysis/cva6-verification-design.md](analysis/cva6-verification-design.md) §0.

```
                         model/libparsermodel  (golden C model — the oracle)
                                    │
                  verif/gen/gen_parser_rom.c  (one generator, `suite[]` = the cases)
                                    │
            ┌───────────────────────┴───────────────────────┐
            │  program.hex / cam.hex                          │  enc.hex / camprog.hex
            │  enc.hex / packet.hex   ($readmemh)             │  + packet/expected/params.hex
            ▼                                                 ▼
   LAYER 2: standalone RTL suite                    LAYER 4: in-core co-sim
   tb/parser_top.sv + tb/parser_smoke_tb.sv         tests/cva6-parser/cosim_main.S
   (Verilator, RTL vs model)                        (real CVA6 pipeline, MMIO, vs model)
```

A new `suite[]` row flows into **both** Layer 2 and Layer 4 automatically — this is
why "full-close" work (adding edge packets) is mostly a generator edit.

## The four layers

### Layer 1 — Golden-model unit / corpus / fuzz  (`model/`)

Proves the **oracle itself** is correct and robust before anything trusts it.

| Command | What it proves |
|---------|----------------|
| `nix run .#model-test` | model unit tests + directed/malformed cases + round-trip encode/decode + the pinned xdp2 `proto_audit` corpus (306 pcaps terminate cleanly) |
| `nix run .#model-analyze` | cppcheck + gcc `-fanalyzer` + clang-tidy + ASan/UBSan on the model |
| `nix run .#model-fuzz` | libFuzzer + ASan/UBSan on random packets (`FUZZ_SECONDS=`) |
| `nix run .#pm-trace` | single-step a parse (debug aid, not a gate) — see [tools/](../tools/README.md) |

Lives in `model/libparsermodel/`; the fuzz/trace utilities in `tools/`.

### Layer 2 — Standalone RTL unit vs model  (Verilator, no CPU)

The parser datapath runs **solo** in Verilator — a tiny micro-PC + program ROM
(`parser_top.sv`) stands in for CVA6's fetch, so the `parser_execute` datapath can
walk a whole program and produce a flow_keys. Each case is compared byte-for-byte +
exit code against the model's generated vectors.

| Command | What it proves |
|---------|----------------|
| `nix run .#parser-sim` | smoke test: the vertical slice produces the model's flow_keys (fast, `-O3`) |
| `nix run .#parser-sim-suite` | the directed 22-case suite (pos/neg/boundary/corner) vs the model |
| `nix run .#parser-sim-decode` | same suite, but sourced through `parser_decode.sv` (32-bit words) — proves the RTL decoder == the model's `encoding.c` |
| `nix run .#parser-sim-trace` / `-debug` | + VCD waveform / `-O0 -ggdb` for gdb |
| `nix run .#parser-lint` | `--lint-only -Wall` (fast strict lint, no build) |
| `nix run .#parser-analyze` | extra SV lint: verible + svlint |

Lives in `tb/`: `parser_top.sv` (scaffold), `parser_smoke_tb.sv` (the `CHECK`-macro
testbench, reads per-packet params at runtime so one build runs every case).
Consumes `program.hex`/`cam.hex`/`enc.hex`/`packet.hex` via RTL `$readmemh`.

### Layer 3 — In-core directed tests  (real CVA6 pipeline, hand-crafted stimulus)

Runs **inside the patched CVA6 core** to prove the pipeline integration: decode →
issue → EX (the `fu_t::PARSER` FU) → writeback → commit → fetch-redirect. These are
directed, hand-encoded stimuli (deliberately — they predate the generator-fed cosim
and target specific integration seams).

| Command | What it proves |
|---------|----------------|
| `nix run .#cva6-parser-test` | a bare-metal custom-0/custom-3 program issues/executes/retires in-core; markers confirm the I2 metadata sink (`META OK`), I3 custom-3 readback, and I4a/I4b fetch redirect (`REDIRECT OK` / `CAM REDIRECT OK`); fesvr `tohost` PASS |
| `nix run .#parser-wrap-test` | 13 assertion-based scenarios on `cva6_parser_wrap`: V11 reset/X-freedom, I1 commit/flush rollback + backpressure, I2 metadata, I3 readback, I4a redirect target, I4b CAM program/readback + CAMNEXT-hit redirect, V4 WAW last-writer-wins, store-past-frame bound, CPPRSWRIMM immediate-load (commit-gate + rollback), CPPRSWRCAM commit-gate + flush-rollback + dependent-lookup interlock |

Lives in `tests/cva6-parser/parser_insn.S` (the in-core directed program, hand-encoded
`.word`s) and `tb/parser_wrap_tb.sv` (the wrap-TB). The I1 speculation-safety SVAs
(`a_arch_committed`, `a_flush_rollback`) are proven here.

### Layer 4 — In-core co-simulation vs model + formal  (the top of the pyramid)

The full **packet → flow_keys equivalence, in-core, over real MMIO** — the same
golden vectors as Layer 2, but driven through the actual CVA6 pipeline and a SoC AXI
peripheral instead of a Verilator scaffold.

| Command | What it proves |
|---------|----------------|
| `nix run .#cva6-parser-cosim` | for every suite packet: `sd` the packet into the FU packet buffer over MMIO, program the CAM, run the parse graph in-core, `ld` the committed flow_keys back, compare to the model — **22/22, byte-for-byte + exit code** |
| `nix run .#parser-formal` | SymbiYosys 1-step BMC: `parser_execute` never writes metadata out of bounds and always exits with a valid code, for *all* inputs |
| `nix run .#parser-negative-control` | negative control (G11): the **stock** (unpatched) model runs `negctl.S` — the identical custom-0 word traps illegal-instruction (mcause=2) on the base RV64GC decoder → handler `tohost=1` → fesvr SUCCESS. Proves the parser ops are a genuine ISA *extension*, so Layer 3/4's PASS is specific to the patch |

Lives in `tests/cva6-parser/cosim_main.S` (the fixed driver, linked per-case with the
generator's `prog.S` + `case.S`), the MMIO peripheral in `nix/cva6-parser/mmio.patch`
(see [analysis/cva6-parser-mmio.md](analysis/cva6-parser-mmio.md)), and the formal
harness in `verif/formal/`. Consumes `enc.hex`/`camprog.hex` from the generator and
munges `packet`/`expected`/`params.hex` into assembly.

## Where the source lives

| Artifact | Path |
|----------|------|
| Golden model | `model/libparsermodel/` |
| Vector generator | `verif/gen/gen_parser_rom.c` |
| Synthesizable RTL + assertions | `rtl/*.sv`, `rtl/parser_asserts.svh` |
| Standalone testbenches / scaffold | `tb/parser_smoke_tb.sv`, `tb/parser_top.sv` |
| Wrap testbench | `tb/parser_wrap_tb.sv` |
| Formal harness | `verif/formal/` |
| In-core test programs | `tests/cva6-parser/` (`parser_insn.S`, `cosim_main.S`, `negctl.S`, `link.ld`) |
| Runner script bodies | `scripts/*.sh` (readFile'd into the nix `writeShellApplication` wrappers) |
| CVA6 patches | `nix/cva6-parser/*.patch` |

`rtl/` holds only synthesizable RTL; the testbenches live in [`tb/`](../tb/README.md)
and the generator + formal harness in [`verif/`](../verif/README.md).

## The full green matrix

Every layer is green from the flake. To run the lot:

```sh
nix run .#model-test          # Layer 1
nix run .#parser-sim-suite    # Layer 2 (+ .#parser-sim-decode, .#parser-lint, .#parser-analyze)
nix run .#cva6-parser-test    # Layer 3 (+ .#parser-wrap-test)
nix run .#cva6-parser-cosim   # Layer 4 (+ .#parser-formal)
nix run .#parser-negative-control   # regression: stock core must trap the parser word (G11)
```

## Coverage status & what's deferred

The increment-by-increment build state (I1–I5) and per-gap burn-down are tracked in
[analysis/cva6-implementation-status.md](analysis/cva6-implementation-status.md). What
the I1–I5 arc did **not** yet close — the edge-packet rows, per-op negative directed
cases, the remaining V-table pipeline rows, and the Phase-7/8 escalations — lives in
one place: the [canonical deferral list](analysis/cva6-verification-design.md#31-canonical-deferral-list-single-source-of-truth).
