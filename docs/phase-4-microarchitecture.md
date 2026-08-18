# Phase 4 — Microarchitecture

← [Phase 3](phase-3-encoding.md) · [Docs index](README.md) · [Phase 5 »](phase-5-rtl.md)

## Objective

Design *how* the parser instructions are implemented in CVA6: the parser
datapath, where packet bytes come from (the decisive bandwidth question), how the
parser unit hooks into the pipeline, and how parser-register state and hazards are
managed. Still no RTL — this is the blueprint [Phase 5](phase-5-rtl.md) builds.

The CVA6 attachment is worked out against the **pinned v5.3.0 source** at
signal granularity in [`analysis/cva6-integration.md`](analysis/cva6-integration.md);
this doc records the microarchitecture decisions, that doc records the exact
files/signals.

## Inputs / prerequisites

- Phase 1 semantics, Phase 3 encodings.
- CVA6 pipeline structure (6-stage in-order: PC/IF → ID → ISSUE → EX → COMMIT),
  read from the pinned tree (`nix build .#cva6-src`).

## Decisions (this phase resolves the Phase-4 open questions)

| # | Question | Decision |
|--|--|--|
| D1 | Packet-data source | **Dedicated on-chip packet buffer**, 256 B, with a **128-bit read window** (Option B-lite). A vs L1D measured in Phase 9. |
| D2 | CVA6 attachment | custom-0 = **new in-pipeline FU** `fu_t::PARSER` (needs fetch redirect); custom-3 = **CV-X-IF**. RoCC/`acc_dispatcher` rejected. |
| D3 | Latency / handshake | **Variable-latency** FU (ready/valid), like LSU — not the fixed-latency FLU path. 1 cycle load/len/cmp, 2–3 cycles cam+end-of-node. |
| D4 | End-of-node redirect | Reuse `branch_unit`'s path: drive `resolved_branch_o`/`resolve_branch_o`. Target computed from `Next`/`Loop` (JALR-like). No new redirect invented. |
| D5 | CAM sizing | 3–15 shared tables, **32 entries** provisioned (slice uses 13), entry = 20-bit key + 32-bit target (+valid). Behavioral first, synthesizable later. Loaded via custom-3 `CPPRSWRCAM`. |
| D6 | Register file | 32 × 64-bit p-regs *inside* the unit; sub-field access keyed by `(Pos,Sz)`. **One in-flight parser op** interlock ⇒ no rename, no per-reg scoreboard. |
| D7 | Context switch | **Ratified (bounded policy).** Save/restore through the custom-3 move ABI (`prs.mv.x.p`/`prs.mv.p.x`); minimize in-use state (single encap, no runthread) for the slice. No new CSRs. V10 round-trips {p11,p13,p14,p15,p16} between parses; **M1 extends the ABI to the position state (p1/p2/p6/p7/p8 writable, p9 done read-only)** so the resumable position+data register set round-trips and a genuine *mid-parse* switch resumes bit-exact vs the model. `done` is read-only (observed, not restored; mid-stream `done=1` wedges the frontend — deferred). Residual M2 (meta_mem frame + CAM restore) deferred. Proven in-core by V10 + M1. |

## Design detail

### 4.1 Where does packet data come from? (Risk R1 — the decisive choice)

If every `prs.load` is an ordinary CPU load through the LSU, we remove
instructions but stay **memory-bound** — the speedup largely evaporates. The real
win comes from feeding the extract logic a **wide window** of packet bytes.

```
Option A — reuse L1D                Option B — dedicated packet buffer
┌──────────────┐                    ┌───────────────────────────┐
│ L1D cache    │                    │ packet SRAM (on-chip)      │
│ 64-bit port  │                    │ 128/256-bit read port      │
└──────┬───────┘                    └───────────┬───────────────┘
       │ narrow                                 │ wide window
       ▼                                        ▼
  parser extract                          parser extract
  (memory-bound)                          (compute-bound → the win)
```

| | A: L1D | B: dedicated buffer |
|--|--------|---------------------|
| Complexity | low | higher (DMA/fill path, coherence) |
| Bandwidth | limited by cache port | wide, sized to the win |
| Realism for NIC/DPU | ok | matches datapath products |

**Decision (D1):** prototype with a **256-byte packet buffer** exposing a
**128-bit (16-byte) read window** at a byte-granular base. Rationale:

- A field load is ≤ 8 bytes at an arbitrary byte offset; a 16-byte window based at
  the (aligned-down) offset always contains the 8 needed bytes — one window read
  per `prs.load`, no straddle logic for the slice.
- 256 B covers the deepest slice header stack with margin (observed max
  `CurHdr.Offset` ≈ 62 B for IPv6+hop-by-hop+TCP; QinQ ≈ 42 B).
