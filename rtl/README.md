# rtl/ — SystemVerilog parser unit (Phase 5/6)

The parser execution unit and its integration into CVA6 — **synthesizable RTL only**.
The datapath is implemented and runs the vertical slice in Verilator, producing a
`flow_keys` that matches the golden C model byte-for-byte. Testbenches live in
[`tb/`](../tb/README.md); the vector generator and formal harness in
[`verif/`](../verif/README.md).

```
parser_pkg.sv        types, params, ROM word layout, extract_subreg / bswap_n
parser_pktbuf.sv     packet buffer + 128-bit read window + byte aligner
                     + a clocked 64-bit write port (MMIO packet preload, I5)
parser_cam.sv        behavioural CAM (20-bit key -> 32-bit target); $readmemh-loadable
                     + a clocked program/delete port (custom-3 CPPRSWRCAM, I4b)
parser_execute.sv    the parser functional unit — a hardware exec_one +
                     common_end_of_node (one branch per model execute_*)
parser_decode.sv     32-bit Phase-3 word -> micro_op_t (the CVA6 decode path;
                     RTL twin of model encoding.c / isa/parser-opcodes.yaml)
cva6_parser_wrap.sv  the in-pipeline FU as it attaches to CVA6 (interface fidelity):
                     commit-gated state + flow_keys frame (I1/I2), custom-3 readback
                     + CAM program (I3/I4b), end-of-node & parse-exit fetch redirect,
                     and MMIO meta-read / ParseLen / exit-PC / status ports (I5)
parser_asserts.svh   toggleable assertion macros (PRS_ASSERT / PRS_ASSERT_I):
                     real SVA under +define+PARSER_ASSERT / +FORMAL, else nothing
.rules.verible_lint  verible project rules (ALL_CAPS params, explicit ranges)
.svlint.toml         svlint correctness-rule config
```

Related, outside `rtl/`:

```
tb/parser_top.sv         bring-up scaffold: program ROM + micro-PC + metadata RAM
tb/parser_smoke_tb.sv    standalone RTL-vs-model suite testbench
tb/parser_wrap_tb.sv     assertion-based cva6_parser_wrap testbench (8 scenarios)
verif/gen/gen_parser_rom.c  host generator: model -> program/CAM/packet/expected/enc
verif/formal/            SymbiYosys harness + .sby proving parser_execute safety
```

> **Testing map.** For how this RTL is exercised across all four test layers (the
> standalone suite, the in-core directed tests, the in-core cosim, and formal) and
> which `nix run` runs each, see [`docs/testing-overview.md`](../docs/testing-overview.md).

The RTL is a **hardware `pm_run`**: it interprets the SAME decoded program the C
[model](../model/README.md) runs (`verif/gen/gen_parser_rom.c` emits the vectors from
`pm_slice_program()` — one source of truth, no second copy), so Phase-6
co-simulation compares like with like.

## Run

```sh
nix run .#parser-sim         # optimized, run the smoke test (fast default)
nix run .#parser-sim-suite   # directed suite: pos/neg/boundary/corner packets
nix run .#parser-sim-decode  # directed suite via parser_decode (32-bit words)
nix run .#parser-sim-trace   # + VCD waveform (build/parser/parser.vcd)
nix run .#parser-sim-debug   # -O0 -ggdb + waveform, for gdb
nix run .#parser-lint        # --lint-only -Wall, no build
nix run .#parser-analyze     # extra SV lint: verible + svlint
nix run .#parser-formal      # SymbiYosys proof of parser_execute safety
```

Assertions are compiled into every sim (`+define+PARSER_ASSERT`). Lint-clean under
Verilator `-Wall` (width/latch/`UNOPTFLAT` fatal; `UNUSEDPARAM`/`UNUSEDSIGNAL`
waived for the shared ISA package), and clean under verible + svlint. See
[`docs/phase-6-verification.md`](../docs/phase-6-verification.md) for the
verification foundation, and
[`docs/phase-5-rtl.md`](../docs/phase-5-rtl.md) §5.6 for the target/debug-level
design, and [`docs/analysis/cva6-integration.md`](../docs/analysis/cva6-integration.md)
for the file/signal map of the CVA6 patch.

## Contracts (from Phase 4)

- **Unit interfaces** (ports/widths per leaf unit) —
  [`docs/phase-4-microarchitecture.md`](../docs/phase-4-microarchitecture.md) §4.6.
- **CVA6 seam** (`fu_t::PARSER`, `resolved_branch_o` redirect, CV-X-IF for
  custom-3, patch checklist) —
  [`docs/analysis/cva6-integration.md`](../docs/analysis/cva6-integration.md).

## Next increment

The in-core CVA6 decode/issue/EX patch (`parser_decode.sv` is done — proven by
`nix run .#parser-sim-decode`), plus generating `parser_pkg` from
[`isa/`](../isa/README.md). See [`docs/phase-5-rtl.md`](../docs/phase-5-rtl.md) §5.2/§5.5
and [`docs/analysis/cva6-integration.md`](../docs/analysis/cva6-integration.md) §8.
