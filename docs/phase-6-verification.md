# Phase 6 — Verification

← [Phase 5](phase-5-rtl.md) · [Docs index](README.md) · [Phase 7 »](phase-7-toolchain.md)

## Objective

Prove the [RTL](phase-5-rtl.md) is **bit-identical to the golden model**
([Phase 2](phase-2-reference-model.md)) across the whole corpus — including every
malformed packet — via co-simulation, directed tests, and fuzzing. This is the
correctness gate for the project.

## Inputs / prerequisites

- Phase 5 RTL running in Verilator.
- Phase 2 golden model + serialized corpus (`{bytes, flow_keys, status}`).

## Status — ✅ Done (correctness gate met)

**The Phase-6 correctness gate is met.** The RTL is proven equal to the golden
model — `flow_keys` fields **and** exit status — across the corpus, by three
independent paths: the standalone Verilator directed suite (`parser-sim-suite`,
22/22), the **in-core** packet→flow_keys MMIO co-simulation (`cva6-parser-cosim`,
22/22), and a **per-instruction RVFI-vs-Spike lock-step** with a constrained-random +
real-corpus packet campaign layered on top (`cva6-parser-tandem` /
`cva6-parser-tandem-campaign`, 0 mismatches). Coverage is signed off
(`parser-coverage`, 100% of the functional op×event×exit bins). The in-core gap
register **G1–G13 is fully closed**; **G14 (timing/physical) is Phase 8**.

Two honesty notes on scope:

- **The cocotb + DPI-C corpus harness specified in §6.1 was not built as such — it is
  *superseded*.** Its goal (RTL == model over the whole corpus, fields + status) is met
  by the substitute infrastructure above (standalone suite + in-core MMIO cosim + tandem
  campaign), which is stronger: it checks the FU both standalone *and* inside the CVA6
  pipeline, against both the model and an independent Spike. The §6.1–§6.5 design below
  is retained as the original plan of record.
