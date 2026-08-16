# Phase 5 — RTL implementation

← [Phase 4](phase-4-microarchitecture.md) · [Docs index](README.md) · [Phase 6 »](phase-6-verification.md)

## Objective

Implement the parser unit in synthesizable **SystemVerilog** realizing the
[Phase 4](phase-4-microarchitecture.md) microarchitecture, and run the vertical
slice in Verilator against the golden model.

## Status — decode path landed

Update (this increment): **`parser_decode.sv` is done and verified.** It turns a
32-bit Phase-3 custom-0 word into a `micro_op_t` — the RTL twin of the model's
`encoding.c` (`pm_decode_opcode` + per-group field extraction) and of
`isa/parser-opcodes.yaml`, same bit positions. It is proven by a **decode
co-simulation**: `nix run .#parser-sim-decode` sources the *entire* directed
suite's program from the 32-bit words (`enc.hex`, emitted by the generator via
`pm_encode`) decoded through `parser_decode`, and every one of the 15 cases
produces a `flow_keys` and exit code byte-identical to the model — i.e. the
decoder is behaviourally equivalent to the model's decoded-instruction table over
the whole suite. (One faithful model fix rode along: `PSTP` now round-trips
exactly, distinguished from `PSETCODE` by the `V` bit, so a decoded program stops
where the model's does.) The in-core CVA6 decode/issue/EX patch is next.

## Status — executed (first slice)

The parser datapath is implemented and **runs the whole slice in Verilator**,
producing a `flow_keys` that matches the golden C model **byte-for-byte**
(`nix run .#parser-sim` → 50 checks, 0 failures, exit code `STOP_OKAY`). The RTL
is a hardware `pm_run`: it interprets the *same decoded program* the model runs
(model/libparsermodel), so the model and the silicon share one program.

Delivered this increment:
- **Leaf datapath** (`rtl/`): `parser_pkg` (types/params/sub-register fn),
  `parser_pktbuf` (packet buffer + 128-bit window + aligner), `parser_cam`
  (behavioural CAM), `parser_execute` (the FU: a hardware `exec_one` +
  `common_end_of_node`, one `execute_*` branch per model routine).
- **Bring-up scaffold** `parser_top` + Verilator testbench `parser_smoke_tb`
  (assertion-based, `` `CHECK `` macro), driven from vectors generated off the
  model by `rtl/gen/gen_parser_rom.c` (single source of truth — no second copy).
- **CVA6 seam** `cva6_parser_wrap` at interface fidelity: the in-pipeline FU with
  the exact CVA6-shaped ports (issue handshake, `resolved_branch_o` redirect,
  packet-window + CAM), holding persistent parser state and driving end-of-node.
- **Nix targets** at four debug levels (below), all lint-clean under `-Wall`.

Deferred to the next increment (honest scope):
- **`parser_decode`** — 32-bit Phase-3 word → `micro_op_t` (the CVA6 decode path).
  The slice currently runs a model-generated micro-op ROM because CAM/next
  *targets* are resolved at run time and are not in the instruction word (see
  `model/.../encoding.h`); decoding drives the CVA6 decoder patch, not the ROM.
- **The in-core CVA6 patch** (decode/issue/EX wiring, `fu_t::PARSER`) —
  specified file-by-file in [`analysis/cva6-integration.md`](analysis/cva6-integration.md) §8.
- **The rest of the slice on RTL is already covered**: because the executor is
  program-driven, VLAN / IPv6-ext paths run with no new RTL once their packets are
  fed — exercised systematically in [Phase 6](phase-6-verification.md).

## Design detail

### 5.1 Module breakdown

```
rtl/
  parser_pkg.sv        types, params, ROM word layout, extract_subreg/bswap_n
  parser_pktbuf.sv     packet buffer + 128-bit window + byte aligner
  parser_cam.sv        behavioural CAM (20-bit key -> 32-bit target), loadable
  parser_execute.sv    the parser FU: hardware exec_one + common_end_of_node
  parser_top.sv        bring-up scaffold: ROM + micro-PC + metadata RAM (sim)
  parser_smoke_tb.sv   Verilator testbench (assertion-based)
  cva6_parser_wrap.sv  the in-pipeline FU as it attaches to CVA6 (interface fidelity)
  parser_decode.sv     32-bit Phase-3 word -> micro_op_t (the CVA6 decode path)
  gen/gen_parser_rom.c host generator: model -> program/CAM/packet/expected/enc vectors
```

`parser_pkg` mirrors the model's machine state and decoded-instruction table;
its ROM word layout is shared with `gen_parser_rom.c` so bits never drift between
model, generator, and RTL. Full constant generation from `isa/parser-opcodes.*`
(so `parser_pkg` is generated, not hand-written) rides on `parser_decode`.

### 5.2 Decode

`parser_decode.sv` turns a 32-bit custom-0 word into a `micro_op_t`, mirroring
`model/libparsermodel/encoding.c` and [`isa/parser-opcodes.yaml`](../isa/parser-opcodes.yaml)
bit-for-bit (LSB0 numbering, `Fnc4`→opcode group, per-group field slots). It is a
pure combinational unit; CAM/next *targets* are not in the word (they live in the
CAM table, resolved at run time), so the decoder produces every micro-op field the
executor needs and the target arrives on `cam_target_i`. It is proven by the
decode co-sim (§5.6, `parser-sim-decode`).

The **in-core** decode patch is landed: `nix/cva6-parser/decode.patch` adds
`PARSER` to `fu_t` (+ `PARSER_C0`/`PARSER_C3` `fu_op`s) and routes `custom-0`/
`custom-3` to `fu = PARSER` in `decoder.sv`. It applies to the pinned source in a
cached derivation (`cva6-parser-src`), and `nix run .#cva6-parser` builds the
patched CVA6 Verilator model — it elaborates through the full core with no
baseline regression (compare `nix run .#cva6-baseline`). The parser micro-op is
decoded **inside** the FU by `parser_decode.sv` from the raw instruction word, so
the core decoder only routes. Still pending: ISSUE routing/handshake and the EX
FU instantiation + `resolved_branch_o` redirect —
[`analysis/cva6-integration.md`](analysis/cva6-integration.md) §3/§8.

### 5.3 Execute & handshake

`cva6_parser_wrap` implements the ready/valid handshake with CVA6 issue and holds
the persistent parser registers; `parser_execute` computes the next state
combinationally (single-cycle for the slice). The scaffold `parser_top` instead
owns a micro-PC so the datapath can run a whole program standalone in sim.

### 5.4 Writeback, redirect & exceptions

- Normal: update the parser registers; custom-0 writes no integer `rd`.
- End-of-node with a node/loop target: assert `resolve_branch_o` + `redirect_pc_o`
  (reuses CVA6's branch-resolution path — Phase-4 D4).
- Parse exit (okay/fail or bounds/length/compare failure): `parse_exit_o` +
  `parse_code_o` (`ParserExitCode`), via the same redirect path — no CPU trap.

### 5.5 Coding standards & lint

- Synthesizable SystemVerilog; `_q`/`_n` registers, `unique case`, no latches.
- **Lint-clean under Verilator `-Wall`** — all width/latch/combinational-loop
  (`UNOPTFLAT`) classes are fatal. `UNUSEDPARAM`/`UNUSEDSIGNAL` are waived: the
  package defines the full ISA vocabulary and datapath temporaries are wider than
  any single use (standard for a shared package). Run: `nix run .#parser-lint`.
- Widths parameterised (`PKT_WINDOW_W`, `CAM_DEPTH`, `PKT_MAX`) for sizing sweeps.

### 5.6 Simulation targets (Nix)

The flake exposes the parser sim at **four debug levels**, all from one script
body (`scripts/parser-sim.sh`, selected by `PARSER_MODE`) so they can't drift, and
all lint-clean. Vectors are regenerated from the model on every run.

| Target | Verilator flags | Use |
|--|--|--|
| `nix run .#parser-sim` | `--binary -O3 --assert +define+PARSER_ASSERT` | fast smoke test (default) |
| `nix run .#parser-sim-suite` | `+ per-case packet/params.hex` | directed suite (pos/neg/boundary/corner) — see [Phase 6](phase-6-verification.md) |
| `nix run .#parser-sim-decode` | `+ +define+PARSER_DECODE` | directed suite via `parser_decode` (32-bit words → micro-ops); proves decode == model |
| `nix run .#parser-sim-trace` | `+ --trace --trace-structs +define+DUMP` | VCD waveform (packed `pstate_t`/`micro_op_t` by name) → `build/parser/parser.vcd` |
| `nix run .#parser-sim-debug` | `-O0 -CFLAGS "-O0 -ggdb" + trace` | step the verilated model in gdb, with waves |
| `nix run .#parser-lint` | `--lint-only -Wall` | fast strict lint, no build |

VCD (not FST) is used so no `lz4` is needed in the shell. Waveforms open in
GTKWave; `--trace-structs` renders the parser state struct field-by-field.
Assertions (`--assert +define+PARSER_ASSERT`) are on for every run — both the
`` `CHECK `` macro in the testbench (which tallies every mismatch instead of
stopping at the first) and the toggleable design assertions in the RTL
(`rtl/parser_asserts.svh`, [Phase 6](phase-6-verification.md)). One Verilator
build serves the whole directed suite because the testbench reads each packet's
`PKT_LEN`/`EXP_CODE` from `params.hex` at runtime. The additional verification
targets (`parser-analyze`, `parser-formal`, `model-analyze`, `model-fuzz`) are in
[Phase 6](phase-6-verification.md). See [nix.md](nix.md).

## Step-by-step tasks

1. ✅ `parser_pkg` + the model-generated micro-op ROM (`gen_parser_rom.c`).
2. ✅ Leaf units: `parser_pktbuf` (window/aligner), `parser_cam`, `parser_execute`.
3. ✅ `parser_top` scaffold + `parser_smoke_tb`; bring up in Verilator.
4. ✅ `cva6_parser_wrap` (interface-fidelity FU); Nix targets + lint.
5. ✅ `parser_decode` (32-bit word → micro-op), proven by the decode co-sim.
6. ⏭ Patch CVA6 decode/issue/EX to route custom opcodes (cva6-integration §8);
   generate `parser_pkg` from `isa/`.

## Deliverables / artifacts

- ✅ `rtl/parser_*.sv` + `cva6_parser_wrap.sv`; a Verilator smoke test producing a
  `flow_keys` for a packet, checked against the model.
- ✅ Four Nix sim/lint targets (run/trace/debug/lint).
- ⏭ The CVA6 integration patch (next increment).

## Exit criteria

- ✅ Design elaborates and lints clean (no width/latch/loop warnings).
- ✅ The vertical slice runs in Verilator and produces a `flow_keys` matching the
  model. (Full multi-packet slice coverage is [Phase 6](phase-6-verification.md).)
- ⏭ In-core CVA6 execution (the decode + pipeline patch) — next increment.

## Open questions

- **Decision:** CAM behavioural (now) → synthesizable structure (later) — behind
  the same `parser_cam` interface. ✅ behavioural first.
- **TBD:** exact CVA6 scoreboard/issue hook signals — pin during the in-core patch.
- **TBD:** packet-buffer fill in sim (preload now) vs a DMA model (Phase 8).

## References

CVA6 source & style; [`analysis/cva6-integration.md`](analysis/cva6-integration.md);
Phase 3 table; Verilator. See [references.md](references.md).
