# Evaluating the in-core CVA6 parser test — what we prove, the gaps, and how to close them

> **Why this document exists.** `nix run .#cva6-parser-test` is arguably the most
> important single check in this repo: it is the one thing that exercises the
> parser instructions *as executed by a real CPU pipeline*, not in isolation. A
> bug that survives into an ASIC tapeout is catastrophic — silicon re-spins cost
> months and millions, and a shipped functional bug (Intel's 1994 Pentium FDIV
> cost ~$475M) can be unrecoverable. So before we lean on this test as a
> correctness gate, we must be brutally honest about what it actually proves,
> enumerate every way the design could still be wrong, and lay out the tests that
> would catch each. This is a living risk register for the in-core integration.

Companion to [phase-6-verification.md](../phase-6-verification.md) (the standalone
unit's verification plan) and [cva6-integration.md](cva6-integration.md) (the
signal-level integration map). This doc is specifically about the **in-core**
surface — the parser FU wired into CVA6 — which is the newer and far thinner of
the two verification surfaces.

> **Next step:** the follow-up
> [cva6-verification-design.md](cva6-verification-design.md) turns this risk
> register into a *design* — ordered implementation increments that close G1–G14
> (speculation-safety fix first), a table-driven test framework, and a
> manufacturing/self-test (DFT) plan.

## 1. Two verification surfaces — don't conflate them

The project verifies correctness at two distinct levels. They catch different
bugs and must not be treated as interchangeable:

| Surface | What runs | Reference | Maturity |
|--|--|--|--|
| **Standalone parser unit** | `parser_execute`/`parser_top` in Verilator | the golden C model, **bit-exact** | **Strong** — directed suite (22 packets), decode co-sim, design assertions, a SymbiYosys formal proof, model fuzzing. `parser-sim{,-suite,-decode}`, `parser-formal`. |
| **In-core integration** | the parser FU inside the full CVA6 pipeline (`Variane_testharness`) | *none yet* — a liveness/smoke check only | **Thin** — one directed program (`cva6-parser-test`), 4 identical custom-0 loads, no value checking. |

The standalone surface proves the **datapath computes the right `flow_keys`** on
real (and malformed) packets. It says **nothing** about whether the pipeline feeds
that datapath correctly, whether results retire to the right place, or whether the
unit behaves under the pipeline's control-flow reality (flushes, speculation,
exceptions). That is entirely the job of the in-core surface — and that surface is
where the risk now concentrates.

## 2. What `cva6-parser-test` proves **today** (precisely)

The test places four `custom-0` words (a `prs.load`) at the DRAM entry point, then
writes `1` to the fesvr `tohost` symbol and spins. A green run
(`*** SUCCESS *** (tohost = 0)`) is a genuine but **narrow** proof. It establishes,
by the fact that the core neither traps nor hangs and reaches the `tohost` store:

1. **Decode routing works** — `custom-0` decodes to `fu = PARSER`, *not* the
   illegal-instruction fallback. (On the stock core the identical word traps; the
   PASS is specific to the patch.)
2. **The issue handshake completes** — the FU asserts `parser_ready`, issue drives
   `parser_valid`, and the op is accepted.
3. **The op retires** — the scoreboard entry is cleared via the parser writeback
   port by `trans_id`; otherwise the scoreboard would fill, commit would stall, the
   `tohost` store would never issue, and the run would time out.
4. **No integer-RF corruption on the straight-line path** — `rd = 0` is honoured
   (the subsequent `li`/`la`/`sd` using `t0`/`t1` still work).
5. **No spurious fetch redirect** — the `resolved_branch_o` mux stays quiescent for
   a load; a bogus redirect would send fetch into garbage and time out.
6. **The patched core builds and elaborates** under Verilator's strict flags with
   the +1 writeback port, the FU instantiation, and the redirect mux all active
   (a real integration/elaboration gate).

That is a **smoke test / liveness test**. It is worth having — it would catch a
gross wiring break, an elaboration regression, a hang, or a decode misroute. But
note what it is **not**: it never checks a single computed *value*, exercises one
op class out of nine, and runs only on the quiescent, non-speculative straight-line
path. It answers "does a parser instruction survive the pipeline?" — not "does the
pipeline execute parser instructions *correctly*?"

## 3. Gap analysis — bug classes, ranked by risk

Each row: the failure mode, whether any **current** test could catch it, and the
concrete test/fix that would. Severity is the tapeout cost if it escaped.
"Current" = `cva6-parser-test` **or** the standalone co-sim, as noted.

