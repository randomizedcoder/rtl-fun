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
- 🔵 **Phase 5 (in progress) — RTL:** the parser datapath is implemented in
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
  (`nix run .#cva6-parser-test` → fesvr `tohost` PASS). Remaining: generate
  `parser_pkg` from `isa/`; the packet-data feed + CAM programming (Phase 8)
  ([`docs/analysis/cva6-integration.md`](docs/analysis/cva6-integration.md) §8).
- 🔵 **Phase 6 (in progress) — Verification:** the verification foundation is in
  place across all four techniques, every target green from the flake:
  **toggleable design assertions** (`rtl/parser_asserts.svh`, on in every sim,
  gone from synthesis); a **SymbiYosys formal proof** that `parser_execute` never
  writes metadata out of bounds and always exits with a valid code, for all inputs
  (`nix run .#parser-formal`); a **directed suite** of 15 positive / negative /
  boundary / corner packets — IPv4/IPv6, VLAN, QinQ, IPv6 ext + fragment, malformed
  and truncated — each matched byte-for-byte and by exit code against the model
  (`nix run .#parser-sim-suite`); and **static analysis + fuzzing** — verible +
  svlint on the RTL (`nix run .#parser-analyze`), cppcheck + gcc `-fanalyzer` +
  clang-tidy + ASan/UBSan on the model (`nix run .#model-analyze`), and libFuzzer
  + ASan/UBSan on random packets (`nix run .#model-fuzz`). The in-core FU is being
  hardened increment by increment against a [status tracker](docs/analysis/cva6-implementation-status.md):
  **I1** speculation-safe commit-visible parser state, **I2** commit-gated metadata
  sink (first in-core value-check), **I3** custom-3 register readback, **I4a**
  end-of-node fetch redirect (node-index→byte-PC), and **I4b** CAM programming from the
  integer side (custom-3 `CPPRSWR`/`CPPRSWRCAM`/`CPPRSRDCAM`, rs1 threaded from
  `ex_stage`) with a CAM-hit `CAMNEXT` driving a real fetch redirect — all green in-core
  via `nix run .#cva6-parser-test`. Remaining: the full RTL↔model corpus co-simulation
  (cocotb + DPI-C) and coverage sign-off.

The parser unit now exists as synthesizable RTL ([`rtl/`](rtl/README.md)); the
remaining source dirs (`tb/`, `fpga/`) are skeletons until their phase lands
(per-phase status: [docs/README.md](docs/README.md)). Deferred: 64-bit instruction
form, the array/counter/TLV-loop encoder+execution, and tunnel protocols
(GRE/GTP/VXLAN).

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
