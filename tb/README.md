# tb/ — SystemVerilog testbenches (Phase 5/6)

The Verilator testbenches that exercise the [`rtl/`](../rtl/README.md) parser unit.
Kept out of `rtl/` (which holds only synthesizable RTL) so the design and the harness
that tests it stay cleanly separated. For the whole test story — all four layers and
which `nix run .#<app>` runs each — see
[`docs/testing-overview.md`](../docs/testing-overview.md).

```
parser_top.sv        bring-up scaffold: program ROM + micro-PC + metadata RAM
                     (stands in for CVA6 fetch+redirect so the datapath runs solo).
                     Not synthesizable core RTL — a sim harness.
parser_smoke_tb.sv   standalone RTL-vs-model suite testbench (assertion-based,
                     `CHECK` macro; reads per-packet params at runtime so one build
                     runs every directed case). Top for parser-sim / -suite / -decode.
parser_wrap_tb.sv    assertion-based testbench for cva6_parser_wrap: I1 commit/flush
                     rollback + backpressure, I2 metadata, I3 readback, I4a/I4b
                     redirect + CAM + V11 reset/X, V4 WAW, store-bound (11
                     scenarios). Top for parser-wrap-test.
```

These compile against the synthesizable units in `rtl/` (via Verilator `-I rtl`,
which also resolves `parser_asserts.svh`) plus the model-generated vectors from
[`verif/gen/`](../verif/README.md). The scaffold reads `program.hex`/`cam.hex`/
`enc.hex`/`packet.hex` and the testbench reads `params.hex`/`expected.hex` at
runtime via `$readmemh` (per-case, from the run directory).

## Run

```sh
nix run .#parser-sim         # smoke test (parser_top + parser_smoke_tb)
nix run .#parser-sim-suite   # directed suite: pos/neg/boundary/corner packets
nix run .#parser-sim-decode  # same suite via parser_decode (32-bit words)
nix run .#parser-wrap-test   # cva6_parser_wrap commit/flush/redirect scenarios
```

The build bodies live in [`scripts/parser-sim.sh`](../scripts/parser-sim.sh) and
[`scripts/parser-wrap-test.sh`](../scripts/parser-wrap-test.sh); the vector
generator in [`verif/gen/gen_parser_rom.c`](../verif/gen/gen_parser_rom.c).

*(The cocotb co-simulation harness this skeleton originally anticipated was not the
path taken — the RTL-vs-model comparison is done with these SystemVerilog
testbenches and the in-core drivers in [`tests/cva6-parser/`](../tests/cva6-parser/)
instead.)*
