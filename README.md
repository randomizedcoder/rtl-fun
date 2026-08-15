# rtl-fun

**Parser instructions for RISC-V — a CPU-in-the-datapath packet parser as an ISA extension.**

This project takes Tom Herbert's *"parser instructions"* idea — domain-specific
CPU instructions that make protocol parsing fast *and* fully programmable — and
carries it all the way to real RTL: a SystemVerilog RISC-V extension, verified
against a golden software model and prototyped on FPGA.

## Why

Protocol parsing is a parse-graph walk: for each header you must (1) determine
its length and (2) determine the next protocol. Fixed-function parsers are fast
but rigid; plain integer code is flexible but slow (dominated by load/shift/mask/
branch). Making the parser a set of *CPU instructions* gives both: hardware-speed
primitives that live inside a Turing-complete, fully programmable core, reusing
existing tool chains and operational practices.

Reference: Tom Herbert, ["Parser Instructions: World's fastest and most flexible
protocol parsing"](https://tomaherbert.com/parser-instructions-worlds-fastest-most-flexible-protocol-parsing-0d366cd4dfc5)
(US patent 12,461,885).

## Status

📝 **Design phase.** This repo currently holds the *design-doc set* only — no RTL
yet. The docs plan the full journey so it can be executed phase by phase.

## Repo map

```
docs/          Design documentation (start here)
model/         Golden C reference model            (Phase 2)
isa/           Machine-readable encoding tables     (Phase 3)
rtl/           SystemVerilog parser unit            (Phase 5)
tb/            cocotb / Verilator testbench         (Phase 6)
corpus/        Packet corpus (incl. malformed)      (Phase 2)
toolchain/     .insn macros, intrinsics, sim patches (Phase 7)
fpga/          Board build + block design           (Phase 8)
bench/         Benchmark harness + results          (Phase 9)
flake.nix      Nix flake — reproducible dev environment (`nix develop`)
nix/           Modular Nix files (tool groups, dev shell)
LICENSE        Public domain (Unlicense)
```

The source directories are skeletons (a README each) until their phase lands.

## Development environment

All tooling (Verilator, cocotb, poppler, Spike, QEMU, …) is provided by a **Nix
flake** so every contributor gets the same versions:

```sh
nix develop      # enter the dev shell
rtl-help         # list the tools
```

See **[docs/nix.md](docs/nix.md)** for the layout and how to extend it.

## Read the docs

| Doc | What it covers |
|-----|----------------|
| [docs/README.md](docs/README.md) | Index + reading order + phase status |
| [docs/00-overview.md](docs/00-overview.md) | **The whole-project design doc — start here** |
| [Phase 0 — Scope & stack](docs/phase-0-scope-and-stack.md) | Goals, core selection, first vertical slice |
| [Phase 1 — ISA spec](docs/phase-1-isa-spec.md) | Parser registers & instruction semantics |
| [Phase 2 — Reference model](docs/phase-2-reference-model.md) | Golden C model + packet corpus |
| [Phase 3 — Encoding](docs/phase-3-encoding.md) | `custom-0..3` opcode allocation |
| [Phase 4 — Microarchitecture](docs/phase-4-microarchitecture.md) | Parser datapath & core integration |
| [Phase 5 — RTL](docs/phase-5-rtl.md) | SystemVerilog implementation |
| [Phase 6 — Verification](docs/phase-6-verification.md) | Co-simulation vs golden model |
| [Phase 7 — Toolchain](docs/phase-7-toolchain.md) | Assembler, LLVM/GCC, Spike/QEMU |
| [Phase 8 — FPGA](docs/phase-8-fpga.md) | Prototype & bring-up |
| [Phase 9 — Benchmark](docs/phase-9-benchmark.md) | flow_dissector comparison |

## How to read

Read `docs/00-overview.md` first for the full picture, then follow the phase docs
in order. Each phase doc is self-contained and links to the previous/next phase.
Anything not yet locked down is marked **TBD** or **Decision** so the docs stay
honest about what's decided vs. open.
