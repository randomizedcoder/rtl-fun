# In-core parser FU — implementation status tracker

> **What this is.** A living progress tracker for executing the
> [implementation & verification design](cva6-verification-design.md) (increments
> **I1–I5**) that closes the gap register in
> [cva6-test-evaluation.md](cva6-test-evaluation.md) (**G1–G14**). The design doc
> says *what to build and how to prove it*; this doc says *where we are*. Update it
> in the same PR that lands each increment (per the repo "keep status current"
> convention — also bump the Phase-5/6 status tables).

Status legend: ⬜ planned · 🔵 in progress · ✅ done (merged to `main`).

## Increment progress

| Inc | What | Status | PR | Gaps | Key files | Exit criterion / proven by |
|--|--|--|--|--|--|--|
| **I1** | Commit-visible parser state (Design B: speculative `st_q` + committed `st_arch_q`, roll back on flush) | 🔵 | #21 | G2 | `rtl/cva6_parser_wrap.sv`, `nix/cva6-parser/issue-ex.patch` (commit wiring), `rtl/parser_wrap_tb.sv` | SVA `a_arch_committed` + `a_flush_rollback` hold under directed commit/flush stimulus (`parser-wrap-test`); `cva6-parser` builds; `cva6-parser-test` green |
| **I2** | Metadata sink + in-core packet feed (observability substrate) | ⬜ | — | G1, G8 | `rtl/cva6_parser_wrap.sv`, `rtl/parser_pktbuf.sv`, testharness MMIO, `toolchain/parser_mmio.h` | baseline eth/ipv4/tcp parsed in-core → `memcmp(flow_keys, model)` equal |
| **I3** | custom-3 register readback | ⬜ | — | G4 | `rtl/cva6_parser_wrap.sv`, `nix/cva6-parser/issue-ex.patch` (`parser_we_o` → WB) | custom-3 read == expected; dependent instr sees forwarded `rd` (V3); enables V1 in software |
| **I4** | End-of-node redirect + CAM programming | ⬜ | — | G3 | `rtl/parser_cam.sv` (program port), `rtl/cva6_parser_wrap.sv`, patch | redirect PC == expected; mux-exclusivity SVA holds |
| **I5** | All op classes + model-generated encodings + table-driven cosim | ⬜ | — | G5, G9 | `nix/cva6-parser-cosim.nix`, `scripts/cva6-parser-cosim.sh`, `rtl/gen/gen_parser_rom.c` | every op self-checked vs model; Tables A+B green in-core |
| V-tables | Directed V1–V11 (branch-shadow, hazards, interrupts, reset/X…) | ⬜ | — | G6, G7, G13 | test programs + `parser_wrap_tb.sv` | each V-row green |
| Regression | Base-ISA regression + negative control + coverage in CI | ⬜ | — | G10, G11, G12 | CI config | riscv-tests/RISCOF green on patched core; stock core traps; coverage target |
| Escalation | riscv-dv + extended-Spike lock-step | ⬜ | — | G5, G6, G7 | Phase 7 | lock-step clean over corpus + random |

## Gap burn-down (G1–G14)

| Gap | Owner | State |
|--|--|--|
| G1 no in-core value checking | I2 | ⬜ |
| **G2 speculation/flush state corruption** | **I1** | 🔵 (fix implemented + verified by `parser-wrap-test`; PR #21) |
| G3 redirect untested in-core | I4 | ⬜ |
| G4 custom-3 untested | I3 | ⬜ |
| G5 one op only | I5 | ⬜ |
| G6 pipeline hazards | I3/I1 + V-tables | ⬜ |
| G7 interrupts/exceptions/ctx-switch | V-tables (+ ctx-switch design) | ⬜ |
| G8 metadata sink undefined | I2 | ⬜ |
| G9 hand-encoded | I5 | ⬜ |
| G10 single config | Regression | ⬜ |
| G11 no negative control | Regression | ⬜ |
| G12 no coverage metric | Regression | ⬜ |
| G13 X-prop/reset | I2 + V11 | ⬜ |
| G14 timing/physical | Phase 8 | ⬜ |

## Verification-target snapshot

| Target | Purpose | State (I1 branch) |
|--|--|--|
| `nix run .#cva6-parser-test` | in-core smoke/liveness + builds the patched core | ✅ SUCCESS (tohost=0, 4327 cyc) |
| `nix run .#parser-wrap-test` | I1 commit/flush rollback + commit-advance + backpressure, assertion-based (new) | ✅ PASS |
| `nix run .#parser-lint` | lints the parser unit incl. `cva6_parser_wrap` | ✅ clean |
| `nix run .#parser-sim-suite` | standalone unit vs model (unaffected by in-core work) | ✅ 15/15 |
| `nix run .#parser-formal` | standalone `parser_execute` safety (combinational) | ✅ (pre-existing) |
| `nix run .#cva6-parser-cosim` | table-driven in-core value-check vs model (from I5) | — (I5) |

## Notes / open decisions (from the plan)

- **I1 pending-queue depth `D`** = 4 (power-of-two ring; stall issue when full). Tune
  from observed issue→commit reorder distance.
- **I1 flush semantics** (grounded): `flush_i` to the FU (`flush_ex`) is always a
  *commit-boundary* flush (exception/eret/fence/CSR); a branch mispredict only
  flushes un-issued instrs + IF (`controller.sv`), so rolling `st_q` back to
  `st_arch_q` and discarding the pending queue on flush is exactly correct.
- **I2 MMIO map** — bases for pktbuf-write + metadata-read, and where to decode
  (testharness xbar); largest integration piece, overlaps Phase 8.
- **V10 context-switch contract** — design decision precedes the test.
- **Coverage closure target** — set with the corpus.
- **I1 formal (follow-up):** the I1 SVA (`a_arch_committed`, `a_flush_rollback`) are
  *sequential* (`$past`, multi-cycle), which the current `parser-formal` flow (sv2v +
  1-step BMC on the combinational `parser_execute`) does not cover. They are proven
  here by the directed assertion-based `parser-wrap-test`; a multi-cycle BMC harness
  for `cva6_parser_wrap` is a tracked follow-up.
