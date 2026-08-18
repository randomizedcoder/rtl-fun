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
| **I1** | Commit-visible parser state (Design B: speculative `st_q` + committed `st_arch_q`, roll back on flush) | ✅ | #21 | G2 | `rtl/cva6_parser_wrap.sv`, `nix/cva6-parser/issue-ex.patch` (commit wiring), `tb/parser_wrap_tb.sv` | SVA `a_arch_committed` + `a_flush_rollback` hold under directed commit/flush stimulus (`parser-wrap-test`); `cva6-parser` builds; `cva6-parser-test` green |
| **I2** | Metadata sink (commit-gated `meta_mem`) + in-core value-check via **sim-only backdoor** | ✅ | #22 | G1, G8 | `rtl/cva6_parser_wrap.sv`, `tb/parser_wrap_tb.sv`, `nix/cva6-parser/tb-backdoor.patch`, `tests/cva6-parser/parser_insn.S` | wrap-TB metadata scenario green (`parser-wrap-test`); in-core `prs.storeimm`→`meta_mem[4]=0xAB` observed via harness XMR watcher (`*** PARSER META OK ***`) in `cva6-parser-test` |
| **I3** | custom-3 register readback (`prs.mv.x.p`) | ✅ | #23 | G4 | `rtl/parser_decode.sv` (CPPRSRD), `rtl/parser_pkg.sv` (`cpreg`/`rd_preg`), `rtl/cva6_parser_wrap.sv` (`read_preg`), `tests/cva6-parser/parser_insn.S` | in-core `prs.mv.x.p t2,p11` == `P_STOP_OKAY`, program-self-checked via `tohost` (exercises integer-RF WB + RAW forwarding, V3); wrap-TB Scenario 5. **No `cva6.sv`/patch change** — decoder already sets `rd`, `wt_valid[PARSER_WB]` already latches result |
| **I4a** | End-of-node fetch redirect (node-index → byte PC) | ✅ | #24 | G3 | `rtl/cva6_parser_wrap.sv` (combinational `resolve`/`redirect_pc_calc`), `nix/cva6-parser/issue-ex.patch` (latch `pc_o` for `fu==PARSER`), `tb/parser_wrap_tb.sv`, `nix/cva6-parser/tb-backdoor.patch`, `tests/cva6-parser/parser_insn.S` | wrap-TB Scenario 6 (target = pc_i + node_delta*4); in-core next-node jump skips a poison store + lands on target (`*** PARSER REDIRECT OK ***`, tohost=0/4325 cyc). Needed same-cycle resolve + parser-PC threading (see notes) |
| **I4b** | CAM programming (custom-3 CPPRSWR/CPPRSWRCAM/CPPRSRDCAM) + CAM-hit redirect | ✅ | #25 | G3, G4 | `rtl/parser_cam.sv` (clocked program port), `rtl/parser_decode.sv` (write/CAM decodes), `rtl/cva6_parser_wrap.sv` (`rs1_i`, `write_preg`, CAM program drive, lookup mux), `nix/cva6-parser/issue-ex.patch` (rs1 = `fu_data_i[0].operand_a` → FU; CAM program port; **branch/parser mux-exclusivity SVA**), `tb/parser_wrap_tb.sv` (Sc.7/8), `nix/cva6-parser/tb-backdoor.patch`, `tests/cva6-parser/parser_insn.S` | wrap-TB Sc.7 (program → CPPRSRDCAM readback == target) + Sc.8 (CAMNEXT hit → redirect to programmed node); in-core CPPRSRDCAM self-check (tohost) + `*** PARSER CAM REDIRECT OK ***`. Unblocks OP_CAMNEXT. **CAM-write speculation-safety closed by N3**: CPPRSWRCAM is now commit-gated (buffered in the I1 queue, applied on commit) with a lookup interlock (`tb/parser_wrap_tb.sv` Sc.12) |
| **I5** | All op classes + model-generated encodings + table-driven cosim over **real MMIO** | ✅ | #26 | G5, G9 (+ closes the I2 MMIO escalation) | `nix/cva6-parser-cosim.nix`, `scripts/cva6-parser-cosim.sh`, `verif/gen/gen_parser_rom.c` (`camprog.hex`), `nix/cva6-parser/mmio.patch` (SoC peripheral + xbar), `rtl/parser_pktbuf.sv` (write port), `rtl/cva6_parser_wrap.sv` (meta-read + parse-exit redirect + status), `toolchain/parser_mmio.h`, `tests/cva6-parser/cosim_main.S` | `cva6-parser-cosim` **15/15** — in-core packet→flow_keys equivalence vs the model, byte-for-byte + exit code, over real `sd`/`ld` MMIO |
| V-tables | Directed V1–V11 (branch-shadow, hazards, interrupts, reset/X, ctx-switch…) | ✅ | #27–#30, PR-5, N4, N5, V10 | G6, G7, G13 | test programs + `parser_wrap_tb.sv` + `tests/cva6-parser/{trap,parser_trap_v7,parser_trap_v6,parser_ctxsw_v10,parser_ctxsw_mid}.S` | **All V1–V11 green**: branch-shadow, interlock, RAW, WAW, adjacency, **interrupt-mid-parse V6 — N5**, **faulting-squash V7 — N4**, redirect/exit, reset-X, and **context-switch V10 (scoped) — D7 ratified**: the custom-3 move ABI round-trips the parser register context bit-for-bit through a between-parse switch; **M1 extends the ABI to the position state (p1/p2/p6/p7/p8/p9) so a genuine *mid-parse* switch resumes bit-exact vs the model** (`parser_ctxsw_mid.S` + `parser_wrap_tb` Sc.14). Only the *M2* residual (meta_mem frame + CAM restore path) stays deferred (§3.1 item 4) |
| Regression | Base-ISA regression + negative control + 2nd config + coverage in CI | ✅ | N1, N6, N7 | G10, G11, G12 | `nix/{parser-negative-control,parser-baseisa,parser-config-wb}.nix`, `scripts/{parser-negative-control,parser-baseisa,parser-coverage}.sh`, `tests/cva6-parser/{negctl,base_isa}.S`, CI config | Negative control ✅ (N1); base-ISA regression ✅ (N6: `cva6-parser-baseisa`); 2nd config ✅ (N6: `cva6-parser-config-wb`); **coverage ✅ (N7: `parser-coverage` — Verilator line/toggle + functional cover points; 100% of the §2.6.5 op×event×exit cross-product bins hit)** |
| Escalation | riscv-dv + extended-Spike lock-step | 🔵 | T0 | G5, G6, G7, G11 | `nix/spike-tandem.nix` + `nix/spike-tandem/parser_ext.cc` (source-built tandem Spike + parser extension), `model/libparsermodel/encoding.c` (`pm_decode`), `nix/cva6-parser-tandem.nix`, `scripts/cva6-parser-tandem.sh`, `tests/cva6-parser/{base_isa,parser_tandem}.S`, `scripts/cva6-baseline.sh` (`SPIKE_TANDEM` gate), `nix/cva6-parser/{tandem-get-misa-d-bit,tandem-mstatus-sd-mask,tandem-parser-activate}.patch` | **Stage 0 (base-ISA tandem) ✅**: `cva6-parser-tandem` stands up the dormant RVFI-vs-Spike lock-step — every retired RV64GC instruction of `base_isa.S` matched against a source-built extended Spike (insn/rd/pc/trap/mode + CSRs), **287/287, 0 mismatches**. **Stage 1a+1b (parser-op tandem) ✅**: a `pm_decode` inverse decoder (round-trip-proven) + a Spike `customext` extension reusing `libparsermodel` teach Spike the parser ISA; the same app lock-steps `parser_tandem.S` (custom-0 redirect + custom-3 register/CAM RD/WR/WRIMM) against it — **43/0 mismatches**, `Activating extension: parser`, deliberate-break negative control confirmed live. Stage 1c (MMIO packet buffer + packet-load ops → 22-case cosim) + Stage 2 (riscv-dv random) deferred |