- `PKT_WINDOW_W` and buffer depth are RTL parameters (Phase 5 §5.5), so the A-vs-B
  and window-width sweeps in Phase 9 are cheap. This remains the single most
  important microarchitecture decision; Phase 9 measures it empirically.

### 4.2 Parser datapath (field extraction)

```
        packet window (128 bits)
                  │
                  ▼
        ┌───────────────────┐
        │  byte aligner     │◄──── offset (pcurptr + disp)
        └─────────┬─────────┘
                  ▼
        ┌───────────────────┐
        │  endian / bswap   │◄──── E (keep big-endian value)
        └─────────┬─────────┘
                  ▼
        ┌───────────────────┐
        │  shift / mask     │◄──── width (Sz: b/h/w/d), field selector [Pos]
        └─────────┬─────────┘
                  ▼
              paccum (+ side effects)
                  │
        ┌─────────┴──────────────────────────────┐
        ▼                                         ▼
  bounds check (last_off < pktlen)      implicit length
      exit-on-fail                      (pcurhdr = max(pcurhdr, last_off+1))
```

Companion units:
- **Length unit** — `lensetmin`: `len = field×M`, clamp-check `≥ MIN` and
  `pcurptr+len ≤ pktlen`; exit-on-fail; write `pcurhdr`.
- **Compare unit** — `cmpi.fail`: compare selected field to immediate; exit-on-fail.
- **CAM / lookup** — keyed by width/field into a numbered sub-table; hit → node
  address into `pnext`; drives end-of-node (`.stp`).
- **End-of-node** — `pcurptr += pcurhdr`; if `pnext` valid, redirect fetch to it,
  else raise parse-complete.

### 4.3 CAM / lookup structure

Per the patent (see [`analysis/patent-encodings-recovered.md`](analysis/patent-encodings-recovered.md)
§4): CAM entry = **20-bit key + 32-bit target** (target = address or code).
- Key is a **union**: *shared* tables (Shared 1..15, ≤16-bit match) or *non-shared*
  (8-bit match + 8-bit `Selector` **derived from the instruction PC**:
  `(PC<<6)&0xFF00`). The RTL must compute the PC-derived selector and detect
  selector collisions.
- A parallel **indexed array** lookup path (32-bit entries, sub-array base index, no
  "miss") is an alternative for small key spaces — deferred past the slice.
- Programmable from the integer side via the custom-3 R-form (`CPPRSWRCAM` /
  `CPPRSWRARRAY`, see `isa/parser-opcodes.yaml`).

**Decision (D5): sizing.** The slice needs 13 entries across 3 shared tables
(`eth_tbl` 4, `proto_tbl` 2, `ip6nh_tbl` 7 — see `model/libparsermodel/program.c`).
Provision **`CAM_DEPTH = 32`** entries × (20-bit key + 32-bit target + valid) with
Shared 1..15 selected by the instruction's `Share` field. **Behavioral**
associative match in simulation first (Phase 5), a synthesizable structure
(registered array + parallel comparators, or a small hash) later; both hide behind
the same `parser_cam` interface (§4.6). `CAM_DEPTH` is an RTL parameter.

### 4.4 Pipeline integration in CVA6

custom-0 parser instructions are a **new in-pipeline functional unit**
(`fu_t::PARSER`) in EX, alongside ALU/MUL/LSU/CVXIF:

```
 ID ─► ISSUE ─► EX ┬─ ALU ┐
                   ├─ MUL/DIV ├ FLU (fixed latency, one_cycle)
                   ├─ CSR ┘
                   ├─ LSU        (variable latency, own WB port)
                   ├─ FPU        (variable latency, own WB port)
                   ├─ CVXIF      (variable latency)  ◄── custom-3 moves
                   └─ PARSER ── reads packet window + parser regs
                             ── writes paccum/pcurhdr/pnext, metadata
                             ── may redirect fetch (end-of-node)  ◄── resolved_branch_o
```