- **The RVFI-vs-Spike tandem lock-step (Stages 0/1a/1b/1c/2) is classified as Phase-6
  verification**, even though its PRs (#42–#45) carry "Phase 7 Stage N" commit banners.
  Its Spike custom extension reuses `libparsermodel`, so the *parser* tandem proves
  **RTL executor == model** on random input; real Spike is the independent oracle for the
  surrounding RV64GC stream. See the [`In-core verification`](#in-core-verification-the-cva6-integrated-fu)
  section and the [status tracker](analysis/cva6-implementation-status.md). Building the
  user-facing Phase-7 Spike/QEMU toolchain (a C-intrinsics parser binary) remains
  [Phase 7](phase-7-toolchain.md).

Residual items that are **not** Phase-6 blockers (deferred / other phases): G14 timing
& DFT/POST → [Phase 8](phase-8-fpga.md); the M2 mid-parse-switch-to-a-STORE-ing/CAM
parse, the superscalar `NrIssuePorts=2` config, formal decode-table correctness, and
full riscv-tests / riscv-dv instruction-axis random → tracked deferrals.

The verification *foundation* across all four techniques is in place and green (all
runnable from the flake):

- **Design assertions, toggleable.** One assertion header (`rtl/parser_asserts.svh`)
  defines `` `PRS_ASSERT `` / `` `PRS_ASSERT_I `` that expand to real SVA only under
  `+define+PARSER_ASSERT` (sim) or `+define+FORMAL` (proof) and vanish otherwise —
  so the same RTL is synthesizable and the no-assert build pays nothing. Safety
  assertions live in `parser_top` (metadata in-bounds, load offset in range,
  negative exit code, sticky done, encap bound) and `cva6_parser_wrap` (handshake:
  ready-low-when-done, writeback-after-accept, no integer writeback). On for every
  sim: `nix run .#parser-sim`.
- **Formal proof.** `nix run .#parser-formal` flattens the SV with `sv2v` and has
  SymbiYosys (z3) *prove* — over all inputs, not samples — that `parser_execute`
  never writes metadata outside the `flow_keys` frame, only ever writes 1/2/4/8
  bytes, and reports a negative exit code whenever it completes.
- **Directed suite.** `nix run .#parser-sim-suite` runs 22 packets —
  positive (v4/v6 × tcp/udp, VLAN, QinQ, IPv6 HBH ext, IPv6 fragment), negative
  (unknown ethertype, bad IP version, unknown proto), boundary (minimal/truncated
  IPv4) and corner (empty, L2-only) — each checked byte-for-byte and exit-code
  against the model. Vectors are generated from the model (`verif/gen/gen_parser_rom.c`),
  which self-checks each case's expected pass/fail, so RTL and model share one truth.
- **Static analysis + fuzzing.** `nix run .#parser-analyze` (verible + svlint, on
  top of Verilator `-Wall`) and `nix run .#model-analyze` (cppcheck, gcc
  `-fanalyzer`, clang-tidy, then an ASan/UBSan run of the model tests).
  `nix run .#model-fuzz` fuzzes the model with libFuzzer + ASan/UBSan on random
  packets (memory-safety on malformed input, Risk R4).

The originally-planned closing work — an **RTL↔model corpus co-simulation** (cocotb +
DPI-C over the full Phase-2 corpus) and coverage sign-off — is **complete**: coverage
is signed off (`parser-coverage`), and the corpus equivalence goal is met by the
substitute infrastructure noted above (the cocotb/DPI-C harness itself was superseded,
not built). The §6.1–§6.5 design below is retained as the plan of record.

## Design detail

### 6.1 Co-simulation harness

```
                 corpus vector {bytes, expected_flow_keys, expected_status}
                          │
             ┌────────────┴─────────────┐
             ▼                          ▼
     cocotb drives RTL           C golden model
     (Verilator DUT)            (DPI-C or separate run)
             │                          │
        flow_keys_rtl              flow_keys_model
        status_rtl                 status_model
             └────────────┬─────────────┘
                          ▼
                 assert bit-exact equality
                 (fields AND exit status)
```

Use **cocotb** to load each packet into `parser_pktbuf`, set `pktbase/pktlen`,
launch the parse program, and read back the metadata buffer + status. Compare to
the model — ideally the model linked in via **DPI-C** so both run on identical
inputs in one process.

### 6.2 Test tiers

1. **Directed** — the Phase-1 worked example and one clean packet per protocol
   combination; easiest to debug first.
2. **Corpus replay** — every well-formed and malformed vector from Phase 2.
3. **Fuzzing** — randomized/mutated packets fed to model and RTL simultaneously;
   any output or status divergence is a bug (in RTL, model, or the spec — all
   worth finding). Emphasize malformed structure (Risk R4): truncation, bad
   lengths, zero-length TLVs, deep VLAN/ext-header stacks.

### 6.3 What we assert

- `flow_keys` fields bit-exact.
- Exit **status** matches (complete vs each error class) — a parser that gets the
  right key but the wrong bounds/exit behavior is still wrong.
- **Liveness:** the RTL always terminates — loop guards prevent hangs on
  zero-length/looping inputs (checked with a cycle watchdog in the TB).

### 6.4 Coverage

- **Functional coverage:** every instruction, every qualifier (`.stp/.fail`),
  every CAM sub-table, each error-exit class, min/max IHL, N ext-headers, stacked
  VLAN.
- **Code/toggle coverage** via Verilator where practical.
- Define a numeric target (**TBD**, coordinate w/ Phase 2 corpus size) that gates
  "done."

### 6.5 CI

- Run directed + corpus tiers on every push; a bounded fuzz budget nightly.
- Fail the build on any mismatch, any watchdog timeout, or coverage regression.
- Pin tool versions (Verilator/cocotb) for reproducibility.

## Step-by-step tasks

1. Stand up the cocotb testbench around the Verilator DUT.
2. Link the golden model via DPI-C (or a compare harness over serialized outputs).
3. Implement the three test tiers (directed → corpus → fuzz).
4. Add field + status assertions and the liveness watchdog.
5. Wire functional/code coverage and set the target.
6. Add CI: per-push directed+corpus, nightly fuzz; fail on mismatch/timeout.

## Deliverables / artifacts

- `tb/` cocotb testbench + DPI-C bridge to the model.
- A fuzzing harness and a coverage report.
- CI config that gates merges on RTL == model.

## Exit criteria

- RTL == golden model (fields **and** status) over the entire corpus.
- Fuzzing finds no divergence within the budget; no watchdog timeouts.
- Coverage target met.

## Open questions

- **Decision:** DPI-C in-process compare vs. offline output diff. (Recommend
  DPI-C — same inputs, no serialization skew.)
- **TBD:** coverage % and fuzz budget that define "signed off."
- Do we also cross-check against Spike once Phase 7 lands? (Nice-to-have.)

## In-core verification (the CVA6-integrated FU)

The plan above verifies the **standalone** parser unit against the model. The
parser FU wired **into CVA6** is a distinct, thinner surface today (one directed
`tohost` smoke test, `nix run .#cva6-parser-test`). Its honest gap analysis — what
that test proves, the bug classes it cannot see (in-core value checking,
speculation/flush state safety, the redirect path, hazards/interrupts, coverage),
and the best-practice roadmap to close them (lock-step co-sim vs an extended Spike,
`riscv-dv`, RVFI/formal, base-ISA regression) — is in
**[analysis/cva6-test-evaluation.md](analysis/cva6-test-evaluation.md)**. The
follow-up **[analysis/cva6-verification-design.md](analysis/cva6-verification-design.md)**
turns that into a build+prove design: ordered implementation increments (the
speculation-safety fix first), a **table-driven** test framework (positive /
negative / boundary / corner, model-generated oracles), and a **manufacturing /
self-test (DFT)** section (scan/ATPG, MBIST/CAM-BIST, JTAG, golden-vector POST).
Progress against that design is tracked live in
**[analysis/cva6-implementation-status.md](analysis/cva6-implementation-status.md)**.
Increment **I1** (commit-visible parser state — fixing the G2 speculation/flush
state-corruption bug) is done: `cva6_parser_wrap` now keeps a speculative working
copy plus a committed architectural shadow, rolling back on flush, verified by
`nix run .#parser-wrap-test` (assertion-based rollback / commit-advance /
backpressure) with no in-core regression.

Increment **I2** (metadata sink + first in-core value-check — gaps G1/G8) adds a
**commit-gated** `meta_mem` flow_keys frame to `cva6_parser_wrap` (buffered in the
pending FIFO, byte-scattered only on commit — the same speculation gate as I1), and
value-checks it **on the real core**: a `prs.storeimm` in `parser_insn.S` writes
`0xAB` into the frame, and a sim-only XMR watcher in the testharness
(`tb-backdoor.patch`) prints `*** PARSER META OK ***` the cycle it commits, which
`nix run .#cva6-parser-test` now gates PASS on. This is the deliberate shorter path
— a real MMIO-mapped packet buffer + metadata frame on the SoC xbar is a tracked,
deferred escalation (see the implementation-status tracker), and the full
packet→flow_keys equivalence vs the golden model comes with I5's table-driven cosim.

Increment **I3** (custom-3 register readback — gap G4) adds `prs.mv.x.p rd, p<n>`
(`CPPRSRD`): `parser_decode` decodes custom-3 and `cva6_parser_wrap` services it as a
register move, selecting a `pstate_t` field into the integer `rd` without advancing
parser state. It is value-checked **in-core by the program itself** — `parser_insn.S`
reads p11 (Next) and writes `tohost` only if it equals the expected reset value, so a
wrong readback fails the test with no backdoor needed. This also exercises the parser
integer-RF writeback and RAW forwarding (a dependent instruction consumes `rd`). No
`cva6.sv`/patch change was required (the decoder already sets `rd` for custom-3).

Increment **I4a** (end-of-node fetch redirect — gap G3) makes a `NEXTNODE` jump steer
the frontend: `cva6_parser_wrap` drives `resolve_branch_o` + a byte-translated
`redirect_pc_o = pc_i + (target_node − cur_node)×4`, muxed into `resolved_branch_o`
(`is_mispredict`) in `ex_stage`. `parser_insn.S` jumps over a **poison** store onto a
**landing** store; the backdoor confirms the poison never committed (`meta[5]==0`) and
the target did (`meta[6]==0xCC`) → `*** PARSER REDIRECT OK ***`. Two subtleties surfaced
only in-core (not in the isolated wrap-TB): the resolve must be **combinational**
(same-cycle as the op in EX, matching `branch_unit` — CVA6's mispredict flush kills only
un-issued instrs, so a registered/late strobe never squashes the wrong-path op); and the
FU's `pc_i` base must be the parser op's **own** PC, which required latching `pc_o` for
`fu==PARSER` in `issue_read_operands` (CVA6 latches it only for `CTRL_FLOW`, so it
otherwise held the last branch's PC). CAM-driven redirect + the branch/parser
mux-exclusivity SVA are deferred to I4b. See the
[status tracker](analysis/cva6-implementation-status.md) for the increment/gap state.

Increment **I4b** (CAM programming + CAM-hit redirect — gap G3, CAM path) programs the
CAM from the integer side and uses it. Three custom-3 moves join `CPPRSRD`, all threading
the integer `rs1` operand from `ex_stage` (`fu_data_i[0].operand_a`): `CPPRSWR` writes a
p-register (commit-gated via the I1 pending queue), `CPPRSWRCAM` programs a CAM entry
(index = `rs1`, `{key,target}` from `p[cpreg]`), and `CPPRSRDCAM` does a key lookup back
into `rd`. `parser_cam` gains a clocked write/delete port; its lookup is muxed between
parse ops and `CPPRSRDCAM`. This **unblocks `OP_CAMNEXT`**: a `CAMNEXT.s` hit on a
programmed entry drives a real end-of-node redirect (the I4a path). `parser_insn.S`
self-checks the `CPPRSRDCAM` readback via `tohost` and takes a CAM-driven redirect over a
poison store onto a landing store (`meta[9]=0xDD`) → `*** PARSER CAM REDIRECT OK ***`; the
deferred branch/parser mux-exclusivity SVA (`parser_branch_mux_excl`) landed here too.
The CAM write is execute-time (speculative); commit-gated CAM programming is a tracked
deferred escalation (the golden model's CAM is static, so the write path is in-core
self-checked, not model-compared — full equivalence comes with I5). See the
[status tracker](analysis/cva6-implementation-status.md).

Increment **I5** (all op classes + model-generated encodings + the table-driven in-core
cosim — gaps G5/G9) delivers the **first true packet→flow_keys equivalence check inside
the CVA6 pipeline**, and closes the I2 sim-only-backdoor escalation by building the real
thing. A SoC AXI MMIO peripheral (`nix/cva6-parser/mmio.patch`, at
`ariane_soc::ParserBase`) bridges bus `sd`/`ld` — via `axi2mem` — into the FU's
`parser_pktbuf` write port and its commit-gated flow_keys frame, plus `ParseLen` /
exit-PC / status registers (ports threaded `ariane`→`cva6`→`ex_stage`→FU; map in
[`toolchain/parser_mmio.h`](../toolchain/parser_mmio.h), design in
[analysis/cva6-parser-mmio.md](analysis/cva6-parser-mmio.md)). The `cva6-parser-cosim`
app generates every vector from the golden model (`gen_parser_rom` → `enc.hex` parse
program + `camprog.hex` CAM words + per-case packet/expected), then for each of the 15
corpus packets: `sd`s the packet in, sets `ParseLen` + an exit-landing PC, programs the
CAM at runtime, jumps into the contiguous custom-0 block, lets the FU walk the graph
(end-of-node redirects, and a **subroutine-return redirect** to the landing PC on parse
exit), and `ld`s the committed flow_keys + exit status back to compare against the model.
**Result: 22/22 — flow_keys byte-for-byte and exit code equal to the model** across
positive/negative/boundary/corner (`nix run .#cva6-parser-cosim`). One integration bug is
worth recording (a testability lesson): a peripheral hung off `axi2mem` **must present
registered read data** — `axi2mem` combinationally advances `addr_o` to the next beat the
moment `r_ready` is high, so a combinational read returns `mem[addr+8]` and every `ld`
came back shifted by one 64-bit word; registering the read response (1-cycle latency,
like the bootrom/DRAM SRAMs) fixed it. See the
[status tracker](analysis/cva6-implementation-status.md).

## References

cocotb, Verilator; Phase 2 model/corpus;
[analysis/cva6-test-evaluation.md](analysis/cva6-test-evaluation.md) (in-core test
gap analysis + verification-methodology references). See [references.md](references.md).