## Gap burn-down (G1–G14)

| Gap | Owner | State |
|--|--|--|
| G1 no in-core value checking | I2 → I5 | ✅ (I5: full packet→flow_keys cosim over real MMIO, 22/22 vs the model; the I2 sim-only backdoor is superseded) |
| **G2 speculation/flush state corruption** | **I1** | ✅ (fix merged + verified by `parser-wrap-test`; PR #21. **Now also proved over all inputs**: `parser-formal` runs a k-induction proof of the sequential `a_arch_committed` + `a_flush_rollback` SVAs on `cva6_parser_wrap` — the I1 formal follow-up, `verif/formal/parser_wrap.sby`) |
| G3 redirect untested in-core | I4a (redirect) / I4b (CAM) → I5 | ✅ (I4a: end-of-node redirect fires + steers fetch in-core; I4b: CAM programmed/read back from the integer side, CAMNEXT hit drives a real redirect, mux-exclusivity SVA. **I5 exercises the redirect + CAMNEXT-hit + parse-exit-return path over 22 real packets** (15 at I5, +7 Table-A edge rows at PR-4) — every graph walk jumps/exits correctly. CAM-write speculation-safety **closed by N3** — CPPRSWRCAM is commit-gated with a dependent-lookup interlock) |
| G4 custom-3 untested | I3 / I4b | ✅ (read **and** write now merged: CPPRSRD register read — `read_preg` p-reg selector, PR #23; CPPRSWR register write + CPPRSWRCAM CAM program + CPPRSRDCAM CAM readback, all rs1-threaded from `ex_stage`, PR #25. In-core self-checks + wrap-TB Scenarios 5/7. The last custom-3 form — **CPPRSWRIMM immediate-load** — is now implemented (N2): `parser_decode` I=1 leg + split-imm extract, commit-gated on the CPPRSWR path, decode patch zeroes integer rs1/rd; wrap-TB Sc.11 + in-core directed row) |
| G5 one op only | I5 | ✅ (every op class — load/store/storeimm/lensetmin/cmpib·neib·ord/cam/camnext/next/stp + custom-3 moves — exercised by the 22-case cosim + wrap-TB; model-generated program) |
| G6 pipeline hazards | I3/I1 + V-rows | ✅ (RAW forwarding via the I3 self-check (V3); WAW last-writer-wins (V4) + parser-op adjacency to mul/CSR/branch with no WB/commit-port contention (V5) — PR-5, `parser_wrap_tb` Sc.9 + in-core `parser_insn.S`; back-to-back interlock is wrap-TB Sc.3 (V2)) |
| G7 interrupts/exceptions/ctx-switch | I5 (parse-exit) / V-tables / N4 / N5 / V10 | ✅ (V9 parse-**exit** redirect realized in I5 — on exit the FU steers fetch to a program-provided landing PC, exercised by all 22 cosim cases; **V7 faulting-instruction squash closed by N4** — an in-core `ecall` flushes an in-flight parser op, which re-executes and commits the fault-free result; **V6 interrupt-mid-parse closed by N5** — a CLINT machine software interrupt (msip) flushes the in-flight op mid-parse, the handler clears msip and `mret`s without advancing mepc, and it re-executes to the interrupt-free result — both via the reusable `trap.S` scaffold, covering both flavours of the FU `flush_i`; **V10 context-switch closed (scoped) — D7 ratified**: `parser_ctxsw_v10.S` spills/clobbers/reloads the writable parser regs {p11,p13,p14,p15,p16} via the custom-3 move ABI and asserts a bit-for-bit round-trip in-core; **M1 (`parser_ctxsw_mid.S`) extends the ABI to the position state (p1/p2/p6/p7/p8/p9) and proves a genuine *mid-parse* switch resumes to the model's byte-exact flow_keys**. Only the *M2* residual (meta_mem frame + CAM restore path) remains deferred — §3.1 item 4) |
| G8 metadata sink undefined | I2 → I5 | ✅ (commit-gated `meta_mem` frame in `cva6_parser_wrap`; software-visible over MMIO from I5; proven by `parser-wrap-test` + the 22-case cosim) |
| G9 hand-encoded | I5 | ✅ (the parse program + CAM table are emitted by the golden model — `gen_parser_rom` `enc.hex`/`camprog.hex` — and assembled verbatim; no hand `.word`s in the cosim) |
| G10 single config | Regression / **N6** | ✅ (`cva6-parser-config-wb` builds the patched model under a **2nd** existing RV64GC config — `cv64a6_imafdc_sv39_wb`, write-back cache — and runs the in-core parser test: the fu_t::PARSER integration (extra WB port, NrWbPorts, issue/commit wiring) issues/executes/retires there too, SUCCESS + META/REDIRECT/CAM markers. Superscalar `NrIssuePorts=2` remains deferred — needs a new config pkg + issue-port-1 interlock validation, §3.1) |
| G11 no negative control | N1 (neg. ctrl) / **N6** (base-ISA) | ✅ (negative control ✅ — `parser-negative-control` asserts the **stock** core traps the identical custom-0 word: illegal-instruction, mcause=2, handler → tohost=1 → fesvr SUCCESS, so the parser ops are a genuine ISA extension; **base-ISA regression ✅ — `cva6-parser-baseisa` runs a directed RV64GC slice (integer incl. *w, M, A, F/D, CSR, every branch flavour, JAL/JALR), each result value-checked, on the PATCHED core → the extension is behaviorally transparent to the base ISA**. **Now also lock-stepped against Spike (T0): `cva6-parser-tandem` steps a source-built extended Spike alongside the patched core for every retired `base_isa.S` instruction and asserts insn/rd/pc/trap/mode/CSRs match — 287/287, 0 mismatches — a strictly stronger transparency check than N6's program self-check.** The full upstream riscv-tests suite is a heavier deferred complement, §3.1) |
| G12 no coverage metric | Regression / **N7** | ✅ (`parser-coverage` builds the smoke suite + wrap-TB under Verilator line/toggle/user coverage, merges with `verilator_coverage`, and gates on **100% of the functional cover points** — the §2.6.5 V-table cross-product: every op class (`parser_top`/`cva6_parser_wrap` `c_op_*`, merged UNION), every FU pipeline event (accept/commit/flush/backpressure/interlock/redirect/exit), and OK/fail exit outcomes. Structural line/toggle % reported for visibility. Numeric closure target = 100% functional; scaling the corpus for a line-% floor is Phase-7) |
| G13 X-prop/reset | I2 + V11 | ✅ (V11 reset X-freedom — `parser_wrap_tb` Sc.0 asserts `$isunknown`-free spec/arch state + first-op result out of reset; PR-5) |
| G14 timing/physical | Phase 8 | ⬜ |

## Verification-target snapshot

| Target | Purpose | State (on `main`, I1–I5 merged) |
|--|--|--|
| `nix run .#cva6-parser-test` | in-core smoke/liveness + **I2 metadata value-check** + **I3 custom-3 readback self-check** + **I4a end-of-node redirect** + **I4b CAM program/readback + CAM-hit redirect** + **V4 WAW** + **V5 adjacency** (PR-5) | ✅ SUCCESS (tohost=0, 4327 cyc) + META OK (meta[4]=ab) + REDIRECT OK (poison meta[5] skipped, meta[6]=cc) + CAM REDIRECT OK (CAMNEXT hit, poison meta[8] skipped, meta[9]=dd; redirect_pc=0x80000076 from node 8); I3 + I4b CPPRSRDCAM + V4 WAW + V5 mul/CSR-adjacency self-checks green |
| `nix run .#parser-wrap-test` | I1 rollback/commit/backpressure + I2 metadata (Sc.4) + **I3 custom-3 readback** (Sc.5) + **I4a redirect target** (Sc.6) + **I4b CAM program/readback** (Sc.7) + **CAMNEXT-hit redirect** (Sc.8) + **I5 MMIO meta read** + **V11 reset/X** (Sc.0) + **V4 WAW** (Sc.9) + **store-past-frame bound** (Sc.10, PR-5), assertion-based | ✅ PASS |
| `nix run .#parser-lint` | lints the parser unit incl. `cva6_parser_wrap` | ✅ clean |
| `nix run .#parser-sim-suite` | standalone unit vs model (unaffected by in-core work) | ✅ 22/22 (Table A complete after PR-4) |
| `nix run .#parser-formal` | `parser_execute` safety (combinational, 1-step) **+ `cva6_parser_wrap` G2 speculation/flush invariants** (`a_arch_committed`/`a_flush_rollback` proved over all inputs by k-induction, `mode prove`) | ✅ PASS (both proofs; `successful proof by k-induction`) |
| `nix run .#cva6-parser-cosim` | **table-driven in-core packet→flow_keys value-check vs the model, over real MMIO** | ✅ **22/22** (positive/negative/boundary/corner; flow_keys byte-for-byte + exit code; Table A rows 16–22 added by PR-4) |

## Notes / open decisions (from the plan)

- **What's deferred lives in one place.** The single canonical deferral list is
  [cva6-verification-design.md §3.1](cva6-verification-design.md#31-canonical-deferral-list-single-source-of-truth)
  (the *M2* mid-parse residual — meta_mem frame + CAM restore path, the escalation layers,
  DMA feed, DFT/POST — V6/V7 interrupt/fault squash, the **scoped V10 between-parse
  context-switch (D7 ratified)**, the **M1 mid-parse register-state switch**, CAM-write
  speculation-safety and the immediate-load custom-3 form are now closed). The
  per-increment notes below add detail but do not re-enumerate it.
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
  **✅ CLOSED by I5 (PR #26).** Option A is now built: a real SoC AXI slave at
  `ariane_soc::ParserBase` (`nix/cva6-parser/mmio.patch`) bridges `sd`/`ld` into the FU's
  `parser_pktbuf` write port and a new commit-gated `meta_mem` read port (threaded
  `ariane`→`cva6`→`ex_stage`→FU), plus a `PktLen.ParseLen`/exit-PC/status register file.
  The cosim `sd`s each packet in and `ld`s the committed flow_keys back — no backdoor.
  The sim-only XMR watcher (`tb-backdoor.patch`) remains only for the pre-I5
  `cva6-parser-test` markers; the value equivalence now runs over the real bus.
- **I5 as-implemented — the whole op set, model-generated program, real MMIO, and one
  non-obvious SoC-integration bug.** `gen_parser_rom` emits the parse program
  (`enc.hex`) *and* the packed CAM-programming words (`camprog.hex`); the cosim driver
  (`cosim_main.S`) programs the CAM at runtime (CPPRSWR + CPPRSWRCAM per entry), sets
  ParseLen + an **exit-landing PC**, jumps into the contiguous custom-0 block, and the
  FU walks the graph — node-index→byte-PC redirects on each end-of-node, and on parse
  exit a **"subroutine-return" redirect** to the landing PC (once `st_q.done` latches no
  further parse op can issue, so exit *must* steer fetch back to the caller). All op
  classes are hit across the 15 packets. **The bug that cost the debugging pass:** the
  meta/status MMIO read was **combinational**, but `axi2mem` requires a **1-cycle-latency
  (synchronous) memory** — in its READ state it combinationally advances `addr_o` to the
  *next* beat address the moment `r_ready` is high (`axi2mem.sv` ~L193 `addr_o =
  cons_addr`), so a combinational `data_i` re-settled to `mem[ar_addr + 8]` and every
  `ld` returned the *next* word (flow_keys shifted by one 64-bit word — dst IP read at
  offset 0 instead of 8). Fix: **register** `parser_mmio_rdata` (one cycle of read
  latency, exactly like the bootrom/DRAM SRAMs). This is a testability lesson worth
  keeping: an on-chip peripheral hung off `axi2mem` must present registered read data.
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
  Custom-3 forms now implemented: register read (I3), register write + CAM program +
  CAM readback (I4b), and immediate load (`prs.ld.immed`, N2 — I=1 split imm, decode
  patch zeroes integer rs1/rd). Still deferred: array program/read (S=1 forms).
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
  packet→flow_keys equivalence stays with I5. **CAM-write speculation-safety — closed by
  N3:** the CAM write is now commit-gated. CPPRSWRCAM buffers its `{index,key,target}` in
  the I1 pending queue and applies to the CAM only on **commit** (like the metadata scatter),
  so a squashed speculative CPPRSWRCAM never reaches the CAM. Since there is no CAM
  speculative-forward path, a dependent lookup (CPPRSRDCAM / parse OP_CAMNEXT) **interlocks**
  at issue until every older CPPRSWRCAM commits — no deadlock (the older commit never depends
  on the stalled lookup; CAM programming is setup-time). Proven by `parser_wrap_tb` Sc.12 +
  the `a_camprog_on_commit`/`a_cam_lookup_interlock` SVAs; cosim 22/22 and the in-core
  CAMNEXT redirect still pass.
- **V10 context-switch contract** — ✅ decided (**D7 ratified**): reuse the custom-3 move
  ABI to spill/reload the writable p-reg subset, no new CSRs; proven in-core by
  `parser_ctxsw_v10.S` (between-parse). **M1 extends the ABI to the position state
  (p1/p2/p6/p7/p8 writable, p9 done read-only)** so the resumable position+data register set
  round-trips and a genuine *mid-parse* switch resumes bit-exact vs the model
  (`parser_ctxsw_mid.S` + `parser_wrap_tb` Sc.14). `done` (p9) is read-only — observed for
  the marker, not restored (mid-stream `done=1` wedges the frontend, deferred). Only the
  **M2** residual (meta_mem frame + CAM restore path) stays deferred (§3.1 item 4).
- **Coverage closure target** — set with the corpus.
- **I1 formal (follow-up) — ✅ DONE.** The I1 SVA (`a_arch_committed`,
  `a_flush_rollback`) are *sequential* (`$past`, multi-cycle), so the combinational
  1-step `parser_execute` proof cannot reach them. `parser-formal` now runs a **second**
  SymbiYosys proof (`verif/formal/parser_wrap.sby`) directly on `cva6_parser_wrap`: an
  **unbounded k-induction** (`mode prove`) discharges the two G2 speculation/flush
  invariants — and every other embedded wrap SVA — over ALL inputs, with a bounded
  `bmc` net alongside. The properties are 1-inductive (`st_arch_q` advances only under
  `pend_commit`; the flush block dominates the `always_ff` and drives `st_q`/`st_arch_q`
  from one identical RHS), so no environment model is needed. `parser_execute`
  elaborates inside the proof but the invariants hold for any datapath; the irrelevant
  `meta_mem` frame + its MMIO readback are pruned (`delete o:meta_rd_data_o`) so each
  solver step stays cheap. The directed `parser-wrap-test` remains as the simulation
  cross-check. Flatten note: sv2v can't bit-select an `int` loop variable, so the
  metadata-scatter width expressions in `cva6_parser_wrap` use width casts
  (`META_OFF_W'(i)`) rather than `i[META_OFF_W-1:0]` — behavior-identical, and now
  sv2v-portable.