**Decision (D2/D3).** custom-0 rides the in-pipeline FU surface because end-of-node
is a *computed control-flow transfer* — only an EX FU can drive CVA6's fetch
redirect. The parser is **variable-latency** (ready/valid to issue), like LSU; it is
deliberately outside CVA6's `one_cycle_select = alu_valid | branch_valid |
csr_valid` fast path. custom-3 coprocessor moves (register/CAM/array programming)
have no redirect and read `rs`/write `rd`, so they map onto **CV-X-IF**
(`cvxif_types.svh`). Full signal chain: [`analysis/cva6-integration.md`](analysis/cva6-integration.md).

Key mechanisms:
- **Latency:** wide extract + CAM is multi-cycle; the unit uses a ready/valid
  handshake with issue. A single in-flight parser op (§4.5) keeps this simple.
- **Two-stage end-of-node** ([Phase 1 §1.8](phase-1-isa-spec.md)): on `.stp`, check
  the **`Loop` register first** (advance `DataHdr.Offset`, redirect to the loop
  head), then **`Next`** (advance `CurHdr.Offset` unless **overlay**; increment
  `Counters.Encap` + advance the metadata-frame pointer on **encapsulation**).
  `Next`/`Loop` carry an **address-or-code** (bit-31) with E/V/NE/NV control bits
  the unit decodes itself. **The PC redirect reuses `branch_unit`'s path** —
  `resolved_branch_o` (`bp_resolve_t`) + `resolve_branch_o` — with
  `target_address` computed from `Next`/`Loop` instead of an immediate/JALR reg.
- **Exit (no traps):** parser exit sets `ParserExitCode` (error code + address) and
  redirects to `OkayTarget`/`FailTarget` via the **same `resolved_branch_o` path**,
  *not* CVA6's `exception_t` trap machinery — the patent defines no CPU traps for
  the parser.

### 4.5 Parser-register file & hazards

- The patent defines **32 × 64-bit `p` registers** — operational (`CurHdr`,
  `DataHdr`, `PktLen`, `Next`, `DataBndLoop` [DataBound + Loop], `Counters` [Encap +
  Cntr1..7], `NodeLoopCnt`, `Accum`, `Flags`, `MetadataBase`, `FrameOffFnumSeqno`,
  `ParserExitCode`, …) plus config (`ParserConfig`, `LoopSpec`, `TLVSpec`, counter
  configs) and target registers (`OkayTarget`, `PostLoop`, `CompareFalse`, …). Full
  layouts: [`analysis/patent-encodings-recovered.md`](analysis/patent-encodings-recovered.md).
- Several registers are **packed structs** (e.g. `DataBndLoop` = DataBound + Loop;
  `Counters` = Encap + 7 counters) — the register file exposes sub-field read/write
  keyed by `(Pos, Sz)` per the MSB-first sub-register convention, not just 64-bit
  words.
- **Decision (D6): hazards.** The p-regs live *inside* the parser unit (not CVA6's
  integer RF). In-order issue + a **single in-flight parser op** interlock (a parser
  op can't issue while one executes) removes every parser-reg RAW/WAW/WAR hazard for
  free — no rename, no per-p-reg scoreboard. Integer-side hazards for custom-3 moves
  are the ordinary `rs`/`rd` scoreboard dependencies CVA6 already tracks.
- **Context switch (Risk R2) — Decision (D7): RATIFIED as a bounded policy.**
  Save/restore rides the existing custom-3 move ABI: an OS spill/reload stub reads each
  live p-reg with `prs.mv.x.p` (CPPRSRD) and restores with `prs.mv.p.x` (CPPRSWR). No new
  CSRs, no runthread, single encap level for the first slice. The policy is proven in-core
  by the **V10 between-parse context-switch test** (`tests/cva6-parser/parser_ctxsw_v10.S`,
  `nix run .#cva6-parser-ctxsw-v10`): thread A's parser context is spilled to memory,
  clobbered by a simulated thread B, reloaded, and asserted bit-for-bit — over the real
  commit-gated pipeline. **ABI boundary (scope):** the round-trippable context is exactly
  the read∩write p-reg subset **{p11, p13, p14, p15, p16}** (p1/p2 were read-only
  telemetry), and every field in it round-trips losslessly.