### P0 — correctness gaps that a smoke test structurally cannot see

- **G1 — No in-core value/result checking (no co-simulation).** *Sev: critical.*
  The test asserts liveness, never correctness. The in-core packet window
  (`parser_pktbuf`) and CAM (`parser_cam`) are **empty-backed**, and the metadata
  (`flow_keys`) write path is a dangling `_unused_meta` in `cva6_parser_wrap` — so
  a `store` executes but writes **nowhere observable**, and a `load` reads zeros.
  Nothing compares in-core execution against the golden model. *Current: not
  caught.* **Fix:** an in-core co-simulation harness — drive a real packet into an
  in-core packet buffer, run a real parser program, read back the metadata frame
  (or a `custom-3` read into an integer `rd`), and compare to the model
  bit-for-bit. This is the single highest-value thing to build; §5 lock-step is the
  gold-standard form of it.

- **G2 — Speculation / flush state corruption.** *Sev: critical (design bug
  risk).* `cva6_parser_wrap` commits persistent parser state at **execute** time:
  `st_q <= st_n` fires on `accept = parser_valid_i & parser_ready_o & ~flush_i`.
  The core has branch prediction (BTB/BHT/RAS) and *speculatively* fetches/issues
  past predicted branches. A parser op fetched in the shadow of a **mispredicted**
  branch (or before an older instruction's exception) can reach EX and mutate
  `st_q` **one or more cycles before** the squashing `flush` arrives — and that
  mutation is **never rolled back**. The architectural retirement is squashed
  correctly (the scoreboard entry is killed), but the parser's *internal register
  file* is now corrupted for all subsequent parsing. The `~flush_i` term only
  protects the *same* cycle, not a flush that arrives later. *Current: not caught*
  — the test runs only straight-line, non-speculative code. **Fix:** architectural
  — parser state must only become visible at **commit**, not execute (buffer the
  next-state and apply it when the instruction retires/commits, or gate on a
  "commit valid" for that `trans_id`), mirroring how CVA6's architectural state is
  commit-gated. **Test:** a directed program that puts a parser op in a
  mispredicted branch shadow and then checks parser state is unchanged; plus a
  random branch-shadow generator (§5).

- **G3 — End-of-node redirect never exercised in-core.** *Sev: high.* The
  `resolved_branch_o` mux — the entire *reason* custom-0 uses an in-pipeline FU
  rather than CV-X-IF (it must redirect fetch on a computed CAM target) — is wired
  but **never triggered** by the test. `redirect_pc_o`/`is_mispredict`/`cf_type`
  correctness, the frontend consuming the redirect, flush ordering, and the RAS/BTB
  interaction of an injected `JumpR` are all unverified in-core. *Current: not
  caught.* **Fix:** a directed test that programs a CAM target (needs `custom-3`,
  §4/G4) or a synthetic end-of-node, takes the redirect, and asserts fetch resumes
  at the expected PC; a formal check that `{branch, parser}` never both resolve in
  one cycle (the mux's mutual-exclusion assumption).

- **G4 — `custom-3` (coprocessor moves) entirely untested in-core.** *Sev: high.*
  `custom-3` reads `rs1` and writes an integer `rd` (`parser_result_o` /
  `parser_we_o`). No in-core test issues a `custom-3` op, so the operand-read path,
  the `we=1` writeback, and `rd != 0` integer-RF *and forwarding* paths are
  unproven. This is also the natural way to make G1 observable (read a parser
  register into `rd` and check it). *Current: not caught.* **Fix:** directed
  `custom-3` read/write tests with self-checking `rd` values; include a dependent
  instruction that consumes `rd` the next cycle (forwarding).

### P1 — coverage and hazard gaps

- **G5 — One op, one encoding.** *Sev: high.* Only `prs.load` (`0x1000000b`) runs
  in-core. `store`, `storeimm`, `lensetmin`, `cmpib/neib/ord`, `cam`, `camnext`,
  `next`, `stp`, and every `custom-3` move are unexercised through the real
  decode→`fu_op`→FU path. The decode table could mis-map any of them. *Current:
  the standalone decode co-sim (`parser-sim-decode`) covers decode correctness, but
  **not** the in-core routing.* **Fix:** an in-core program touching every op class;
  cross-check each test `.word` against `encoding.c`/`isa/parser-opcodes.yaml` so
  the hand-written encodings can't silently drift (G9).

- **G6 — Pipeline-hazard scenarios.** *Sev: high.* Untested: back-to-back parser
  ops under the single-in-flight interlock at full rate; a `custom-3` `rd`
  feeding an immediately dependent instruction (RAW/forwarding); WAW on the parser
  register file; a parser op adjacent to loads/stores/branches/CSR/mult contending
  for the writeback and commit ports. *Current: not caught.* **Fix:** directed
  hazard sequences + random interleaving (§5).

- **G7 — Interrupts / exceptions during a parser op, and parser-exit semantics.**
  *Sev: high.* A timer/external interrupt or a preceding faulting instruction while
  a parser op is in flight is untested; so is the parser's own exit path
  (`parse_exit_o`/`parse_code_o`) which is wired but not consumed in-core. Per the
  design, parser exits redirect (not trap) — that contract is unverified in-core.
  Also unaddressed: **context switch** — parser registers are internal state; an
  interrupt that swaps threads must save/restore them (Risk R2), and there is no
  mechanism or test for that. *Current: not caught.* **Fix:** interrupt-injection
  tests; a parse-exit redirect test; a design decision + test for parser-state
  save/restore across traps. **Progress:** the parse-exit redirect is realized in-core
  (I5, all 22 cosim cases), and the **preceding-faulting-instruction squash is closed by
  N4** (`parser_trap_v7.S` + the reusable `trap.S` scaffold: an `ecall` flushes an
  in-flight parser op, which re-executes and commits the fault-free result), and the
  **interrupt-mid-parse squash is closed by N5** (`parser_trap_v6.S`, reusing `trap.S`:
  a CLINT machine software interrupt — msip — flushes the in-flight parser op mid-parse;
  the handler clears msip and `mret`s without advancing mepc, so it re-executes and
  commits the interrupt-free result). V6+V7 cover both flavours of the FU `flush_i`
  (async interrupt / sync exception). Remaining: the context-switch save/restore (V10),
  which is decision-gated on the D7 parser-state ABI.

- **G8 — Metadata sink undefined in-core.** *Sev: medium (blocks G1).* There is no
  in-core metadata/`flow_keys` frame; store results are dropped. Until a sink
  exists (memory-mapped buffer or `custom-3` readback), store correctness cannot be
  observed in-core. **Fix:** define and wire the metadata destination (ties into
  Phase 8 packet buffer).

### P2 — methodology / infrastructure gaps

- **G9 — Hand-encoded instructions, no assembler.** *Sev: medium.* Test words are
  hand-written `.word`s; there is no assembler support (Phase 7) and no check that
  they match the model's `encoding.c`. A wrong constant could make the test pass on
  the wrong instruction. **Fix:** generate the test encodings from `encoding.c`
  (reuse `gen_parser_rom`'s `enc.hex`), or add `.insn`/assembler macros and diff.

- **G10 — Single core configuration.** *Sev: medium.* ✅ **2nd config closed (N6).**
  `nix run .#cva6-parser-config-wb` builds the patched model under a **second** existing
  RV64GC config — `cv64a6_imafdc_sv39_wb` (write-back cache, a different cache
  architecture / writeback-port arrangement than the default write-through) — and runs
  the in-core parser test on it: the `fu_t::PARSER` integration (extra WB port,
  `NrWbPorts` arithmetic, `PARSER_WB` indexing, issue/commit wiring) issues/executes/
  retires there too. **Still deferred:** the **superscalar** (`NrIssuePorts=2`,
  `SuperscalarEn=1`) config — it needs a new cv64 superscalar config pkg and validating
  the "no parser on issue port 1" interlock under two issue ports (§3.1).

- **G11 — No negative control in CI.** *Sev: low.* ✅ **Closed (N1 + N6).**
  `nix run .#parser-negative-control` builds the **stock** (unpatched) model and runs
  `tests/cva6-parser/negctl.S`: the identical custom-0 word the patched core executes
  traps illegal-instruction (mcause=2) on the base RV64GC decoder; the handler writes
  tohost=1 → fesvr SUCCESS, so a regression turning `custom-0` into a silent NOP would
  make *this* app fail. The base-ISA regression on the *patched* core is now a runnable
  app too — `nix run .#cva6-parser-baseisa` runs `tests/cva6-parser/base_isa.S`, a
  directed RV64GC slice (integer incl. `*w`, M, A, F/D, CSR, every branch flavour,
  JAL/JALR), each result value-checked, proving the `NrWbPorts`/pipeline change didn't
  break RV64GC. (The full upstream riscv-tests suite is the heavier deferred complement
  — the vendored `ci/build-riscv-tests.sh` flow stands it up for a Phase-7 run.)

- **G12 — No coverage measurement.** *Sev: medium.* Nothing measures functional or
  code/toggle coverage of the in-core FU, so "how much is tested" is unknown and
  "done" is undefined. **Fix:** functional coverage (op × qualifier × hazard ×
  control-flow outcome) with a numeric closure target; Verilator line/toggle
  coverage on the parser modules.

- **G13 — X-propagation / reset.** *Sev: medium.* Empty buffers read as defined 0
  today, but a real (uninitialized) packet buffer or CAM could inject X's; reset
  behavior of `st_q` and the interlock is only implicitly tested. **Fix:** an
  X-propagation pass (Verilator `--x-assign unique`/randomized) and an explicit
  reset/first-op test.

- **G14 — Timing / physical (not correctness, but tapeout-blocking).** *Sev:
  high at tapeout.* `parser_execute` is a single combinational blob per micro-op;
  it may dominate the critical path and cap frequency, and the injected `JumpR`
  redirect adds to an already-critical branch-resolution path. **Fix:** synthesis +
  static timing analysis (Phase 8); consider pipelining the FU.

## 4. Coverage matrix (in-core) — current vs. target

Legend: ✅ covered in-core · ➖ only standalone (not in-core) · ❌ not covered.

| Dimension | In-core today | Standalone | Target |
|--|--|--|--|
| Decode → `fu=PARSER` routing (custom-0) | ✅ (load only) | — | all op classes |
| Decode → `fu=PARSER` routing (custom-3) | ❌ | — | all moves |
| Datapath value correctness | ❌ | ✅ (vs model) | in-core co-sim vs model |
| Retire / writeback by `trans_id` | ✅ (we=0) | n/a | we=0 and we=1 (`rd`) |
| Integer `rd` write + forwarding (custom-3) | ❌ | n/a | RAW/WAW covered |
| End-of-node redirect (`resolved_branch_o`) | ❌ | n/a | redirect + target check |
| Parse-exit redirect (`parse_exit`) | ❌ | ✅ (exit codes) | in-core redirect |
| Speculation/flush safety | ❌ | n/a | branch-shadow squash test |
| Interrupt/exception during op | ❌ | n/a | injection tests |
| Hazards (back-to-back, dependent) | ❌ | n/a | directed + random |
| Context switch (save/restore state) | ❌ | n/a | design + test |
| Multiple core configs | ❌ | n/a | superscalar + no-cvxif |
| Coverage closure metric | ❌ | partial | numeric target |

## 5. How the industry does this — best practices to adopt

Processor verification is a mature discipline with hard-won lessons. The through
line: **directed tests find the bugs you thought of; the bugs that reach silicon
are the ones you didn't.** The mitigations, roughly in order of what we should
adopt:

1. **Co-simulation / lock-step against a reference model (step-and-compare).** Run
   the DUT and a golden ISS on the same program and compare architectural state at
   every retired instruction. This is the backbone of OpenHW's `core-v-verif` for
   CVA6 itself. For us: extend **Spike** (Phase 7) with the parser instruction
   semantics (reusing `libparsermodel`) and step-and-compare CVA6's retirement
   against it. This directly closes G1/G5 and most of §3.

2. **Constrained-random stimulus + functional coverage (coverage-driven
   verification).** Generate huge volumes of legal, randomized instruction streams
   — parser ops interleaved with normal code, branches, loads/stores, interrupts —
   and measure functional coverage until a target is closed. **`riscv-dv`**
   (CHIPS Alliance) is the standard generator and is extensible with custom
   instructions; it feeds a DUT+ISS lock-step. This is how G2/G6/G7 corner cases
   get hit without hand-authoring each one.

3. **Assertion-based verification (SVA).** Concurrent assertions on the *in-core*
   interfaces: handshake protocol (no `valid` without eventual `ready`), the
   writeback-port mutual-exclusion, "parser state changes only on committed ops"
   (the G2 property), "redirect implies exactly one of branch/parser resolving."
   We already have `parser_asserts.svh` for the unit; extend it to the seam.

4. **Formal property / equivalence checking.** Bounded model checking finds
   control-corner bugs random testing misses. **RVFI + `riscv-formal`** checks a
   core against the ISA; the analogous move here is formal proofs of the decode
   table (RTL decode == `isa/parser-opcodes.yaml`) and the redirect-mux
   exclusivity, plus a formal G2 proof that no state update survives a flush.

5. **Architectural compatibility & regression suites.** `riscv-tests` (the
   `tohost`/HTIF convention we already use) and **RISCOF/riscv-arch-test** ensure we
   didn't break the *base* ISA by adding the FU/writeback port — a real risk given
   we changed `NrWbPorts` and shared pipeline logic. Run the base regression on the
   patched core.

6. **Emulation / FPGA + post-silicon plans.** For volume and real traffic (Phase
   8), and because some bugs only appear at scale/speed.

### Lessons from famous CPU bugs (why "it passed" isn't enough)

- **Pentium FDIV (1994)** — a few missing entries in a lookup table; passed normal
  testing, failed on specific divisor patterns. *Lesson:* exhaustive/formal or
  directed-corner coverage of data tables; random data catches what examples miss.
  (Our analogue: the decode table and the sub-register extraction math.)
- **Pentium F00F, various TLB/errata** — legal-but-unusual instruction/state
  interactions. *Lesson:* interaction and corner-case coverage, not just
  per-feature tests.
- **Spectre/Meltdown** — the *specification* was met but the *microarchitecture*
  (speculation) leaked/behaved outside the architectural contract. *Lesson,* and it
  is exactly our **G2**: speculative execution must have **no** architecturally
  visible effect that survives squashing. A FU that mutates persistent state at
  execute violates this.

> These references are collected in [§7](#7-references).

## 6. Prioritized roadmap (risk-reduction per unit effort)

> **Current state.** Steps 1–4 below are **built and merged** (increments I1–I5, PRs
> #21–#26 — see the [status tracker](cva6-implementation-status.md)). What remains
> open from this roadmap is tracked in the single
> [canonical deferral list](cva6-verification-design.md#31-canonical-deferral-list-single-source-of-truth)
> — this doc does not keep its own copy.

1. **Fix G2 (speculation safety)** — make parser state commit-visible, not
   execute-visible; add the SVA property and a branch-shadow directed test. *This is
   a latent correctness bug, not just a coverage gap — do it first.*
2. **Build the in-core co-sim (G1/G8)** — a memory-mapped packet buffer + metadata
   frame (or `custom-3` readback), a real parser program in-core, read-back compared
   to the model. Makes every subsequent test self-checking.
3. **Add `custom-3` + the redirect path (G3/G4)** — the two integration paths the
   in-pipeline FU exists for; both self-checked.
4. **Cover all op classes in-core (G5)** and generate encodings from `encoding.c`
   (G9).
5. **Hazard/interrupt/exception directed tests (G6/G7)**; then **`riscv-dv`-style
   constrained-random** feeding CVA6+ISS lock-step for the long tail.
6. **Spike step-and-compare (Phase 7)** as the standing correctness engine.
7. **Base-ISA regression + negative control + multi-config + coverage closure**
   (G10/G11/G12) wired into CI as the sign-off gate.

Exit bar for "the in-core FU is verified": lock-step clean against the reference
over the full corpus **and** a constrained-random campaign, all §3 corner scenarios
covered, base-ISA regression green on the patched core, coverage target met, and
no unproven speculation/flush path.

### The reference flow to adopt (concrete)

The consistent industry pattern is **golden-model-first**: give an authoritative
reference model the custom instruction's semantics, then reuse the standard
stimulus + comparison machinery. For this project that means:

1. **Model the parser instructions in Spike** (the reference ISS) — reusing
   `libparsermodel` for the semantics. Spike is explicitly designed to be extended
   (add `riscv/insns/<name>.h`, register the opcode, wire it in; non-trivial
   extensions live under `customext/`); precedent is UCB-BAR's `esp-isa-sim`
   accelerator extension. *Caveat: Spike's C++ internals are not a stable API — pin
   the version.*
2. **Step-and-compare** CVA6's retirement against that extended Spike via
   **RVFI/RVVI** (CVA6 already exposes RVFI; `core-v-verif` does exactly this for
   the base core). This is the workhorse self-checking oracle.
3. **Generate stimulus with `riscv-dv`** — add a parser-instruction subclass so it
   is interleaved, constrained-legally, with normal RV64 code and real hazards.
4. **Keep the directed `tohost` tests** (what we have) as a fast smoke gate, and
   add **formal** (riscv-formal-style) for the bounded high-value properties (G2
   speculation-safety, decode-table correctness, redirect-mux exclusivity).
5. **Guardrail with the base-ISA regression** (riscv-tests + RISCOF/riscv-arch-test
   on the *base* ISA of the patched core) — we changed `NrWbPorts` and shared
   pipeline logic, so proving we didn't break standard instructions is not optional.

A crucial limitation to plan around (Alastair Reid's ISA-Formal experience): formal
ISA verification does **not** cover datapath *compute* correctness at scale, the
memory system, or instruction fetch — those stay the job of lock-step co-sim and
directed/random tests. No single technique suffices; layer them so their blind
spots don't align.

## 7. References

**RISC-V verification ecosystem**
- riscv-dv (constrained-random generator, CHIPS Alliance) — https://github.com/chipsalliance/riscv-dv
- OpenHW core-v-verif (CVA6 UVM env, step-and-compare) — https://github.com/openhwgroup/core-v-verif · strategy docs: https://docs.openhwgroup.org/projects/core-v-verif/en/latest/ · CVA6 env: https://docs.openhwgroup.org/projects/core-v-verif/en/latest/cva6_env.html
- riscv-tests (directed unit tests + HTIF `tohost`) — https://github.com/riscv-software-src/riscv-tests
- RISCOF — https://riscof.readthedocs.io/en/latest/intro.html · riscv-arch-test — https://github.com/riscv/riscv-arch-test *(note: RISC-V Intl is transitioning certification from RISCOF toward a newer ACT framework)*
- Spike / riscv-isa-sim (golden ISS) — https://github.com/riscv-software-src/riscv-isa-sim · custom-extension precedent (esp-isa-sim) — https://github.com/ucb-bar/esp-isa-sim
- Ibex↔Spike co-simulation (concrete lock-step reference) — https://ibex-core.readthedocs.io/en/latest/03_reference/cosim.html
- riscv-formal + RVFI (YosysHQ) — https://github.com/YosysHQ/riscv-formal · RVFI spec: https://github.com/YosysHQ/riscv-formal/blob/main/docs/source/rvfi.rst
- RVVI (RISC-V Verification Interface, lock-step) — https://github.com/riscv-verification/RVVI

**Processor-verification methodology & lessons**
- Alastair Reid et al., "End-to-End Verification of ARM Processors with ISA-Formal" (CAV'16) — https://alastairreid.github.io/papers/CAV_16/ · limitations: https://alastairreid.github.io/isa-formal-limitations/ · finding bugs vs proving absence: https://alastairreid.github.io/finding-bugs/
- OpenHW CORE-V Verification Strategy — https://docs.openhwgroup.org/projects/core-v-verif/en/latest/intro.html
- Bening & Foster, *Principles of Verifiable RTL Design* — https://books.google.com/books/about/Principles_of_Verifiable_RTL_Design.html?id=EFmw4YuKK5QC
- Siemens Verification Academy — assertions: https://verificationacademy.com/topics/assertions/ · SystemVerilog: https://verificationacademy.com/topics/systemverilog/
- Doulos — Coverage-Driven Verification methodology — https://www.doulos.com/knowhow/systemverilog/uvm/easier-uvm/easier-uvm-deeper-explanations/coverage-driven-verification-methodology/
- Dan Luu, "We saw some really bad Intel CPU bugs in 2015" — https://danluu.com/cpu-bugs/
- RemembERR (ETH ComSec, MICRO'22 — errata-as-data study) — https://comsec.ethz.ch/wp-content/files/rememberr_micro22.pdf

**Famous CPU bugs (the "it passed testing and shipped anyway" set)**
- Pentium FDIV — https://en.wikipedia.org/wiki/Pentium_FDIV_bug · silicon post-mortem: http://www.righto.com/2024/12/this-die-photo-of-pentium-shows.html
- Pentium F00F — https://en.wikipedia.org/wiki/Pentium_F00F_bug
- AMD Barcelona/Phenom TLB erratum 298 — https://www.legitreviews.com/amd-phenom-tlb-patch-benchmarked-and-explained_618
- Intel Sandy Bridge / Cougar Point (electrical/reliability, not logic) — https://www.theregister.com/2011/01/31/intel_coougar_point_chipset_flaw/
- Spectre/Meltdown (spec-vs-microarchitecture gap) — https://spectreattack.com/spectre.pdf · RTL contract-shadow-logic defense: https://arxiv.org/pdf/2407.12232
