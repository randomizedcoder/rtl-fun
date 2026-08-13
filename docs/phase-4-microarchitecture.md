# Phase 4 — Microarchitecture

← [Phase 3](phase-3-encoding.md) · [Docs index](README.md) · [Phase 5 »](phase-5-rtl.md)

## Objective

Design *how* the parser instructions are implemented in CVA6: the parser
datapath, where packet bytes come from (the decisive bandwidth question), how the
parser unit hooks into the pipeline, and how parser-register state and hazards are
managed. Still no RTL — this is the blueprint [Phase 5](phase-5-rtl.md) builds.

## Inputs / prerequisites

- Phase 1 semantics, Phase 3 encodings.
- CVA6 pipeline structure (6-stage in-order: PC/IF → ID → ISSUE → EX → COMMIT).

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

**Recommendation:** prototype with a **128-bit packet window** (Option B-lite: a
small packet buffer or a widened read path) so the benchmark can actually show the
compute-bound speedup, and measure A vs B in Phase 9. This is the single most
important microarchitecture decision in the project.

### 4.2 Parser datapath (field extraction)

```
        packet window (128/256 bits)
                  │
                  ▼
        ┌───────────────────┐
        │  byte aligner     │◄──── offset (pcurptr + disp)
        └─────────┬─────────┘
                  ▼
        ┌───────────────────┐
        │  endian / bswap   │
        └─────────┬─────────┘
                  ▼
        ┌───────────────────┐
        │  shift / mask     │◄──── width (b/h/w/d), field selector [i]
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
  "miss") is an alternative for small key spaces.
- Programmable from the integer side (`CPPRSWRCAM`/`WRARRAY`).
- Sizing **TBD**: entries per table, total width. Start small (enough for the slice),
  leave a config/load path to grow.

### 4.4 Pipeline integration in CVA6

The parser unit is a **new functional unit** in EX, alongside ALU/MUL/LSU:

```
 ID ─► ISSUE ─► EX ┬─ ALU
                   ├─ MUL/DIV
                   ├─ LSU
                   └─ PARSER UNIT ── reads packet window, parser regs
                                   ── writes paccum/pcurhdr/pnext, meta
                                   ── may redirect fetch (end-of-node)
```

Key questions:
- **Latency:** single- vs multi-cycle. A wide extract + CAM likely multi-cycle;
  the unit stalls issue or uses a ready/valid handshake. (Semantics unaffected —
  layer discipline.)
- **Control-flow — two-stage end-of-node** ([Phase 1 §1.8](phase-1-isa-spec.md)):
  on `.stp`, the unit checks the **`Loop` register first** (advance `DataHdr.Offset`,
  redirect to the loop head), then **`Next`** (advance `CurHdr.Offset` unless
  **overlay**; increment `Counters.Encap` + advance the metadata-frame pointer on
  **encapsulation**). `Next`/`Loop` carry an **address-or-code** (bit-31) with the
  E/V/NE/NV control bits. The PC redirect reuses CVA6's branch/redirect path rather
  than inventing one; the unit must decode the control bits itself.
- **Exceptions/exit:** parser exit sets `ParserExitCode` (Error code + address) and
  jumps to `OkayTarget`/`FailTarget`. Note the patent defines **no CPU traps/
  interrupts** for the parser — exits are explicit jumps.

### 4.5 Parser-register file & hazards

- The patent defines **32 × 64-bit `p` registers** (not the handful the blog implies)
  — operational (`CurHdr`, `DataHdr`, `PktLen`, `Next`, `DataBndLoop` [DataBound +
  Loop], `Counters` [Encap + Cntr1..7], `NodeLoopCnt`, `Accum`, `Flags`,
  `MetadataBase`, `FrameOffFnumSeqno`, `ParserExitCode`, …) plus config registers
  (`ParserConfig`, `LoopSpec`, `TLVSpec`, counter configs) and target registers
  (`OkayTarget`, `PostLoop`, `CompareFalse`, …). Full layouts:
  [`analysis/patent-encodings-recovered.md`](analysis/patent-encodings-recovered.md).
- Several registers are **packed structs** (e.g. `DataBndLoop` = DataBound + Loop;
  `Counters` = Encap + 7 counters) — the RTL register file must expose sub-field
  read/write, not just 64-bit words.
- In-order + single parser unit ⇒ hazards are simple: RAW on parser regs handled by
  issue interlock; no rename needed.
- **Context switch (Risk R2, now larger than assumed):** the live parser state is
  ~17 operational + config/target regs. Define save/restore — parser regs as CSRs or
  a shadow block the OS can spill. For the first slice, minimize *in-use* state
  (single encap level, no runthread) to bound the cost.

## Step-by-step tasks

1. Decide the packet-window source & width (4.1) — prototype 128-bit buffer.
2. Specify the extract datapath stages + side effects (4.2).
3. Size & spec the CAM/sub-tables and their load path (4.3).
4. Define the CVA6 EX hook: issue handshake, latency model, fetch redirect (4.4).
5. Define the parser register file + hazard interlocks + save/restore (4.5).
6. Draft block diagrams and interfaces (signal-level) for Phase 5.

## Deliverables / artifacts

- This microarch doc with block diagrams and unit interfaces.
- A decided packet-window strategy and CAM sizing.
- A CVA6 integration plan (exact stages, signals, redirect path).

## Exit criteria

- Packet-data path, extract datapath, CAM, integration point, and register/hazard
  model are all decided and documented at signal-interface granularity.
- No unresolved dependency blocking RTL.

## Open questions

- **Decision:** L1D vs dedicated packet buffer for production (prototype = buffer).
- **TBD:** parser-unit latency & handshake with CVA6 issue.
- **TBD:** CAM depth/width and its (re)load mechanism.
- **TBD:** CSR vs shadow-file for parser-register context save/restore.

## References

CVA6 microarchitecture docs; blog for datapath intent. See [references.md](references.md).
