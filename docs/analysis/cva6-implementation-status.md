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
| **I1** | Commit-visible parser state (Design B: speculative `st_q` + committed `st_arch_q`, roll back on flush) | ✅ | #21 | G2 | `rtl/cva6_parser_wrap.sv`, `nix/cva6-parser/issue-ex.patch` (commit wiring), `rtl/parser_wrap_tb.sv` | SVA `a_arch_committed` + `a_flush_rollback` hold under directed commit/flush stimulus (`parser-wrap-test`); `cva6-parser` builds; `cva6-parser-test` green |
| **I2** | Metadata sink (commit-gated `meta_mem`) + in-core value-check via **sim-only backdoor** | 🔵 | #22 | G1, G8 | `rtl/cva6_parser_wrap.sv`, `rtl/parser_wrap_tb.sv`, `nix/cva6-parser/tb-backdoor.patch`, `tests/cva6-parser/parser_insn.S` | wrap-TB metadata scenario green (`parser-wrap-test`); in-core `prs.storeimm`→`meta_mem[4]=0xAB` observed via harness XMR watcher (`*** PARSER META OK ***`) in `cva6-parser-test` |
| **I3** | custom-3 register readback (`prs.mv.x.p`) | 🔵 | #23 | G4 | `rtl/parser_decode.sv` (CPPRSRD), `rtl/parser_pkg.sv` (`cpreg`/`rd_preg`), `rtl/cva6_parser_wrap.sv` (`read_preg`), `tests/cva6-parser/parser_insn.S` | in-core `prs.mv.x.p t2,p11` == `P_STOP_OKAY`, program-self-checked via `tohost` (exercises integer-RF WB + RAW forwarding, V3); wrap-TB Scenario 5. **No `cva6.sv`/patch change** — decoder already sets `rd`, `wt_valid[PARSER_WB]` already latches result |
| **I4a** | End-of-node fetch redirect (node-index → byte PC) | 🔵 | #24 | G3 | `rtl/cva6_parser_wrap.sv` (combinational `resolve`/`redirect_pc_calc`), `nix/cva6-parser/issue-ex.patch` (latch `pc_o` for `fu==PARSER`), `rtl/parser_wrap_tb.sv`, `nix/cva6-parser/tb-backdoor.patch`, `tests/cva6-parser/parser_insn.S` | wrap-TB Scenario 6 (target = pc_i + node_delta*4); in-core next-node jump skips a poison store + lands on target (`*** PARSER REDIRECT OK ***`, tohost=0/4325 cyc). Needed same-cycle resolve + parser-PC threading (see notes) |
| **I4b** | CAM programming (custom-3 CPPRSWR/CPPRSWRCAM/CPPRSRDCAM) + CAM-hit redirect | 🔵 | this PR | G3 | `rtl/parser_cam.sv` (clocked program port), `rtl/parser_decode.sv` (write/CAM decodes), `rtl/cva6_parser_wrap.sv` (`rs1_i`, `write_preg`, CAM program drive, lookup mux), `nix/cva6-parser/issue-ex.patch` (rs1 = `fu_data_i[0].operand_a` → FU; CAM program port; **branch/parser mux-exclusivity SVA**), `rtl/parser_wrap_tb.sv` (Sc.7/8), `nix/cva6-parser/tb-backdoor.patch`, `tests/cva6-parser/parser_insn.S` | wrap-TB Sc.7 (program → CPPRSRDCAM readback == target) + Sc.8 (CAMNEXT hit → redirect to programmed node); in-core CPPRSRDCAM self-check (tohost) + `*** PARSER CAM REDIRECT OK ***`. Unblocks OP_CAMNEXT. CAM write is execute-time (speculation-safety deferred — see notes) |
| **I5** | All op classes + model-generated encodings + table-driven cosim | ⬜ | — | G5, G9 | `nix/cva6-parser-cosim.nix`, `scripts/cva6-parser-cosim.sh`, `rtl/gen/gen_parser_rom.c` | every op self-checked vs model; Tables A+B green in-core |
| V-tables | Directed V1–V11 (branch-shadow, hazards, interrupts, reset/X…) | ⬜ | — | G6, G7, G13 | test programs + `parser_wrap_tb.sv` | each V-row green |
| Regression | Base-ISA regression + negative control + coverage in CI | ⬜ | — | G10, G11, G12 | CI config | riscv-tests/RISCOF green on patched core; stock core traps; coverage target |
| Escalation | riscv-dv + extended-Spike lock-step | ⬜ | — | G5, G6, G7 | Phase 7 | lock-step clean over corpus + random |

## Gap burn-down (G1–G14)

