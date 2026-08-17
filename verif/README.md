# verif/ — verification infrastructure (Phase 6)

The pieces that *generate* and *formally prove*, as opposed to the testbenches that
*run* (those live in [`tb/`](../tb/README.md)). Kept out of `rtl/` so it holds only
synthesizable RTL. For the whole test story see
[`docs/testing-overview.md`](../docs/testing-overview.md).

```
gen/gen_parser_rom.c   host generator: runs the golden C model over the case table
                       (`suite[]`) and emits the vectors — program.hex, cam.hex,
                       enc.hex, camprog.hex, packet.hex, expected.hex, params.hex,
                       cases.txt. THE single source of truth for both the standalone
                       suite (tb/) and the in-core cosim (tests/cva6-parser/).
formal/
  parser_execute_fp.sv SymbiYosys formal wrapper around parser_execute
  parser_execute.sby   the proof: 1-step BMC (parser_execute is combinational, so
                       this is exhaustive) of the memory-safety + exit-code invariants
```

## One generator, two consumers

`gen/gen_parser_rom.c` is the lever the whole verification plan turns on: a new row
in `suite[]` flows into **both** the standalone RTL suite and the in-core co-sim
automatically, because both read its output (the standalone suite via RTL
`$readmemh`, the cosim by munging the same `enc.hex`/`camprog.hex`/packet vectors
into assembly). The generator self-checks each case against the model and fails the
build (exit 3) on disagreement, so a bad expectation can never reach a test.

It is compiled and invoked by the runner scripts, not built by Nix into the store —
[`scripts/parser-sim.sh`](../scripts/parser-sim.sh),
[`scripts/cva6-parser-cosim.sh`](../scripts/cva6-parser-cosim.sh), and
[`scripts/model-analyze.sh`](../scripts/model-analyze.sh) each `cc` it against
`model/libparsermodel` at run time.

## Run

```sh
nix run .#parser-formal      # SymbiYosys proof of parser_execute safety (verif/formal)
nix run .#parser-sim-suite   # standalone suite — consumes verif/gen output
nix run .#cva6-parser-cosim  # in-core cosim — consumes verif/gen output
```

The formal build body is [`scripts/parser-formal.sh`](../scripts/parser-formal.sh)
(sv2v flatten → yosys/SymbiYosys); it flattens `rtl/parser_pkg.sv` +
`rtl/parser_execute.sv` + `formal/parser_execute_fp.sv`.
