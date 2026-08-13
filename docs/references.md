# References

External material referenced by the design docs. Links are informational; where a
page is paywalled or 403s, the key facts are summarized in the relevant doc.

> 📁 **Local copies** of the key sources live in
> [`references/`](references/README.md) so the repo is self-contained — see that
> folder's README for provenance & licensing. Entries below link to the local copy
> where one exists (📄), otherwise to the upstream URL.

## Primary sources

- **Tom Herbert — "Parser Instructions: World's fastest and most flexible protocol
  parsing"** (Nov 2025). 📄 [local copy](references/herbert-parser-instructions.md) ·
  <https://tomaherbert.com/parser-instructions-worlds-fastest-most-flexible-protocol-parsing-0d366cd4dfc5>
  (live page returns 403 to fetchers). The originating blog post. Source of the
  instruction set, parser registers, worked Ethernet/IPv4 example, and performance
  figures.
- **US Patent 12,461,885 — "Parser instructions for CPUs"** (Tom Herbert).
  📄 [Google export (text)](references/patent-us12461885.pdf) ·
  📄 [USPTO PDF (108 drawing sheets)](references/uspto-patent-us12461885.pdf) ·
  [Google Patents](https://patents.google.com/patent/US12461885B2/en). Bit-field
  encodings extracted from the drawings:
  [`analysis/patent-encodings-recovered.md`](analysis/patent-encodings-recovered.md).
  Describes the underlying PANDA parser approach: parser state (current offset /
  header length), bounds checks, metadata extraction, next-protocol
  determination, and native TLV / flag-field handling.
- **XDP2 / PANDA parser** — Herbert's parser framework and programming model; the
  protocol-table source and the general parser programming model this ISA lowers
  to. (Compared against Linux `flow_dissector` in prior PANDA work.)

## RISC-V

- **RISC-V ISA Manual** (unprivileged + privileged) — defines the `custom-0..3`
  major opcodes reserved for non-standard extensions, and the R/I/S instruction
  formats. 📄 [local copy](references/riscv-isa-manual-2026-08-04.pdf) (release
  `ba25a36`, 2026-08-04, CC-BY-4.0) ·
  <https://riscv.org/technical/specifications/>
- **RISC-V `.insn` assembler directive** — emit raw custom encodings without a
  full binutils change. (GNU as / LLVM MC documentation.)

## Base cores

- **CVA6 (OpenHW Group)** — RV64GC 6-stage in-order application core in
  SystemVerilog; our chosen base. <https://github.com/openhwgroup/cva6>
- **Ibex (lowRISC)** — small RV32 in-order core (OpenTitan); documented lighter
  alternative. <https://github.com/lowRISC/ibex>
- *(Considered, not chosen)* VexRiscv (SpinalHDL, plugin architecture);
  Rocket Chip + RoCC (Chisel, loosely-coupled coprocessor interface).

## Software baseline

- **Linux `flow_dissector`** (`net/core/flow_dissector.c`) — the reference
  software flow-key extractor and the primary benchmark baseline.
  📄 [local copy](references/linux-flow_dissector.c) (GPL-2.0-only) ·
  <https://github.com/torvalds/linux/blob/master/net/core/flow_dissector.c>

## Verification & simulation tooling

- **Verilator** — fast SystemVerilog simulator for co-simulation.
  <https://www.veripool.org/verilator/>
- **cocotb** — Python coroutine-based HDL testbench framework.
  <https://www.cocotb.org/>
- **Spike** — the RISC-V ISA simulator (golden ISA reference for the toolchain).
  <https://github.com/riscv-software-src/riscv-isa-sim>
- **QEMU (RISC-V)** — for faster functional runs once instructions are modeled.

## Toolchain

- **riscv-gnu-toolchain** (binutils/GCC), **LLVM/Clang** (MC layer, intrinsics,
  builtins) — for eventual first-class assembler/compiler support.
