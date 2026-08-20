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

🔨 **Executing phase by phase.** The full [design-doc set](docs/README.md) is
complete; phases are now being built in order.

- ✅ **Phase 0 — Scope & stack:** base core locked (CVA6, RV64GC); the stock CVA6
  Verilator model builds end-to-end from Nix (`nix run .#cva6-baseline`) with the
  RISC-V cross-toolchain; reproducibility snapshot in
  [docs/environment.md](docs/environment.md).
- ✅ **Phase 1 — ISA spec:** normative, patent-cited
  [per-instruction semantics](docs/phase-1-isa-semantics.md) for the vertical slice.
- ✅ **Phase 2 — Golden model + corpus:** the C reference model
  (`model/libparsermodel`) parses Ethernet, VLAN (802.1Q/802.1ad, stacked), IPv4
  (with options), IPv6 (with hop-by-hop/routing/fragment/dest-opts extension
  headers), TCP and UDP into a `flow_keys`. It passes directed, malformed (§2.3),
  and corpus tests against a pinned [xdp2](https://github.com/randomizedcoder/xdp2)
  `proto_audit` corpus — all 306 Ethernet pcaps terminate cleanly, no
  crashes/hangs (`nix run .#model-test`). Debug a parse with `nix run .#pm-trace`.
- ✅ **Phase 3 — Instruction encoding:** the patent's bit-accurate scheme
  (custom-0 `0x0b` + `Fnc4`; custom-3 `0x7b` coprocessor) as a machine-readable
  table ([`isa/parser-opcodes.yaml`](isa/parser-opcodes.yaml)) with a C
  encoder/decoder in the model and `.insn` emitters
  ([`toolchain/parser_insn.h`](toolchain/parser_insn.h)); every slice instruction
  round-trips (`nix run .#model-test`).
- ✅ **Phase 4 — Microarchitecture:** the parser datapath (align → endian →
  shift/mask extract, bounds/length/compare, CAM, two-stage end-of-node), a 256 B
  packet buffer with a 128-bit read window, and a 32×64-bit parser register file
  with a single-in-flight hazard interlock — all decided at signal-interface
  granularity. The CVA6 integration is mapped to the **pinned v5.3.0 source**
  ([`docs/analysis/cva6-integration.md`](docs/analysis/cva6-integration.md)):
  custom-0 becomes a new in-pipeline `fu_t::PARSER` that reuses CVA6's
  `resolved_branch_o` path for end-of-node fetch redirect, and the custom-3
  coprocessor moves attach via CV-X-IF.
- ✅ **Phase 5 — RTL:** the parser datapath is implemented in
  synthesizable SystemVerilog ([`rtl/`](rtl/README.md)) as a hardware `pm_run` and
  **runs the vertical slice in Verilator, producing a `flow_keys` that matches the
  golden model byte-for-byte** (`nix run .#parser-sim`). Lint-clean under `-Wall`,
  with four Verilator targets at different debug levels
  (`parser-sim{,-trace,-debug}`, `parser-lint`). The 32-bit word decoder
  (`parser_decode.sv`) is proven equivalent to the model over the whole suite
  (`nix run .#parser-sim-decode`), and the **in-core CVA6 patch is complete**:
  custom-0/custom-3 route to a new `fu_t::PARSER`, issue over a ready/valid
  handshake, execute in the EX-stage FU (`cva6_parser_wrap`), retire via a new
  writeback port, and can redirect fetch via `resolved_branch_o`. The patched core
  builds (`nix run .#cva6-parser`) with no baseline regression, and a bare-metal
  custom-0 program **issues, executes, and retires in-core**
  (`nix run .#cva6-parser-test` → fesvr `tohost` PASS). The **packet-data feed + CAM
  programming are real** (I5): a SoC AXI MMIO peripheral (`nix/cva6-parser/
  mmio.patch`) bridges `sd`/`ld` into the FU's `parser_pktbuf` write port + commit-gated
  flow_keys frame, and the CAM is programmed at runtime from the integer side — so a
  program parses a packet end-to-end in-core. All exit criteria met; the lone leftover
  (generate `parser_pkg` from `isa/`) is a cosmetic refactor, not a gate.
- ✅ **Phase 6 — Verification:** the correctness gate is met — the RTL is proven
  equal to the golden model (fields **and** exit status) across the corpus, and the
  in-core FU is verified end-to-end. The foundation is green across all four
  techniques from the flake: **toggleable design assertions**
  (`rtl/parser_asserts.svh`, on in every sim, gone from synthesis); **SymbiYosys
  formal proofs** — `parser_execute` never writes metadata out of bounds / always
  exits valid, and `cva6_parser_wrap` never leaks speculative parser state past a
  flush (G2 k-induction), for all inputs (`nix run .#parser-formal`); a **directed
  suite** of 22 positive / negative / boundary / corner packets — IPv4/IPv6, VLAN,
  QinQ, IPv6 ext + fragment, malformed and truncated — each matched byte-for-byte and
  by exit code against the model (`nix run .#parser-sim-suite`); and **static
  analysis + fuzzing** — verible + svlint on the RTL (`nix run .#parser-analyze`),
  cppcheck + gcc `-fanalyzer` + clang-tidy + ASan/UBSan on the model
  (`nix run .#model-analyze`), and libFuzzer + ASan/UBSan on random packets
  (`nix run .#model-fuzz`). The in-core FU is hardened through increments **I1–I5**
  (see the [status tracker](docs/analysis/cva6-implementation-status.md)), culminating
  in the full **in-core packet→flow_keys co-simulation over real MMIO** — all 22 corpus
  packets parse in the CVA6 pipeline and match the model **byte-for-byte + exit code**
  (`nix run .#cva6-parser-cosim`, 22/22). A **per-instruction RVFI-vs-Spike lock-step**
  then steps an extended Spike (its custom extension reuses `libparsermodel`) beside
  the core and compares every retired instruction — base ISA (287/287), parser ops
  (43/0), the 22-packet corpus (0 mismatches) — plus a **constrained-random +
  real-corpus packet campaign** (`nix run .#cva6-parser-tandem` /
  `.#cva6-parser-tandem-campaign`). *(That lock-step tandem is the project's Phase-6
  verification oracle; its PRs are commit-tagged "Phase 7 Stage N", but the work is
  classified as Phase-6 verification, not the Phase-7 toolchain.)* Sign-off is
  complete: **negative control** (`nix run .#parser-negative-control`, G11),
  **base-ISA regression** (`nix run .#cva6-parser-baseisa`), a **2nd config**
  (`nix run .#cva6-parser-config-wb`, G10), the interrupt / fault / context-switch
  rows (V6/V7/V10/M1), and **coverage closure** (`nix run .#parser-coverage`, 100% of
  the functional op×event×exit bins, G12). Gaps **G1–G13 are closed**; **G14
  (timing/physical) belongs to Phase 8**. The only §6.1 item not built as literally
  specified — a **cocotb + DPI-C** corpus harness — is *superseded*: its goal is met
  by the Verilator suite + in-core MMIO cosim + tandem campaign.
- 🔵 **Phase 7 (in progress) — Toolchain:** the software-tooling ladder. **Level 1**
  (`.insn` + intrinsics, [`toolchain/parser_insn.h`](toolchain/parser_insn.h)) and
  **Level 2** (binutils as/objdump — a parser-patched `riscv64-none-elf` binutils
  assembles the `prs.*` mnemonics with readable, round-tripping disassembly — Hybrid
  syntax plus additive prose sugar `pcurptr+N`/`paccum[i]`/`value:mask`;
  `nix run .#parser-asm-test`) are done, and **Level 4 Spike** now runs standalone
  (`nix run .#parser-spike`: a runnable `spike` with the parser extension + `0x5000_0000`
  packet MMIO runs the 22-case corpus == the golden model — distinct from the Phase-6
  `spike-tandem` oracle). Still open: the prose-freeze follow-on (`.stp`/`.fail`
  qualifiers, `mult:min`, mnemonic aliases, …), **LLVM MC / GCC builtins** (L3), **QEMU**
  modeling (L4), a C-intrinsics rewrite of the slice parser running on Spike **and** QEMU
  matching the model (the exit criterion), and the heavyweight random-*instruction* checks
  (full upstream riscv-tests; riscv-dv, blocked on a commercial UVM simulator).

The parser unit now exists as synthesizable RTL ([`rtl/`](rtl/README.md)), with its
testbenches in [`tb/`](tb/README.md) and the vector generator + formal harness in
[`verif/`](verif/README.md); the remaining source dirs (`corpus/`, `fpga/`) are
skeletons until their phase lands (per-phase status: [docs/README.md](docs/README.md)). Deferred: 64-bit instruction
form, the array/counter/TLV-loop encoder+execution, and tunnel protocols
(GRE/GTP/VXLAN).

## Repo map

```
docs/          Design documentation (start here; testing map: docs/testing-overview.md)
model/         Golden C reference model            (Phase 2)
isa/           Machine-readable encoding tables     (Phase 3)
rtl/           SystemVerilog parser unit — synthesizable RTL only (Phase 5)
tb/            SystemVerilog testbenches (scaffold + smoke + wrap) (Phase 6)
verif/         Vector generator (verif/gen) + formal harness (verif/formal) (Phase 6)
tests/         In-core CVA6 test programs (parser_insn.S, cosim_main.S) (Phase 5/6)
scripts/       Bodies of the `nix run .#<app>` runners (readFile'd into nix)
tools/         Reusable dev utilities (pm-trace, bitgen)
corpus/        Packet corpus skeleton (incl. malformed) (Phase 2)
toolchain/     .insn macros, intrinsics, MMIO map      (Phase 7)
fpga/          Board build + block design           (Phase 8)
bench/         Benchmark harness + results          (Phase 9)
flake.nix      Nix flake — reproducible dev environment (`nix develop`)
nix/           Modular Nix files (tool groups, dev shell, CVA6 patches)
LICENSE        Public domain (Unlicense)
```

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
| [docs/testing-overview.md](docs/testing-overview.md) | **How the parser is tested** — the four test layers + which `nix run` runs each |
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
