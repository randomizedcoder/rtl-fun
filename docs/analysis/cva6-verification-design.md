# In-core parser FU — implementation & verification design

> **What this is.** The companion [gap analysis](cva6-test-evaluation.md) said *what*
> is unproven about the in-core parser FU and *why* each gap is dangerous at
> tapeout. This document is the next step: it **designs how to build the fixes and
> how to prove them**. The verification half is deliberately **table-driven** —
> every check is a row in a manifest of `{stimulus → expected result → oracle}`,
> covering **positive, negative, boundary, and corner** cases — so coverage is
> something you can read off a table and grow by adding rows, not by writing new
> bespoke testbenches. A final section designs **manufacturing / self-test (DFT)**:
> the on-chip structures that prove each *fabricated* chip is good as it comes off
> the line and at every power-on — a concern distinct from proving the *design* is
> correct, and one that consumes a surprisingly large fraction of real silicon.

Reads on top of: [cva6-test-evaluation.md](cva6-test-evaluation.md) (the gap
register, G1–G14), [cva6-integration.md](cva6-integration.md) (signal map),
[phase-6-verification.md](../phase-6-verification.md) (standalone-unit plan).

## 0. Design principles (the invariants this plan holds to)

1. **Golden-model-first.** The C model (`model/libparsermodel`) is the single
   source of truth. Every test's *expected* output is produced by the model on the
   same input — never hand-authored — so RTL and model can never silently drift.
   This is already how the standalone suite works ([`verif/gen/gen_parser_rom.c`](../../verif/gen/gen_parser_rom.c));
   the in-core plan **extends the same generator**, it does not fork a second truth.
2. **Table-driven.** Tests are *data*: a manifest of rows, each a
   `{name, class, stimulus, expected}`. Adding coverage = adding a row. The
   generator already models this with `struct testcase { name; cat; expect_ok;
   build; }` (`gen_parser_rom.c:162`); we generalize that struct to carry in-core
   stimulus and expected pipeline effects too.
