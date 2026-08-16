# rtl/ — SystemVerilog parser unit (Phase 5)

The parser execution unit and its integration into CVA6. The datapath is
implemented and runs the vertical slice in Verilator, producing a `flow_keys`
that matches the golden C model byte-for-byte.

```
parser_pkg.sv        types, params, ROM word layout, extract_subreg / bswap_n
parser_pktbuf.sv     packet buffer + 128-bit read window + byte aligner
parser_cam.sv        behavioural CAM (20-bit key -> 32-bit target), loadable
parser_execute.sv    the parser functional unit — a hardware exec_one +
                     common_end_of_node (one branch per model execute_*)
parser_top.sv        bring-up scaffold: program ROM + micro-PC + metadata RAM
                     (stands in for CVA6 fetch+redirect so the datapath runs solo)
parser_smoke_tb.sv   Verilator testbench (assertion-based, `CHECK` macro)
cva6_parser_wrap.sv  the in-pipeline FU as it attaches to CVA6 (interface fidelity)
gen/gen_parser_rom.c host generator: model -> program/CAM/packet/expected vectors
```

The RTL is a **hardware `pm_run`**: it interprets the SAME decoded program the C
[model](../model/README.md) runs (`gen/gen_parser_rom.c` emits the vectors from
`pm_slice_program()` — one source of truth, no second copy), so Phase-6
co-simulation compares like with like.

## Run

```sh
nix run .#parser-sim         # optimized, run the smoke test (fast default)
nix run .#parser-sim-trace   # + VCD waveform (build/parser/parser.vcd)
nix run .#parser-sim-debug   # -O0 -ggdb + waveform, for gdb
nix run .#parser-lint        # --lint-only -Wall, no build
```

Lint-clean under Verilator `-Wall` (width/latch/`UNOPTFLAT` fatal;
`UNUSEDPARAM`/`UNUSEDSIGNAL` waived for the shared ISA package). See
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

`parser_decode.sv` (32-bit Phase-3 word → `micro_op_t`, which also lets
`parser_pkg` be generated from [`isa/`](../isa/README.md)) and the in-core CVA6
decode/issue/EX patch. See [`docs/phase-5-rtl.md`](../docs/phase-5-rtl.md) §5.2/§5.5.