| Gap | Owner | State |
|--|--|--|
| G1 no in-core value checking | I2 | 🔵 (metadata sink value-checked in-core via sim-only backdoor; full packet→flow_keys cosim at I5) |
| **G2 speculation/flush state corruption** | **I1** | ✅ (fix merged + verified by `parser-wrap-test`; PR #21) |
| G3 redirect untested in-core | I4a (redirect) / I4b (CAM) | 🔵 (I4a: end-of-node redirect fires + steers fetch in-core — poison skipped, target landed, node-index→byte-PC, PR #24. I4b: CAM programmed from the integer side (CPPRSWR/CPPRSWRCAM), read back (CPPRSRDCAM), and a **CAMNEXT hit on a programmed entry drives a real fetch redirect**; branch/parser mux-exclusivity SVA added. Remaining: CAM-write speculation-safety + full CAMNEXT miss dispositions) |
| G4 custom-3 untested | I3 | 🔵 (CPPRSRD read decoded + serviced; `read_preg` p-reg selector; in-core self-check + wrap-TB Scenario 5; PR #23) |
| G5 one op only | I5 | ⬜ |
| G6 pipeline hazards | I3/I1 + V-tables | 🔵 (RAW forwarding on parser `rd` exercised by the I3 self-check; full hazard V-table later) |
| G7 interrupts/exceptions/ctx-switch | V-tables (+ ctx-switch design) | ⬜ |
| G8 metadata sink undefined | I2 | 🔵 (commit-gated `meta_mem` frame in `cva6_parser_wrap`; proven by `parser-wrap-test` + in-core; PR #22) |
| G9 hand-encoded | I5 | ⬜ |
| G10 single config | Regression | ⬜ |
| G11 no negative control | Regression | ⬜ |
| G12 no coverage metric | Regression | ⬜ |
| G13 X-prop/reset | I2 + V11 | ⬜ |
| G14 timing/physical | Phase 8 | ⬜ |

## Verification-target snapshot

| Target | Purpose | State (I4b branch) |
|--|--|--|
| `nix run .#cva6-parser-test` | in-core smoke/liveness + **I2 metadata value-check** + **I3 custom-3 readback self-check** + **I4a end-of-node redirect** + **I4b CAM program/readback + CAM-hit redirect** | ✅ SUCCESS (tohost=0, 4325 cyc) + META OK (meta[4]=ab) + REDIRECT OK (poison meta[5] skipped, meta[6]=cc) + CAM REDIRECT OK (CAMNEXT hit, poison meta[8] skipped, meta[9]=dd; redirect_pc=0x80000076 from node 8); I3 + I4b CPPRSRDCAM readback self-checks green |
| `nix run .#parser-wrap-test` | I1 rollback/commit/backpressure + I2 metadata (Sc.4) + **I3 custom-3 readback** (Sc.5) + **I4a redirect target** (Sc.6) + **I4b CAM program/readback** (Sc.7) + **CAMNEXT-hit redirect** (Sc.8), assertion-based | ✅ PASS |
| `nix run .#parser-lint` | lints the parser unit incl. `cva6_parser_wrap` | ✅ clean |
| `nix run .#parser-sim-suite` | standalone unit vs model (unaffected by in-core work) | ✅ 15/15 |
| `nix run .#parser-formal` | standalone `parser_execute` safety (combinational) | ✅ (pre-existing; `parser_execute` untouched) |
| `nix run .#cva6-parser-cosim` | table-driven in-core value-check vs model (from I5) | — (I5) |

## Notes / open decisions (from the plan)

- **I1 pending-queue depth `D`** = 4 (power-of-two ring; stall issue when full). Tune
  from observed issue→commit reorder distance.
- **I1 flush semantics** (grounded): `flush_i` to the FU (`flush_ex`) is always a
  *commit-boundary* flush (exception/eret/fence/CSR); a branch mispredict only
  flushes un-issued instrs + IF (`controller.sv`), so rolling `st_q` back to
  `st_arch_q` and discarding the pending queue on flush is exactly correct.
- **I2 took the shorter, sim-only backdoor path — deliberately (⚠ loop back later).**
  For observability we chose **Option B** (a `$readmemh`/XMR sim backdoor): a
  commit-gated `meta_mem` frame in `cva6_parser_wrap` read hierarchically by an
  `ariane_testharness` watcher (`tb-backdoor.patch`), which prints a grep-able marker
  when the frame lands. We did **not** build **Option A** — a real MMIO-mapped packet
  buffer + metadata frame on the SoC AXI xbar (new `axi_slaves_t` entry +
  `NB_PERIPHERALS`, addr_map row, `axi2mem` slave, a `parser_pktbuf` write port, and a
  meta-read port threaded FU→`ex_stage`). **Why:** Option A is a strict *superset* of
  what I2 built (needs everything the backdoor needs plus ~6–9 files of shared
  *synthesizable* RTL that also perturbs the formal + `cva6-parser-test` flows), so
  low-risk-first was the right call. **Escalation (do this when deeper analysis
  requires it):** build Option A when a real `sd`/`ld` MMIO path or the Phase-8 packet
  DMA feed is needed, or when a software-visible metadata frame is wanted. This is an
  explicit deferred item, **not** "done". The full packet→`flow_keys` value
  equivalence (vs the golden model) is likewise deferred to **I5**'s table-driven
  cosim, where I3's custom-3 readback makes an in-core self-check clean.
- **I3 readback map + vestigial `parser_we_o`.** `read_preg` exposes the p-registers
  resident in the execution subset (`pstate_t`): p11 Next, p13 DataBndLoop, p14
  ParserExitCode, p15 Accum, p16 Flags, and p1/p2 as the flattened current/data-header
  `{len,off}` (an implementation-defined packing); other Cpreg values read 0. The
  read reflects the working state `st_q` (program-order correct; squashed with the op
  on flush). Note: CVA6 writes the integer RF via the statically-decoded `rd`
  (custom-3 `rd=itype.rd`, custom-0 `rd=x0`) + `wt_valid[PARSER_WB]`; `parser_we_o` is
  therefore **vestigial** in this integration (kept as a documented internal strobe,
  asserted `a_we_iff_rdpreg`). To make the FU authoritatively gate `rd` (CVXIF-style),
  surface `parser_we_o` and gate `sbe.rd` in `scoreboard.sv` — deferred, not needed.
  Deferred custom-3 forms: register write (`prs.mv.p.x`, needs rs1 → FU), immediate
  load, CAM/array program (I4).
- **I4a end-of-node redirect — two non-obvious fixes (both found in-core, not in the
  wrap-TB).** (1) **Same-cycle resolve.** `resolve_branch_o`/`redirect_pc_o`/
  `parse_exit_o` must be **combinational** (driven off `accept_state`), not registered:
  CVA6's mispredict flush (`controller.sv`) kills only *un-issued* instrs + IF and
  relies on a branch resolving the very cycle it is in EX (`branch_unit` is
  combinational). A registered strobe fired a cycle late — after the wrong-path
  (poison) op had issued — so it was never squashed. (2) **Redirect base PC.**
  `redirect_pc = pc_i + (target−cur)×4` needs `pc_i` = the *parser op's own* PC, but
  `ex_stage.pc_i` (`pc_id_ex`) is latched in `issue_read_operands` **only for
  `fu==CTRL_FLOW`** (it feeds `branch_unit`). For a parser op it held the last
  branch's PC (the boot ROM `jr` at `0x10014` in the smoke test) → redirect computed
  `0x1001c`, jumping into the boot ROM (a 2M-cycle hang). Fix: a one-line
  `issue-ex.patch` hunk also latches `pc_o <= issue_instr_i[0].pc` for `fu==PARSER`
  (safe — parser/branch are mutually exclusive in-order). Neither bug is visible in
  `parser-wrap-test` (which checks the delta math in isolation); both were pinned by an
  RVFI trace + a backdoor `pc_i` dump. The **branch/parser mux-exclusivity SVA** landed
  in I4b (see below).
- **I4b CAM programming + CAM-hit redirect.** Three more custom-3 moves join CPPRSRD,
  all threading the integer `rs1` operand from `ex_stage` (`fu_data_i[0].operand_a`, which
  the CVA6 decoder already fills for custom-3): **CPPRSWR** writes a p-register from `rs1`
  (enqueued + commit-gated like a parse op, reusing the I1 pending queue); **CPPRSWRCAM**
  programs a CAM entry — index = `rs1`, and `{key,target}` come from `p[cpreg]` (patent
  pseudo-code: key = `p>>32`, target = `p[31:0]`), staged there by a prior CPPRSWR;
  **CPPRSRDCAM** does a key lookup and returns the target into `rd`. `parser_cam` gained a
  clocked write/delete port; the lookup port is muxed (parse ops key it from
  `parser_execute`, CPPRSRDCAM from `rs1`). This **unblocks OP_CAMNEXT**: a programmed CAM
  entry now drives a real end-of-node redirect (`CAMNEXT.s` hit → `Next` = target →
  `f_eon` → node-index→byte-PC redirect, the I4a path). The deferred **branch/parser
  mux-exclusivity SVA** (`parser_branch_mux_excl` in `ex_stage`) was added here — the
  `gen_resolved_branch_mux` silently drops a branch resolve if the parser also resolves,
  so this asserts they never co-assert (true by in-order single-issue + single-in-flight).
  The golden model has a **static** CAM (`program.c` const tables) and does not execute
  runtime `CPPRSWRCAM`, so the CAM-write path is **in-core self-checked** (CPPRSRDCAM
  readback via `tohost`, CAMNEXT redirect via the backdoor), not model-compared — full
  packet→flow_keys equivalence stays with I5. **Deferred escalation:** the CAM write is
  applied at **execute** (speculative, so a following lookup sees it immediately) and is
  **not** commit-gated / rolled back on flush — a squashed CPPRSWRCAM would leave a stale
  entry. Acceptable for setup-time programming (the patent treats CAM programming as
  setup) and for the straight-line directed test; commit-gated CAM programming is a tracked
  escalation, like the I2 sim-only backdoor.
- **V10 context-switch contract** — design decision precedes the test.
- **Coverage closure target** — set with the corpus.
- **I1 formal (follow-up):** the I1 SVA (`a_arch_committed`, `a_flush_rollback`) are
  *sequential* (`$past`, multi-cycle), which the current `parser-formal` flow (sv2v +
  1-step BMC on the combinational `parser_execute`) does not cover. They are proven
  here by the directed assertion-based `parser-wrap-test`; a multi-cycle BMC harness
  for `cva6_parser_wrap` is a tracked follow-up.