3. **Self-checking.** No test passes by "it ran." Every row asserts a concrete
   value (flow_keys bytes, exit code, `rd`, redirect PC) against the oracle, or a
   concrete property (an assertion). Liveness alone (today's `tohost` smoke test)
   is necessary but never sufficient.
4. **Layered oracles.** Directed tables catch the bugs we thought of; lock-step
   co-sim + constrained-random catch the ones we didn't; formal proves the handful
   of properties that must hold over *all* inputs. No single layer is trusted alone
   (Alastair Reid's ISA-Formal lesson: techniques have non-overlapping blind spots).
5. **One table, three consumers.** The same generated vectors drive (a) the
   standalone Verilator suite, (b) the in-core co-sim, and eventually (c) the
   **silicon power-on self-test** (§4.6). A packet that verifies the design in
   simulation should be the same packet that screens the chip on the tester.

## 1. Implementation design — ordered increments

The order is **risk-first**, matching the gap analysis roadmap: fix the latent
*correctness* bug before adding coverage, then build the observability that makes
every later test self-checking, then widen. Each increment names the files it
touches and its own exit check.

```
 I1  speculation-safe state  ──┐   (fixes G2: the latent design bug)
 I2  metadata sink + pkt feed ─┤   (fixes G1/G8: makes results observable)
 I3  custom-3 readback        ─┤   (fixes G4: the cheapest in-core oracle)
 I4  end-of-node redirect     ─┤   (fixes G3: the reason the FU is in-pipeline)
 I5  full op coverage + enc   ─┘   (fixes G5/G9: every op, encodings from model)
        │
        ▼
 V*  verification (§2) layers on top of I2/I3 once results are observable
```

### I1 — Speculation-safe parser state (fixes G2) — *do this first*

**The bug, precisely.** In [`cva6_parser_wrap.sv`](../../rtl/cva6_parser_wrap.sv)
the persistent parser register state is committed at **execute** time:

```systemverilog
assign accept = parser_valid_i & parser_ready_o & ~flush_i;   // line 91
always_ff @(posedge clk_i ...) if (accept) st_q <= st_n;       // line 112
```

`~flush_i` gates only a flush arriving *in the same cycle*. A parser op that
executes in the shadow of a branch mispredict (CVA6 has BTB/BHT/RAS and fetches
speculatively) mutates `st_q` one or more cycles before the squashing flush
arrives; the scoreboard kills the *architectural* retirement, but the parser's
internal register file is now **permanently corrupted**. This is the Spectre-class
"speculation must leave no surviving state" violation, as a functional bug.

**Fix — make parser state commit-visible, not execute-visible.** Two viable
designs; recommend shipping A first (obviously correct), then B for throughput.

```
Design A — commit-serialized (simplest, correct)
  • Do NOT write st_q at execute. Latch the computed next-state into a
    pending buffer tagged with its trans_id:
        st_pend_q, pend_trans_id_q, pend_valid_q   (set on `accept`)
  • Strengthen the issue interlock: the NEXT parser op may not issue until
    the previous one COMMITS (not merely retires from the FU). One parser
    op "in the commit window" at a time.
  • On commit of pend_trans_id_q:  st_q <= st_pend_q; pend_valid_q <= 0
  • On flush_i:                     pend_valid_q <= 0   (discard — st_q intact)
  Cost: a parser op every few cycles. Fine for a first correct version.

Design B — speculative w/ architectural shadow (target)
  • Keep speculative st_q updated at execute (fast path, forwards to the
    next op), PLUS a committed shadow st_arch_q updated only at commit.
  • On flush_i:  st_q <= st_arch_q   (roll back to last committed state)
  • On commit:   st_arch_q <= (the committing op's next-state)
  Cost: a second state register + restore mux. Full speculative throughput,
  correct rollback.
```

**What both need:** a **commit signal for the parser's trans_id** reaching the FU.
CVA6 commits in program order; `commit_stage` drives `commit_instr_o` /
`commit_ack_o` with a `trans_id`. **Decision/TBD:** thread a
`{commit_valid, commit_trans_id}` (or a 1-bit "the committing op is the pending
parser op") from `commit_stage.sv` → `ex_stage.sv` → the FU. This is the one new
cross-stage wire the fix costs; scope it during I1.

**Files:** `rtl/cva6_parser_wrap.sv` (state machine), `nix/cva6-parser/issue-ex.patch`
(commit wire + interlock tweak in `issue_read_operands.sv`), possibly
`commit_stage.sv` export.

**Exit check (V1, §2.5):** a directed program that lands a parser op in a
*mispredicted* branch shadow and then asserts parser state is byte-identical to a
run where that op never existed; plus an SVA property
`parser_state_changes |-> committed_this_trans_id` proven in formal.

### I2 — Metadata sink + in-core packet feed (fixes G1/G8)

Today the metadata write path is a dangling `wire _unused_meta` (`cva6_parser_wrap.sv:88`)
and the packet window / CAM are empty-backed, so a `store` writes nowhere
observable and a `load` reads zeros. Nothing can be compared to the model. This
increment builds the **observability substrate** the whole verification plan needs.

```
Design — a memory-mapped parser I/O region (pre-DMA, test-grade)
  ┌── packet buffer ──┐   loaded by the CPU (sd loop) or fesvr before the run,
  │  parser_pktbuf    │   at a fixed MMIO base; drives pkt_win_be_i.
  └───────────────────┘
  ┌── metadata frame ─┐   the store sink: meta_we/meta_off/meta_wdata/meta_nbytes
  │  flow_keys buffer │   land here; CPU reads it back with plain `ld` after the
  └───────────────────┘   parse to compare against the model's flow_keys.
  ┌── CAM image ──────┐   programmed via custom-3 (I3) or a test backdoor.
  └───────────────────┘
```

This is the **test-grade** feed (CPU/fesvr fills the buffer); the real DMA packet
feed and CAM programming are Phase 8. Keeping the sink memory-mapped means the
existing golden vectors (`packet.hex` / `expected.hex` from `gen_parser_rom.c`)
drop straight in: load `packet.hex`, run, `ld` the frame, `memcmp` vs `expected.hex`.

**Files:** `rtl/parser_pktbuf.sv` (MMIO write port), a new small `parser_meta.sv`
frame or reuse of `parser_pktbuf`, wiring in `ex_stage.sv`; a `parser_mmio.h`
address map under `toolchain/`.

**Exit check:** the baseline eth/ipv4/tcp packet parsed **in-core** yields a
flow_keys that `memcmp`-equals the model's — the first true in-core co-simulation.

> **⚠ As implemented (PR #22) — we took the shorter, sim-only path on purpose; loop
> back for the fuller solution when deeper analysis needs it.**
> The design above is the **test-grade MMIO** region (Option A). What I2 actually
> shipped is a **sim-only backdoor** (Option B), because it is a strict *subset* of
> Option A and carries far less risk:
> - **Metadata sink (built):** a commit-gated `meta_mem` frame (64×8, mirrors
>   `parser_top.sv`) inside `cva6_parser_wrap`. The per-op metadata write is buffered
>   in the pending FIFO and byte-scattered into the frame **only on commit** — the
>   same speculation-safety gate as the register state (I1), so a squashed op never
>   dirties the frame. Proven by `parser-wrap-test` (Scenario 4) and formally
>   consistent with the LSU store buffer.
> - **In-core value-check (built):** rather than a real `ld`/`sd` MMIO path, an
>   `ariane_testharness` XMR watcher (`nix/cva6-parser/tb-backdoor.patch`) reads
>   `meta_mem` hierarchically and prints `*** PARSER META OK ***` the cycle a
>   `prs.storeimm` (in `parser_insn.S`) commits `0xAB` to offset 4. `cva6-parser-test`
>   gates PASS on that marker — the first in-core value-check of the metadata sink.
> - **Deferred to the escalation (NOT built):** a real MMIO-mapped packet buffer +
>   metadata frame on the SoC AXI xbar (`ariane_soc_pkg` `axi_slaves_t` +
>   `NB_PERIPHERALS`, addr_map row, `axi2mem` slave, a `parser_pktbuf` write port, a
>   meta-read port threaded FU→`ex_stage`, `toolchain/parser_mmio.h`). This is
>   Option A above; ~6–9 files of shared *synthesizable* RTL. Build it when a genuine
>   `sd`/`ld` path or the Phase-8 packet DMA feed is required.
> - **Also deferred to I5:** the full packet→`flow_keys` equivalence vs the golden
>   model (table-driven cosim), where I3's custom-3 readback makes a program-driven
>   in-core self-check clean — more robust than fighting Verilator XMR at sim-end.
>
> Tracking: `cva6-implementation-status.md` (I2 row + notes).
>
> > **✅ ESCALATION CLOSED by I5 (PR #26).** Option A is now built — a real SoC AXI
> > slave at `ariane_soc::ParserBase` (`nix/cva6-parser/mmio.patch`): `axi2mem` bridges
> > `sd`/`ld` into the FU's `parser_pktbuf` write port and the commit-gated `meta_mem`
> > read port (ports threaded `ariane`→`cva6`→`ex_stage`→FU), plus ParseLen / exit-PC /
> > status registers; `toolchain/parser_mmio.h` documents the map. The I5 cosim feeds
> > every packet in and reads flow_keys back over the real bus — no backdoor. The
> > sim-only XMR watcher survives only for the pre-I5 `cva6-parser-test` markers. Full
> > design + the `axi2mem` registered-read gotcha: `docs/analysis/cva6-parser-mmio.md`.

### I3 — custom-3 readback (fixes G4) — the cheapest oracle

`custom-3` reads `rs1` and writes an integer `rd` (`parser_result_o`/`parser_we_o`).
It is the *lowest-effort* way to make parser state observable: read a parser
register into `rd` and self-check it — no MMIO frame needed for register-level
checks. Also exercises the `we=1` writeback and `rd != 0` integer-RF **and
forwarding** paths that custom-0 never touches.

**Files:** decode routing for `custom-3` (already patched — verify), the
writeback mux, a directed test consuming `rd` the next cycle (forwarding).

**Exit check (table rows in §2.3):** `custom-3` read of a known post-parse
register == expected; a dependent `add` on `rd` sees the forwarded value.

> **As implemented (PR #23).** Only the **read** direction (`CPPRSRD` /
> `prs.mv.x.p rd, p<cpreg>`) landed. `parser_decode` now decodes `custom-3` (0x7b) in
> the read form and carries `cpreg`/`rd_preg` in `micro_op_t`; `cva6_parser_wrap`
> services it as a register move — `read_preg(st_q, cpreg)` selects a `pstate_t` field
> (p11 Next, p13 DataBndLoop, p14 ParserExitCode, p15 Accum, p16 Flags, p1/p2 the
> flattened header `{len,off}`; others read 0), drives `rd`, and does **not** advance
> parser state or enter the pending queue (squashed with the op on flush). **No
> `cva6.sv`/patch change was needed:** the decoder already sets `rd = itype.rd` for
> custom-3 and `wt_valid[PARSER_WB]` already latches the result into the scoreboard →
> committed to `rd`, so `parser_we_o` is vestigial here (kept as a documented strobe).
> Verified in-core by a **program-driven self-check** (`parser_insn.S` reads p11 and
> writes `tohost` only on a correct value — no backdoor), which also exercises the
> integer-RF writeback + RAW forwarding, plus wrap-TB Scenario 5. Deferred custom-3
> forms: register **write** (`prs.mv.p.x`, needs rs1 routed to the FU), immediate
> load, and CAM/array programming (folds into I4). Tracked in the status doc.

### I4 — End-of-node redirect (fixes G3)

The `resolved_branch_o` mux (`ex_stage.sv`, the reason custom-0 is in-pipeline
rather than CV-X-IF) is wired but never triggered. With I2/I3 giving observability,
add a program that takes a real end-of-node redirect (CAM target) and asserts fetch
resumes at the expected PC.

**Exit check:** redirect PC observed == expected node target; an SVA that
`branch` and `parser` never both assert `resolve` in one cycle (the mux's
mutual-exclusion assumption); a `custom-3` readback confirms state after redirect.

> **As implemented — split into I4a (redirect) + I4b (CAM), PR #24 = I4a.**
> Grounding showed the redirect path is real (the ex_stage `gen_resolved_branch_mux`
> builds a mispredicting `resolved_branch_o` from `parser_redirect_pc`, and the
> frontend refetches on `resolved_branch.valid & is_mispredict`), but the FU emitted
> `redirect_pc_o` as a raw parser **node index**, not a byte PC. **I4a** fixes exactly
> that: `redirect_pc_o = pc_i + (target_node − cur_node)×4`, deriving the base from the
> current op's PC + node index (no external `ParserInstrBase`), valid while the parser
> program is a contiguous stride-4 block. **Resolve is same-cycle (combinational),
> not registered:** CVA6's mispredict flush (`controller.sv`, on
> `resolved_branch_i.is_mispredict`) only kills *un-issued* instructions + IF — it
> relies on a branch resolving the very cycle it is in EX (as `branch_unit.sv` does
> combinationally), before the next (wrong-path) instruction issues. A first cut that
> *registered* `resolve_branch_o`/`redirect_pc_o` fired one cycle late — after the
> poison store had already issued — and the ex_stage mux then sampled a stale `pc_i`,
> so fetch never steered and the core hung. The fix drives `resolve_branch_o`,
> `redirect_pc_o`, and `parse_exit_o` combinationally off the accepted parse op
> (`accept_state`), matching the branch contract exactly; only the *fetch steer* is
> speculative — parser register state and the metadata frame stay commit-gated (I1).
> **The redirect base needed a second fix:** `redirect_pc_calc = pc_i + delta×4` is
> only correct if `pc_i` is the *parser op's own* PC — but `ex_stage.pc_i`
> (`pc_id_ex`) is latched in `issue_read_operands` **only for `fu == CTRL_FLOW`**
> (it feeds `branch_unit`), so for a non-branch parser op it held the last branch's
> PC (in the smoke test, the boot ROM `jr` at `0x10014`). The redirect therefore
> computed `0x10014 + 2×4 = 0x1001c` (an in-core RVFI trace + a backdoor `pc_i` dump
> pinned this exactly: `pc_i=0x10014 nq=5 nn=7 rpc=0x1001c`) and the core jumped into
> the boot ROM and hung. The fix threads the parser op's PC into `pc_o` too — a small
> `issue-ex.patch` hunk latches `pc_o <= issue_instr_i[0].pc` when `fu == PARSER`
> (safe because parser and branch ops are mutually exclusive in-order). A
> `NEXTNODE`-driven end-of-node jump now
> steers the frontend refetch to the byte-translated target — proven in-core by a
> program that jumps over a **poison** store (`meta[5]` stays 0) onto a **landing**
> store (`meta[6]=0xCC`), watched by the backdoor (`*** PARSER REDIRECT OK ***`), plus
> wrap-TB Scenario 6. The **branch/parser
> mux-exclusivity SVA** and the **CAM-driven redirect** move to **I4b** (CAM
> programming needs a `parser_cam` write port + an rs1 operand threaded from ex_stage,
> so it edits the patch anyway; the mux SVA lands there with it). Custom-3 CAM/array
> and register-write forms are part of I4b. Tracked in the status doc.
>
> **As implemented (I4b — CAM programming + CAM-hit redirect).** Three custom-3 moves
> join `CPPRSRD`, all threading the integer `rs1` operand from `ex_stage`
> (`fu_data_i[0].operand_a`, which the CVA6 decoder already fills for custom-3 — no
> `issue_read_operands` change): **`CPPRSWR`** writes a p-register from `rs1` (enqueued +
> commit-gated exactly like a parse op — it reuses the I1 pending queue); **`CPPRSWRCAM`**
> programs a CAM entry, index = `rs1`, `{key,target}` sourced from `p[cpreg]` (patent
> pseudo-code: key = `p>>32`, target = `p[31:0]`) — so a directed program first
> `CPPRSWR`s the entry word into Accum (p15), then `CPPRSWRCAM`s it in; **`CPPRSRDCAM`**
> does a key lookup and returns the target into `rd`. `parser_cam` gains a **clocked
> write/delete port**; its combinational lookup is now muxed (parse ops key it from
> `parser_execute`, `CPPRSRDCAM` from `rs1`). This **unblocks `OP_CAMNEXT`**: a
> `CAMNEXT.s` that hits a programmed entry sets `Next = target`, and the same-cycle
> `f_eon` drives the I4a node-index→byte-PC redirect — proven in-core by a program that
> programs a CAM entry whose target is a node index, `CAMNEXT`s over a poison store
> (`meta[8]` stays 0) onto a landing store (`meta[9]=0xDD`), watched by the backdoor
> (`*** PARSER CAM REDIRECT OK ***`); the `CPPRSRDCAM` readback is self-checked via
> `tohost`. The deferred **branch/parser mux-exclusivity SVA** (`parser_branch_mux_excl`)
> landed here (the `gen_resolved_branch_mux` drops a branch resolve if the parser also
> resolves, so it asserts they never co-assert). Also proven by wrap-TB Scenarios 7
> (program → readback) and 8 (`CAMNEXT` hit → redirect).
>
> **✓ CAM-write speculation-safety — closed by N3.** The `CPPRSWRCAM` program now rides
> the same pending-queue commit-gate as parser register state (I1) and the metadata frame
> (I2): its `{index, key, target}` are buffered on accept and applied to the CAM only when
> the op **commits**, so a squashed speculative `CPPRSWRCAM` never reaches the CAM. Because
> there is no CAM speculative-forward path, a dependent lookup (`CPPRSRDCAM` or a parse
> `OP_CAMNEXT`) **interlocks** at issue until every older CPPRSWRCAM has committed — correct
> because CAM programming is setup-time (the patent treats it as setup, not a parse-hot-path
> op), and the older commit never depends on the stalled lookup, so it cannot deadlock.
> Proven by `parser_wrap_tb` Sc.12 (speculative program → flush → entry absent; program →
> commit → entry present) plus the `a_camprog_on_commit` / `a_cam_lookup_interlock` SVAs, and
> exercised in-core (`*** PARSER CAM REDIRECT OK ***`) and over all 22 cosim packets. Full
> packet→flow_keys equivalence still needs I5's model cosim (the golden model's CAM is static
> `const` tables and does not execute runtime `CPPRSWRCAM`, so the CAM-write path is in-core
> self-checked, not model-compared).

### I5 — Full op coverage + model-generated encodings (fixes G5/G9)

Extend the in-core program to touch **every** op class (store, storeimm,
lensetmin, cmpib/neib/ord, cam, camnext, next, stp, and every custom-3 move), and
**generate the test's instruction words from the model** (`encoding.c` /
`isa/parser-opcodes.yaml`) instead of hand-written `.word`s, so a wrong constant
can't make the test pass on the wrong instruction. `gen_parser_rom.c` already emits
`enc.hex` (the 32-bit encoded form) — reuse it to build the in-core `.S`.

**Exit check:** every op class routes decode→`fu_op`→FU correctly, each self-checked.

> **As implemented (PR #26).** The `cva6-parser-cosim` app (`scripts/
> cva6-parser-cosim.sh` + `nix/cva6-parser-cosim.nix`) is the table-driven in-core
> co-sim. `gen_parser_rom` emits the parse program (`enc.hex`) **and** the packed
> CAM-programming words (`camprog.hex`); the fixed driver (`tests/cva6-parser/
> cosim_main.S`) is linked per case with a generated `prog.S` (parse block + CAM
> table) and `case.S` (packet + expected flow_keys/code). Per case it `sd`s the packet
> over **real MMIO** (the I5 SoC peripheral — see the I2 escalation-closed banner and
> `cva6-parser-mmio.md`), sets `ParseLen` + an exit-landing PC, programs the CAM
> (CPPRSWR + CPPRSWRCAM), jumps into the contiguous custom-0 block, and the FU walks
> the graph (node-index→byte-PC redirects; a **subroutine-return redirect** to the
> landing PC on parse exit), then `ld`s the committed flow_keys + latched exit status
> back and compares to the model. **Result: 22/22, flow_keys byte-for-byte + exit code
> equal to the model** across positive/negative/boundary/corner — closing G5 (all op
> classes exercised) and G9 (program + CAM are model-generated, no hand `.word`s). One
> non-obvious integration bug is documented in the status tracker + MMIO doc: a
> peripheral hung off `axi2mem` must present **registered** read data (1-cycle latency),
> else the combinational `addr_o = cons_addr` next-beat advance returns `mem[addr+8]`.

## 2. Verification design — table-driven

### 2.1 The oracle and the generator

One generator, `gen_parser_rom.c`, already turns the model into vectors. We add an
**in-core manifest** so the same rows drive the CVA6 co-sim. Generalize the
existing case struct:

```c
struct testcase {                 // today (gen_parser_rom.c:162)
    const char *name;
    enum cat    cat;              // POS | NEG | BND | COR
    int         expect_ok;       // model must P_STOP_OKAY (or must fail)
    void      (*build)(pkt *);   // packet builder
};
// generalized for in-core (proposed):
struct testcase {
    const char *name;
    enum cat    cat;             // POS | NEG | BND | COR
    int         expect_ok;
    void      (*build)(pkt *);   // stimulus: packet …
    const char *program;        // … and/or parser program variant
    // expected (all model-derived, not hand-authored):
    //   expected.hex  flow_keys bytes      params.hex  {PKT_LEN, META_LEN, EXP_CODE}
    //   expected redirect PC (for I4 rows), expected rd (for custom-3 rows)
};
```

The runner reads the manifest and, per row, loads the packet into the in-core
buffer, runs the program, and compares **flow_keys, exit code, redirect PC, and any
`rd`** against the generated expectations. This is the in-core analogue of the
standalone `cases.txt` manifest the suite already uses.

### 2.2 Test taxonomy — positive / negative / boundary / corner

The four classes are already the project's convention (`enum cat { POS, NEG, BND,
COR }`, `gen_parser_rom.c:159`). Definitions we hold to:

| Class | Question it answers | Oracle |
|--|--|--|
| **Positive** | Does a *well-formed* input produce the *correct* result? | flow_keys + exit == model |
| **Negative** | Does an *ill-formed* input fail the *right way* (correct error class, no corruption, no hang)? | exit code == model's error; state safe |
| **Boundary** | Do exact edges (min/max lengths, off-by-one) behave? | == model at the edge |
| **Corner** | Do rare *interactions* (empty, deeply stacked, pipeline events) behave? | == model / property holds |

### 2.3 Table A — packet/datapath cases (extends the existing 15)

The standalone suite already has 15 rows (`gen_parser_rom.c:186`); the in-core
co-sim reuses them verbatim (that is the point of one generator) and adds the edge
rows below that the current set lacks. ✅ = row exists today, ➕ = to add.

| # | Name | Class | Expect | Checks |
|--|--|--|--|--|
| 01–08 | eth/ipv4·ipv6 × tcp·udp, vlan, qinq, ipv6-hbh, ipv6-frag | POS | OK | ✅ flow_keys bit-exact |
| 09 | unknown ethertype | NEG | fail | ✅ error class |
| 10 | ipv4 bad version | NEG | fail | ✅ |
| 11 | ipv4 unknown proto | NEG | fail | ✅ |
| 12 | ipv4 tcp minimal (ihl=5) | BND | OK | ✅ |
| 13 | ipv4 truncated | BND | fail | ✅ no over-read |
| 14 | empty packet | COR | fail | ✅ liveness (no hang) |
| 15 | eth-only, no L3 | COR | fail | ✅ |
| 16 | ipv4 **ihl=15** (max options) | BND | OK (`-4`) | ✅ full 60-B header walk |
| 17 | ipv4 **ihl=0** (illegal) | NEG | fail (`-14` LENGTH) | ✅ min-length trap |
| 18 | **deep VLAN stack** (40 tags) | COR | fail (`-24` MAX_NODES) | ✅ node-count / deep-loop guard |
| 19 | **ext-hdr len=0** chain (HBH) | COR | OK (`-4`) | ✅ liveness — len=0 ext advances 8 B (Risk R4) |
| 20 | packet == **256 B** (buffer exact) | BND | OK (`-4`) | ✅ pktbuf boundary |
| 21 | packet **> buffer** (264 B) | BND | OK (`-4`) | ✅ bytes ≥256 read 0; parse bounded (fail-safe) |
| 22 | 1-byte packet | COR | fail (`-14` LENGTH) | ✅ short-packet / aligner corner |

> **Status.** Rows **01–22 run in-core over real MMIO** in `cva6-parser-cosim`
> (22/22, flow_keys + exit bit-exact vs the model) and in the standalone RTL suite
> (`parser-sim-suite`, 22/22). Rows 16–22 were added by PR-4 as new packet builders
> in `verif/gen/gen_parser_rom.c`; because one generator feeds both consumers, adding
> them there closed the row in both suites at once. The generator self-checks every
> case against the model (fails the build on OK/fail disagreement), so the expected
> column above is the model's own verdict. The 264-B row exceeds the 256-B `pktbuf`;
> the standalone TB `$readmemh`'s a buffer-sized `pktbuf.hex` (bytes ≥256 dropped)
> while the cosim feeds the full `packet.hex` over MMIO with hardware dropping writes
> past the buffer — both see the same bound, and `ParseLen` still carries the true
> length. Table A is complete; no Table-A rows remain in the deferral list (§3.1).

### 2.4 Table B — instruction/op cases (fixes G5)

One row per op class, each self-checked via custom-3 readback (I3) or the metadata
frame (I2). Encodings generated from `encoding.c` (I5).

| Op class | Positive row | Negative/boundary row | Observed via |
|--|--|--|--|
| `load.{b,h,w,d}` | load known field == expected | load past `parse_len` → bound | custom-3 read of dest reg |
| `store` / `storeimm` | store field → frame == expected | store past frame → assert fires | metadata frame `ld` |
| `lensetmin.n` | sets length; next load in-bounds | min > remaining → fail | exit code / state |
| `cmpib` / `neib` / `cmpord` `.fail` | match → continue | mismatch → correct exit | exit code |
| `cam` / `camnext` | hit → correct target | miss → miss-target/fail | redirect PC (I4) |
| `next` / `stp` | end-of-node → redirect/exit | — | redirect PC / exit |
| custom-3 moves | read/write p-reg == expected | `rd`+forwarding | integer `rd` |

> **Status.** Every op class in this table is **exercised in-core** — the 22 cosim
> packets walk graphs that use load/store/storeimm/lensetmin/cmpib·neib·cmpord/cam/
> camnext/next/stp, and the custom-3 moves drive CAM programming + readback each run;
> the positive behaviour is model-checked end-to-end via flow_keys + exit code. The
> **negative/boundary** column is covered as follows:
> - *store past frame* — **directed** by `parser_wrap_tb` Scenario 10 (PR-5): a store at
>   the last valid byte (`off=63`) lands; a store past `META_MAX` (`off=64`) is
>   bounds-gated in `parser_execute` (`meta_we` suppressed) and corrupts no committed byte.
> - *lensetmin min>remaining* — Table A **row 17** (ipv4 `ihl=0`) trips the `LENCUR`
>   min-length trap in-core (`-14` LENGTH), model-checked.
> - *load past `parse_len`* — Table A **rows 13/22** (truncated / 1-byte) run a load off
>   the end and fail-safe (`-14`), model-checked; the standalone TB also carries the
>   `a_load_inbounds` safety assertion.
> - *CAM miss → miss-target/fail* — Table A **rows 09/11** (unknown ethertype / proto)
>   drive a `MISS_STOP` and fail (`-15`), model-checked.
>
> So the per-op negatives are now covered — the assertion-firing/boundary control that no
> corpus packet expresses is the `parser_wrap_tb` store-bound scenario; the rest are
> reachable directed packets. No Table-B rows remain in the deferral list (§3.1).

### 2.5 Table C — pipeline/integration cases (fixes G2/G3/G6/G7)

These are the *in-core-only* rows — the interactions the standalone unit cannot
have. Each is a directed program plus a property.

| # | Scenario | Class | Assertion |
|--|--|--|--|
| V1 | parser op in **mispredicted branch shadow** | COR | parser state unchanged vs no-op run (**G2**) |
| V2 | back-to-back parser ops at full issue rate | COR | each retires; interlock holds |
| V3 | custom-3 `rd` → **dependent next instr** | COR | forwarded value correct (**G6** RAW) |
| V4 | WAW on parser reg file | COR | last writer wins — ✅ PR-5: `parser_wrap_tb` Sc.9 proves committed/arch WAW; `parser_insn.S` self-checks it in-core |
| V5 | parser op adjacent to load/store/branch/CSR/mul | COR | no WB/commit-port contention — ✅ PR-5: `parser_insn.S` interleaves a custom-3 readback with mul/CSR/branch, value-checks both retires |
| V6 | **software/external interrupt** mid-parse | COR | clean; resumes or restarts correctly (**G7**) — ✅ N5: `parser_trap_v6.S` — a CLINT machine software interrupt (msip) flushes an in-flight CPPRSWR parser write mid-parse in-core; the handler clears msip and `mret`s WITHOUT advancing mepc, so it re-executes and commits the SAME value as an interrupt-free run (interrupt-run == clean-run + fired once) — the asynchronous companion to V7 |
| V7 | preceding **faulting** instr squashes parser op | COR | no state corruption (**G2/G7**) — ✅ N4: `parser_trap_v7.S` — an `ecall` flushes an in-flight CPPRSWR parser write in-core; after the handler returns it re-executes and commits the SAME value as a fault-free run (fault-run == clean-run + trap fired once) |
| V8 | **end-of-node redirect** taken | POS | fetch resumes at target PC (**G3**) — ✅ I4a + I5 (every cosim walk jumps mid-graph) |
| V9 | parse-**exit** redirect (not trap) | POS | redirects per contract (**G7**) — ✅ I5: on exit the FU steers fetch to a program-provided landing PC ("subroutine return"); all 22 cosim cases return + read back |
| V10 | **context switch** save/restore of parser regs | COR | state preserved (Risk R2 — needs design) |
| V11 | **reset** then first op | BND | defined state, no X (**G13**) — ✅ PR-5: `parser_wrap_tb` Sc.0 asserts `$isunknown`-free spec/arch state + first-op result out of reset |

V10 requires a *design decision first* (parser state is internal — how is it
saved/restored across a trap? CSR-mapped? memory-mapped? not-context-switchable
by contract?); the test follows the decision.

### 2.6 Beyond directed tables — the escalation layers

Directed tables are the floor. Layered on top, in adoption order:

1. **Constrained-random (`riscv-dv`).** Add a parser-instruction subclass so the
   generator interleaves parser ops with normal RV64 code, branches, loads/stores,
   and interrupts — hitting the V-table corners without hand-authoring each. Feeds
   the co-sim below.
2. **Lock-step step-and-compare vs extended Spike.** The standing oracle: extend
   Spike (Phase 7) with the parser semantics (reuse `libparsermodel`) and compare
   CVA6's retirement stream (via **RVFI**, which CVA6 already exposes and
   `core-v-verif` already uses) instruction-by-instruction. This is the workhorse
   that turns every random program into a self-checking test.
3. **Formal properties.** Bounded proofs of the handful that must hold for *all*
   inputs: the **G2** no-state-survives-a-flush property, decode-table correctness
   (RTL decode == `isa/parser-opcodes.yaml`), and redirect-mux exclusivity. Extend
   `rtl/parser_asserts.svh` to the in-core seam.
4. **Base-ISA regression.** `riscv-tests` + RISCOF on the *base* ISA of the patched
   core — we changed `NrWbPorts` and shared pipeline logic, so proving we didn't
   break standard RV64GC is a required gate, not a nicety.
5. **Coverage closure.** Functional coverage over the cross-product
   `op × qualifier × class × pipeline-event`, plus Verilator line/toggle coverage
   on the parser modules, with a **numeric closure target** that defines "done"
   (**Decision/TBD:** set the number with the corpus).

### 2.7 CI gate

Per push: Tables A/B/C directed + the base-ISA regression + the negative control
(assert the **stock** core traps on the parser ELF — fixes G11). The negative
control is now a runnable app (`nix run .#parser-negative-control`, **N1**): it
builds the *stock* (unpatched) model and runs `tests/cva6-parser/negctl.S` — the
same custom-0 word the patched core executes traps illegal-instruction (mcause=2)
on the stock decoder, whose handler writes tohost=1 → fesvr SUCCESS, so the pass IS
the assertion. The base-ISA regression half is now a runnable app too
(`nix run .#cva6-parser-baseisa`, **N6**): a directed RV64GC slice (integer incl. *w,
M, A, F/D, CSR, every branch flavour, JAL/JALR), each result value-checked, runs on
the *patched* model — the extension is behaviorally transparent to the base ISA. And
the FU is proven under a 2nd config (`nix run .#cva6-parser-config-wb`, **N6**) — the
patched model built under `cv64a6_imafdc_sv39_wb` runs the in-core parser test. Nightly:
a bounded `riscv-dv` + lock-step campaign and the fuzz budget. **Fail on** any value
mismatch, any watchdog timeout, any coverage regression, or a base-ISA regression.

## 3. Requirements traceability — every gap has an owner

| Gap (from eval) | Closed by | Proven by |
|--|--|--|
| G1 no value checking | I2 → **I5** | ✅ Table A in-core cosim over real MMIO (22/22) |
| G2 speculation/flush | **I1** | ✅ `parser-wrap-test` (V1 + rollback SVA) |
| G3 redirect untested | I4 → **I5** | ✅ V8/V9 realized (every cosim walk jumps + exit-returns) |
| G4 custom-3 untested | I3 / I4b / **N2** | ✅ custom-3 read (I3) + write/CAM-program/readback (I4b) + immediate-load (N2, `CPPRSWRIMM`); Table B custom-3 rows, V3, wrap-TB Sc.11 |
| G5 one op only | **I5** | ✅ all op classes in the cosim + wrap-TB |
| G6 hazards | I3/I1 + V-rows | ✅ RAW (V3), WAW (V4), adjacency/no-WB-contention (V5) — PR-5 (`parser_wrap_tb` + in-core `parser_insn.S`); V2 back-to-back interlock in wrap-TB Sc.3 |
| G7 interrupts/ctx-switch | I5 (+design) / **N4 / N5** | 🔵 V9 parse-exit redirect done (I5); **V7 faulting-squash done (N4)**; **V6 interrupt-mid-parse done (N5)** — both flavours of the flush_i that reaches the FU; V10 ctx-switch deferred (§3.1, needs the D7 ABI) |
| G8 metadata sink | I2 → **I5** | ✅ commit-gated frame, MMIO-visible, cosim-checked |
| G9 hand-encoded | **I5** | ✅ program + CAM model-generated (`enc.hex`/`camprog.hex`) |
| G10 single config | **N6** | ✅ `cva6-parser-config-wb` builds the patched model under a 2nd RV64GC config (`cv64a6_imafdc_sv39_wb`, write-back cache) + runs the in-core parser test — the FU integrates under a different config. Superscalar (`NrIssuePorts=2`) still deferred (§3.1) |
| G11 no negative control | **N1** (negative control) + **N6** (base-ISA) | ✅ `parser-negative-control` asserts the **stock** core traps the custom-0 word (illegal-instruction, mcause=2 → fesvr SUCCESS); **`cva6-parser-baseisa` asserts a directed RV64GC slice still retires on the PATCHED core** (extension is base-ISA-transparent). Full upstream riscv-tests suite is a deferred complement (§3.1) |
| G12 no coverage | — | §2.6.5 functional + toggle coverage |
| G13 X-prop/reset | I2 + V11 | ✅ V11 reset X-freedom (`parser_wrap_tb` Sc.0, `$isunknown`-free spec/arch state + first-op) — PR-5 |
| G14 timing/physical | Phase 8 | synthesis + STA (§5 tapeout exit bar) |

### 3.1 Canonical deferral list (single source of truth)

> Everything the I1–I5 arc **did not** close, in one place. The status tracker and
> the original [gap register](cva6-test-evaluation.md) point *here* rather than each
> keeping their own (drifting) copy. "Planned PR-N" refers to the follow-on
> verification-refactor sequence; the rest are Phase-7/8 escalations.

1. ~~**Table A rows 16–22** — edge packets: ipv4 `ihl=15`, `ihl=0`, deep VLAN stack,
   ext-hdr `len=0`, packet == 256 B, packet > buffer, 1-byte.~~ **✅ Closed by PR-4.**
   Added as packet builders in `verif/gen/gen_parser_rom.c`; they flow into **both**
   the standalone suite and the cosim (one generator), now **22/22** in each, with the
   model self-check gating the expected OK/fail. See §2.3 Table A.
2. ~~**Table B per-op negative/boundary rows** — store past frame, `lensetmin`
   min>remaining, load past `parse_len`, CAM miss.~~ **✅ Closed by PR-5.** Store-past-
   frame is a directed `parser_wrap_tb` scenario (bounds-gated, no write); the other
   three are directed reachable packets (Table A rows 17 / 13·22 / 09·11), model-checked.
   See §2.4.
3. ~~**V-table V4 / V5 / V11** — WAW on the parser reg file (V4); parser op adjacent to
   load/store/branch/CSR/mul (V5); reset → first op X-free (V11, **G13**).~~ **✅ Closed
   by PR-5.** V4 + V11 are `parser_wrap_tb` scenarios (Sc.9 / Sc.0); V4 + V5 are also
   self-checked in-core in `parser_insn.S`. See §2.5.
4. **V-table V6 / V7 / V10** — **V7 faulting-instruction squash ✅ closed by N4**
   (`parser_trap_v7.S` + the reusable `trap.S` scaffold: an `ecall` flushes an
   in-flight CPPRSWR, which re-executes and commits the fault-free result). **V6
   interrupt mid-parse ✅ closed by N5** (`parser_trap_v6.S`, reusing `trap.S`: a CLINT
   machine software interrupt — msip — flushes the in-flight CPPRSWR mid-parse; the
   handler clears msip and `mret`s without advancing mepc, so it re-executes and
   commits the interrupt-free result). V6+V7 together cover **both** flavours of the
   single-cycle `flush_i` that reaches the FU (async interrupt / sync exception), so
   **G7 is closed** for the realized parser state; context-switch save/restore (V10)
   remains deferred — it needs the parser-state ABI decision first (§6, D7).
5. ~~**CAM-write speculation-safety** — `CPPRSWRCAM` applies at execute, not
   commit-gated.~~ **✅ Closed by N3.** `CPPRSWRCAM` now buffers its `{index,key,target}`
   in the I1 pending queue and applies to the CAM only on **commit**; a dependent CAM
   lookup (`CPPRSRDCAM` / parse `OP_CAMNEXT`) interlocks at issue until every older
   CPPRSWRCAM commits (no deadlock — CAM programming is setup-time). A squashed
   speculative CAM write never reaches the CAM. `parser_wrap_tb` Sc.12 (flush → entry
   absent; commit → present) + `a_camprog_on_commit`/`a_cam_lookup_interlock` SVAs; cosim
   22/22 + in-core `*** PARSER CAM REDIRECT OK ***` still pass.
6. ~~**Deferred custom-3 form** — the immediate-load move.~~ **✅ Closed by N2.**
   `CPPRSWRIMM` writes a p-register from an 11-bit split immediate (`Imm2[20:15]`,
   `Imm1[11:7]`), commit-gated on the same I1 pending-queue path as `CPPRSWR`. RTL:
   `parser_decode` (I=1 leg + imm extract), `parser_pkg` (`wr_preg_imm`/`imm`),
   `cva6_parser_wrap` (imm → `write_preg`); the decode patch forces integer `rs1`/`rd`
   to x0 for I=1 (the immediate reuses those fields). Proven by `parser_wrap_tb` Sc.11
   (rollback + commit + readback) and an in-core directed row (writes p16, reads it
   back, and asserts the reused `Rd` register is untouched). Emitter: `prs_ld_immed`
   (`toolchain/parser_insn.h`). (Register write + CAM program + CAM readback merged in
   I4b, PR #25; register read in I3, PR #23.)
7. **Escalation layers (§2.6/§2.7)** — constrained-random `riscv-dv`, extended-Spike
   lock-step, base-ISA regression + negative control + 2nd config + coverage closure
   (**G10/G11/G12**). **Negative control ✅ N1** (`parser-negative-control` — the stock
   core traps the custom-0 word). **Base-ISA regression ✅ N6** (`cva6-parser-baseisa` —
   a directed RV64GC slice retires on the patched core; the full upstream riscv-tests
   suite is the heavier deferred complement). **2nd config ✅ N6** (`cva6-parser-config-wb`
   — the FU integrates under `cv64a6_imafdc_sv39_wb`); **superscalar `NrIssuePorts=2`
   stays deferred** — it needs a new cv64 superscalar config pkg + validating the
   no-parser-on-issue-port-1 interlock and `PARSER_WB` indexing. Coverage (N7, G12);
   `riscv-dv` + Spike lock-step stay Phase 7+.
8. **Real DMA packet feed** — the I5 MMIO peripheral is **test-grade** (CPU/fesvr
   fills the buffer); the DMA feed + runtime CAM programming from the wire are Phase 8.
9. **DFT / POST (§4)** — scan/ATPG/MBIST + power-on self-test ROM: a Phase-8 silicon
   concern (**G14**).

> **On G9 / "no hand `.word`s".** Model-generated encodings (no hand-written opcode
> constants) hold for the **cosim** path: `gen_parser_rom` emits `enc.hex` +
> `camprog.hex` and the driver assembles them verbatim. The directed
> `tests/cva6-parser/parser_insn.S` **remains hand-encoded on purpose** — it is the
> low-level bring-up test for I2/I3/I4 (metadata sink, custom-3 readback, redirect)
> that predates the generator-fed cosim, and each `.word` there is a deliberate
> directed stimulus, not a coverage gap. Stated once here; the tracker points back.

## 4. Manufacturing test & on-chip self-test (DFT)

Everything above proves the **design is correct** (functional / design
verification). It says nothing about whether a *particular fabricated chip* was
manufactured correctly — a stuck transistor, a broken via, a weak SRAM cell. That
is **structural / manufacturing test**, and it is a *separate discipline with its
own on-chip hardware*: **Design-for-Test (DFT)**. The user's observation is the
right one — a large fraction of a modern CPU's area exists only to test the chip,
not to run programs.

> **TBD/Decision.** DFT is a Phase-8 (silicon/ASIC) concern; on FPGA it is largely
> N/A (the fabric is pre-tested, memories are BRAM). This section is the *design
> intent* so the RTL is written DFT-aware now (no un-scannable logic, memories
> behind clean wrappers) rather than retrofitted painfully later.

### 4.1 Two different questions (don't conflate them)

| | Design verification (§1–§3) | Manufacturing test (§4) |
|--|--|--|
| Question | Is the *design* logically correct? | Was *this die* fabricated correctly? |
| When | Pre-silicon (sim/formal/FPGA) | Wafer sort, package test, burn-in, and every power-on |
| Oracle | Golden model | Fault models (stuck-at, transition, …) |
| Structures | Testbenches, assertions | Scan chains, BIST, JTAG — **on the chip** |
| Metric | Functional coverage | **Fault coverage** (% of modeled faults detected) |

### 4.2 Scan + ATPG — the backbone of structural test

**Scan insertion** stitches the design's flip-flops into shift registers (scan
chains): in test mode you can shift an arbitrary value into *every* flop
(controllability) and shift out the captured result (observability). **ATPG**
(automatic test pattern generation) then computes the minimal set of shift-in
vectors that detect a target **fault model** — classically **stuck-at** (a node
frozen at 0/1), plus **transition/at-speed** faults for delay defects. The quality
metric is **fault coverage**: the fraction of modeled faults a pattern set detects;
production CPUs target very high stuck-at coverage (commonly ~99%).

For the parser FU this means: the parser register bank — which is **flop-based**,
not an SRAM: the `pstate_t st_q` packed struct in `cva6_parser_wrap.sv:64/93` (the
p-registers `cur_off/accum/flags/next/…`, `parser_pkg.sv`) — plus the pending/shadow
state from I1 and the `parser_execute` datapath flops must all be **scannable**.
They are by default if we avoid latches, gated clocks without test bypass, and
combinational feedback. *Design rule for Phase 5 RTL now:* no un-scannable
constructs in the parser modules. (Note: the p-register bank is covered by **scan**,
not MBIST — it is flip-flops, not a memory array.)

### 4.3 MBIST — testing the parser's memories

Scan tests logic well but SRAM/CAM arrays need **MBIST** (memory BIST): a small
on-chip engine that writes/reads **March** patterns (e.g. March C-) to catch
stuck-at, transition, coupling, and address-decoder faults in the array, at speed,
without routing every cell to a tester. The parser has **two** true array clients
(the register bank is flops — scan, above):

| Array | In RTL | Depth × width | Test |
|--|--|--|--|
| Packet buffer | `parser_pktbuf.sv` (`mem`) | 256 × 8 b | MBIST March; boundary/aliasing patterns |
| CAM (parse-node lookup) | `parser_cam.sv` (`entry`) | 32 × 53 b | **CAM-specific BIST** (below) |
| *(metadata frame)* | `parser_top.sv` (`meta_mem`), sim scaffold | 64 × 8 b | MBIST March, once the in-core sink (I2) is a real array |

**Both arrays are behavioral models today** — `parser_pktbuf.mem` and
`parser_cam.entry` are unclocked arrays loaded by `$readmemh`, with the real
synthesizable SRAM/CAM structures explicitly deferred (comments in both files).
MBIST/CAM-BIST planning therefore targets those *future* structures; the design
rule now is just to keep them behind clean array wrappers.

**Why the CAM needs *special* BIST.** A CAM cell is storage **plus** a per-cell
comparator, so beyond the SRAM faults a March test covers, a CAM has **match/
mismatch faults, mask/wildcard faults, valid-bit faults, and multi-match priority
(address-priority) faults** that plain RAM MBIST won't exercise — and its match
output has poor observability (it propagates through a long priority encoder).
Industrial memory-BIST engines are adapted to CAMs with a modified test collar.

CVA6's own arrays (I$/D$, TLBs, BTB/BHT/RAS) get the same treatment in a real
tapeout. *Design rule:* wrap each parser memory so an MBIST wrapper can be inserted
at the array boundary. Optionally **BISR** (built-in self-repair with spare rows/
columns) to lift yield — overkill at our sizes; note as future.

### 4.4 LBIST + boundary scan — in-field and at the pins

- **LBIST** (logic BIST): an on-chip PRPG (pseudo-random pattern generator) drives
  the scan chains and a MISR (multiple-input signature register) compacts the
  responses to a signature compared against a golden value. LBIST needs no external
  tester, so it doubles as an **in-field / power-on** logic check (below), and is
  the basis of automotive functional-safety self-test.
- **Boundary scan (JTAG, IEEE 1149.1)** tests the *interconnect at the pins/board*.
  We get most of the plumbing for free: **CVA6 already integrates the pulp-platform
  `riscv-dbg` debug module with a JTAG DTM** (JTAG TAP → DTM → DMI → Debug Module,
  RISC-V External Debug v0.13.2). The same TAP a debugger uses to halt/step the hart
  — via an execution-based *park loop* + **program buffer** + **system-bus access**
  — can drive an in-system test and poke the parser memories. *Caveat for POST
  design:* `riscv-dbg` does **not** implement abstract-command *memory* access, so a
  JTAG-driven self-test reads/writes parser MMIO through the system bus or program
  buffer, not via abstract commands. Boundary-scan (1149.1) proper still needs its
  own BSR at the pads; the debug TAP is the on-chip access convenience, not a
  substitute for it.

*RVFI is not a DFT structure.* CVA6 exposes RVFI and `core-v-verif` uses it for
step-and-compare against Spike (§2.6.2), but RVFI is a **pre-silicon
verification/formal** interface — it does not exist as scan/BIST hardware in the
tapeout. Don't count it toward manufacturing-test coverage.

### 4.5 Production flow context (where these run)

Structural test runs at **wafer sort** (probe each die on the wafer — scan/ATPG +
MBIST on **ATE**, automatic test equipment), again at **package test**, and
sometimes after **burn-in** (accelerated aging to catch infant mortality). The
economic metric is **DPPM** (defective parts per million) shipped — test escapes
are what high fault-coverage buys down. This is the "as the chips come off the
factory line" step the user asked about.

### 4.6 POST / power-on self-test — and the elegant reuse

The **third consumer of our one test table** (§0.5). Beyond structural test on the
tester, the chip should verify *its own parser unit* at every power-on and
optionally periodically in the field:

```
   Boot ROM / POST routine
        │
        ├─ trigger LBIST/MBIST on the parser arrays  → compare signatures
        │
        └─ FUNCTIONAL self-test:  a small on-chip ROM of golden vectors
             (the SAME packet.hex / expected.hex the sim suite uses),
             run each through the real parser FU, memcmp flow_keys.
             Mismatch → flag the unit faulty (fuse/telemetry), don't ship traffic.
```

The functional POST is essentially the in-core co-sim (I2/§2.3) **shrunk to a ROM
and run on silicon**: the same golden `{packet → flow_keys}` rows that proved the
design now screen the chip. This is exactly the model used by **automotive
functional-safety Software Test Libraries** (STL) under **ISO 26262** — vendor-
provided self-test code that a safety-critical CPU runs at boot and during
operation to detect latent hardware faults. A few well-chosen rows (one per parser
op class + one redirect + one negative) give a fast, high-value power-on screen.

### 4.7 Area / effort budget (the user's "15–20%" question)

DFT is not free silicon — scan flops are larger than plain flops, and BIST engines,
MISRs, and JTAG logic are pure test overhead. The "a big chunk of the chip is for
test" intuition is **real**, but the precise fraction is workload- and
methodology-dependent, and the specific "Intel dedicates ~15–20% of the die to
test" number is **folklore** — it doesn't trace to a primary source, so this doc
won't state it as fact. What *is* defensible:

- **Area:** full scan adds **~10% to the sequential (register) area**; total-chip
  DFT overhead is commonly cited around **~5–15%** (scan, plus another ~10–15% *of
  scan* if LBIST is added), depending on how aggressively memories are wrapped and
  repaired. Test points at ~0.5–1% area can cut pattern count 20–50%.
- **Performance:** the scan mux in the flop path and added routing cost **~5–10%**.
- **The stronger statistic** — and probably the one behind the "chips spend a lot
  on test" intuition — is **test *cost***: test + assembly is frequently cited at
  **~25–30% of manufacturing cost** (up to ~50% for complex parts). If the point is
  "vendors pour enormous resources into proving each chip is good," the cost figure
  is the citable one, not a die-area percentage.

*For us the takeaway is qualitative:* budget for it, design the RTL scan/BIST-friendly
from the start (§4.8), and treat the parser memories as first-class MBIST clients.

### 4.8 Concrete DFT design rules for the parser RTL (adopt now)

1. No latches, no combinational feedback, no ungated clock gating without a
   test-enable bypass — keep every parser flop scannable.
2. Wrap `parser_pktbuf` and `parser_cam` (and the I2 metadata frame) at clean
   array boundaries so MBIST/CAM-BIST wrappers insert without touching the
   datapath — when their behavioral models become synthesizable SRAM/CAM. The
   p-register bank stays flop-based (scan, rule 1), not a memory.
3. Reset every state element from `rst_ni` to a defined value (already true of
   `st_q`, `cva6_parser_wrap.sv:94`) — no X after reset (also fixes G13).
4. Reuse the **CVA6 JTAG/debug TAP** as the access port for any test/POST trigger
   rather than adding a bespoke one.
5. Keep the golden vector set small and self-contained enough that a subset can
   live in a boot ROM as the functional POST (§4.6).

### 4.9 Reality check — none of this exists for CVA6 today

Two honest caveats so this section reads as *design intent*, not present state:

- **CVA6 ships no DFT.** The CVA6 Requirement Specification contains **no** scan/
  ATPG/MBIST requirements; the open RTL leaves DFT to whoever hardens it into
  silicon. (Ariane, CVA6's predecessor, was taped out in GF 22FDX at ETH Zurich,
  but no public source documents its scan/MBIST flow.)
- **Open-source DFT is partial.** OpenROAD does scan-cell replacement + chain
  stitching but **no ATPG and no MBIST**; the `Fault` toolchain (for OpenLane) adds
  scan insertion + pattern generation + fault simulation; MBIST/BISR for the open
  `OpenRAM` compiler exists only in research. A real parser-FU tapeout would lean on
  commercial DFT (Tessent / Modus / Synopsys) for ATPG + MBIST.

## 5. Phasing & exit bar

```
 now → I1 (G2 fix + V1 + formal)            ── the latent bug; highest priority
       I2/I3 (observability: frame + rd)     ── unlocks self-checking
       I4/I5 (redirect + all ops + enc)      ── the FU's raison d'être + breadth
       V-table directed (V1–V11)             ── in-core interactions
       riscv-dv + Spike lock-step (Phase 7)  ── the long tail
       base-ISA regression + coverage (CI)   ── the sign-off gate
       DFT: scan/MBIST-aware RTL now; scan/ATPG/BIST insertion + POST ROM (Phase 8)
```

**Exit bar — "the in-core FU is verified":** lock-step clean vs the reference over
the full corpus **and** a constrained-random campaign; every §2.5 V-row green;
base-ISA regression green on the patched core; coverage target met; no unproven
speculation/flush path (I1 formal property holds). **Exit bar — "the FU is
tapeout-ready":** the above **plus** scan/ATPG fault coverage target met, MBIST on
all three arrays, a functional POST ROM screening one row per op class, and timing
closure on `parser_execute` + the injected redirect path (G14).

## 6. Open questions / decisions

- **Decision (I1):** Design A (commit-serialized) first, then B (speculative +
  architectural shadow)? Recommend yes — ship correctness, optimize later.
- **Decision (I1):** exact `commit_valid`/`trans_id` signal to thread from
  `commit_stage.sv` to the FU. Scope during I1.
- **Decision (V10):** parser-state context-switch contract — CSR-mapped,
  memory-mapped, or "not context-switchable" by ABI? Test follows.
- **TBD (§2.6.5):** numeric functional-coverage closure target and fuzz budget.
- **TBD (§4.7):** confirmed DFT area-overhead figures (research pending) for §6
  references.
- **TBD (G10):** which config matrix (superscalar, CvxifEn off, accelerator on).

## 7. References

Builds on the methodology and citations in
[cva6-test-evaluation.md §7](cva6-test-evaluation.md#7-references) (riscv-dv,
core-v-verif, Spike, RVFI/riscv-formal, RISCOF, ISA-Formal, famous CPU bugs).
DFT-specific references are collected below.

**DFT area / test cost**
- DFT techniques & overhead survey (scan ~10% of register area) — https://www.researchgate.net/publication/398402574_Design_for_Testability_DFT_Techniques_in_Modern_VLSI_Chips
- Intel high-performance microprocessor DFT/ATPG strategy — https://www.researchgate.net/publication/4120296_An_optimized_DFT_and_test_pattern_generation_strategy_for_an_Intel_high_performance_microprocessor
- GHz general-purpose microprocessor DFT features & test — https://link.springer.com/article/10.1007/s11390-008-9193-0
- Test cost ~25–30%+ of manufacturing cost — https://semiengineering.com/test-costs-spiking/ · https://ontoinnovation.com/events/aec-apc-symposium-asia/reducing-packaging-costs-in-semiconductor-fabs-through-predictive-testing-models/

**Scan / ATPG / LBIST / MBIST / BISR**
- Scan design fundamentals — https://ecrionix.org/dft-course/day-02/ · DFT overview — https://ecrionix.org/dft/
- Tessent ATPG & fault models — https://blogs.sw.siemens.com/xcelerator-academy/2026/04/20/unlocking-efficiency-a-deep-dive-into-tessent-atpg-for-digital-ic-testing/
- Logic BIST (STUMPS/PRPG/MISR) — https://www.electronicdesign.com/home/article/21202239/combining-logic-bist-and-scan-test-compression · X-handling — https://semiengineering.com/dont-let-x-be-a-problem-for-logic-bist/
- MBIST & March C- — https://ecrionix.org/verification/mbist/ · SRAM BIST core — https://www.ijert.org/research/design-of-built-in-self-test-core-for-sram-IJERTV3IS030468.pdf
- CAM-specific BIST (match/mask/multi-match faults) — https://ieeexplore.ieee.org/document/8097123/ · https://www.researchgate.net/publication/224219513_Test_of_Embedded_Content_Addressable_Memories
- BIRA/BISR (self-repair) — https://link.springer.com/article/10.1007/s10836-007-5032-4

**JTAG / debug reuse & production flow**
- IEEE 1149.1 JTAG primer — https://www.corelis.com/education/tutorials/jtag-tutorial/jtag-technical-primer/
- RISC-V Debug DTM is built on a JTAG TAP — https://docs.riscv.org/reference/debug/v1.0/dtm.html · pulp-platform riscv-dbg (CVA6's DM) — https://github.com/pulp-platform/riscv-dbg
- CVA6 RVFI tracer / Spike step-and-compare — https://github.com/openhwgroup/cva6/blob/master/corev_apu/tb/rvfi_tracer.sv · https://github.com/openhwgroup/cva6/blob/master/corev_apu/tb/common/spike.sv
- Structural vs functional test — https://ecrionix.org/structural-functional-testing/ · manufacturing test vs verification — https://chipxpert.us/design-for-testability-vs-functional-verification/
- Wafer sort / final test / burn-in / DPPM — https://anysilicon.com/understanding-semiconductor-testing/ · https://semiengineering.com/understanding-test-quality-in-semiconductor-devices-an-overview/

**POST / in-field self-test (the POST-ROM model)**
- Power-on self-test — https://en.wikipedia.org/wiki/Power-on_self-test
- ISO 26262 self-test: BIST for functional safety — https://semiengineering.com/how-to-meet-functional-safety-requirements-with-built-in-self-test/ · Siemens BIST/ISO 26262 — https://resources.sw.siemens.com/en-US/white-paper-using-built-in-self-test-hardware-to-satisfy-iso-26262-safety-requirements/
- Software Test Library (STL) precedent — https://developer.arm.com/community/arm-community-blogs/b/embedded-and-microcontrollers-blog/posts/flexible-approach-to-adding-functional-safety-to-a-cpu

**RISC-V / open-core DFT status**
- CVA6 Requirement Spec (no DFT requirements) — https://docs.openhwgroup.org/projects/cva6-user-manual/02_cva6_requirements/cva6_requirements_specification.html
- OpenROAD DFT (scan stitching; no ATPG/MBIST) — https://openroad.readthedocs.io/en/latest/main/src/dft/README.html · Fault DFT toolchain — https://www.researchgate.net/publication/348497892_Fault_Open_Source_EDA's_Missing_DFT_Toolchain
- Ariane 22FDX tapeout — https://arxiv.org/pdf/1904.05442