- **Mid-parse register-state switch realized (M1).** The same ABI is *extended* (no new
  CSRs, no ready-logic change) to reach the in-progress *position* state:
  `read_preg`/`write_preg` gain **p1{cur_len,cur_off}, p2{dat_len,dat_off}** (promoted
  read-only→rw), **p6 node_cnt, p7 encap, p8 next_pc** writable; **p9 done** read-only
  (p8/p9 use free patent slots). The resumable position+data register set is now
  ABI-reachable, and a genuine *mid-parse* preemption is proven in-core: an async interrupt
  squashes a live parse op, the ISR saves/clobbers/restores those registers over the ABI,
  and the parse resumes to the golden model's byte-exact flow_keys
  (`tests/cva6-parser/parser_ctxsw_mid.S`, `nix run .#cva6-parser-ctxsw-mid`; deterministic
  encodings in `parser_wrap_tb` Scenario 14). **`done` (p9) is read-only** — a status flag
  the switcher observes (the mid-parse marker), not restorable cursor state: at a resumable
  checkpoint `done==0`, and writing `done=1` to a live parse stream is a spurious mid-stream
  exit that wedges the CVA6 frontend (a distinct limitation, deferred — not on the
  register-resume path). **Residual (M2, deferred):** a mid-parse switch to a
  STORE-ing / CAM-programming parse also needs a `meta_mem` flow_keys spill/reload port + a
  CAM save/restore path — neither is custom-3-reachable, and both cut against the
  minimize-in-use-state intent — so they stay deferred (see
  [cva6-verification-design.md §3.1](analysis/cva6-verification-design.md#31-canonical-deferral-list-single-source-of-truth)).

### 4.6 Unit interfaces (signal-level, for Phase 5)

Leaf-unit contracts the Phase-5 modules implement. Widths use CVA6 parameters
(`XLEN`=64) and parser parameters `PKT_WINDOW_W`=128, `CAM_DEPTH`=32,
`P_REGS`=32. `Sz`∈{dword,byte,half,word}, `Pos`=4-bit sub-register index.

| Module | Inputs | Outputs |
|--|--|--|
| `parser_align` | `win[PKT_WINDOW_W-1:0]`, `base[8:0]` (byte offset) | `bytes[63:0]` (8 bytes at base) |
| `parser_extract` | `bytes[63:0]`, `Sz`, `Pos`, `E`, `Blen`, `pktlen`, `curptr` | `accum[63:0]`, `last_off`, `bounds_fail`, `impl_len` |
| `parser_length` | `field[63:0]`, `mult`, `min`, `Shift`/const, `curptr`, `pktlen` | `curhdr_len`, `len_fail` |
| `parser_compare` | `field[63:0]`, `imm`, `mask`, `op` (eq/ne/lt/le/gt/ge) | `cmp_fail` |
| `parser_cam` | `key[19:0]` (from accum/flags), `share[3:0]`, `pc` (selector) | `hit`, `target[31:0]` |
| `parser_eon` | `next[31:0]`, `loop[31:0]`, `curhdr`, `datahdr` | `redirect`, `target_pc`, `encap`, `overlay`, `complete`, `exit_code` |
| `parser_regfile` | `raddr`, `waddr`, `Pos`, `Sz`, `wdata`, `we` | `rdata[63:0]` (sub-field aware) |
| `parser_pktbuf` | `base[8:0]`, fill port (Phase-8 DMA / Phase-5 preload) | `win[PKT_WINDOW_W-1:0]` |

`parser_execute` sequences these behind the CVA6 issue handshake
(`parser_valid_i`/`parser_ready_o` → `parser_valid_o`/`parser_trans_id_o` +
`resolved_branch_o` on end-of-node). Exact CVA6-side port names:
[`analysis/cva6-integration.md`](analysis/cva6-integration.md) §3–§5.

## Step-by-step tasks

1. ✅ Decide the packet-window source & width (D1) — 256 B buffer, 128-bit window.
2. ✅ Specify the extract datapath stages + side effects (4.2, 4.6).
3. ✅ Size & spec the CAM/sub-tables and their load path (D5, 4.3).
4. ✅ Define the CVA6 EX hook: FU tag, issue handshake, writeback, redirect path
   against pinned v5.3.0 signals ([cva6-integration.md](analysis/cva6-integration.md)).
5. ✅ Define the parser register file + hazard interlock + save/restore (D6, D7).
6. ✅ Draft block diagrams and unit interfaces (signal-level) for Phase 5 (4.6).

## Deliverables / artifacts

- This microarch doc with block diagrams, decisions (D1–D7), and unit interfaces.
- [`analysis/cva6-integration.md`](analysis/cva6-integration.md) — the file/signal
  map against pinned CVA6 v5.3.0 (opcodes, `fu_t::PARSER`, `resolved_branch_o`
  redirect, CVXIF for custom-3, patch checklist).
- A decided packet-window strategy (D1) and CAM sizing (D5).

## Exit criteria

- ✅ Packet-data path, extract datapath, CAM, integration point, and
  register/hazard model are all decided and documented at signal-interface
  granularity.
- ✅ No unresolved dependency blocking RTL — remaining items (below) are Phase-5
  bring-up tuning, not blockers.

## Open questions (deferred to Phase-5 bring-up / Phase-9 measurement)

- **Phase 9:** L1D vs dedicated packet buffer for production (prototype = buffer, D1).
- **Phase 5 bring-up:** exact `resolved_branch_o` mux/priority between `branch_unit`
  and the parser (mutually exclusive by the single-in-flight interlock, but pinned
  in HW); parser-unit cycle counts confirmed against the extract/CAM critical path.
- **Phase 8:** how the packet buffer is filled (sim preload vs DMA model).

## References

CVA6 microarchitecture (pinned v5.3.0 source, `nix/cva6.nix`); CV-X-IF spec;
[`analysis/cva6-integration.md`](analysis/cva6-integration.md); blog for datapath
intent. See [references.md](references.md).
