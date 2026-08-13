# Phase 1 — ISA specification

← [Phase 0](phase-0-scope-and-stack.md) · [Docs index](README.md) · [Phase 2 »](phase-2-reference-model.md)

## Objective

Define, precisely and implementation-independently, the **parser registers** and
the **semantics of every parser instruction** — following **US Patent 12,461,885**
(the authority), not just the blog teaser. This doc is the human-readable spec;
[Phase 2](phase-2-reference-model.md) turns it into an executable golden model, and
[Phase 3](phase-3-encoding.md) into bits.

> **Layer rule:** no cycle counts here. Semantics only.
>
> **Sources:** the patent claims + detailed description. Exact register field widths,
> `Sz` tables, and the address/code encoding are in
> [`analysis/patent-encodings-recovered.md`](analysis/patent-encodings-recovered.md);
> the gap analysis that drove this rewrite is in
> [`analysis/patent-conformance.md`](analysis/patent-conformance.md).

## Inputs / prerequisites

- Phase 0 scope (the vertical slice defines the minimum instruction subset to cover).
- Patent as the semantic source.

## Design detail

### 1.1 Parser register file

The patent defines **32 × 64-bit `p` registers** (not the 6 the blog implies).
Logical name (ABI name, number). Full struct layouts and cites:
[`analysis/patent-encodings-recovered.md`](analysis/patent-encodings-recovered.md) §5.

**Operational registers:**

| Reg (ABI) | Holds |
|-----------|-------|
| `ObjectRef` (pobjref, p0) | opaque PDU reference |
| `CurHdr` (pcurhdr, p1) | **Offset + Length** of the current *protocol* header |
| `DataHdr` (pdathdr, p2) | **Offset + Length** of the current *data* header (e.g. a TLV) |
| `PktLen` (ppktlen, p3) | `AllLen:32` (whole PDU) + `ParseLen:16` (bytes in parse buffer) + F/P |
| `FrameOffFnumSeqno` (pfofnsq, p4) | metadata `FrameOffset` + `FuncNum` + `Seqno` |
| `PktInfo` (ppktinf, p5) | work-item packet info (PktCtx, checksum, IFID, L/N/D) |
| `NodeLoopCnt` (pndlcnt, p6) | `NumLoops` + `NonPadCnt` + `PadLen` + `ConPad` + `NodeCnt` |
| `Counters` (pcount, p7) | `Encap` + `Cntr1..Cntr7` |
| `PktHdrBase` (phdrbas, p8) | base address of packet headers |
| `MetadataBase` (pmdbase, p9) | base of common metadata + frame array |
| `ParserInstrBase` (pinbase, p10) | base of parser code |
| `Next` (pnext, p11) | next node — **address or code**, with control bits (§1.8) |
| `PendingWork` (ppendwk, p12) | pending work-item index |
| `DataBndLoop` (pdbndlp, p13) | **`DataBound` + `Loop` register** (§1.2, §1.8) |
| `ParserExitCode` (pexcode, p14) | exit `Error` code + `Address` (§1.10) |
| `Accum` (paccum, p15) | accumulator — load target, lookup/compare/length source |
| `Flags` (pflags, p16) | flags in a flag-field loop; 2nd accumulator |

**Pseudo-registers** (assembly operands, computed, not stored): `pcurptr =
PktHdrBase + CurHdr.Offset`, `pdatptr = PktHdrBase + DataHdr.Offset`.

**Configuration registers** (limits/properties): `ParserConfig` (MaxNodes, MaxEncap,
MaxFrames, FrameSize, FrameOffset, EE, EO, PrsBuff…), `CounterLimitsConfig`,
`CounterArrayConfig`, `CouterArraySzResEncConfig`, `LoopSpec` (MaxCnt, MaxNon,
MaxPlen, MaxCPad, Disp, E), `TLVSpec` (IgnVal/IgnMask, PAD1, PADN, EOL, P/N/E).

**Target/exception registers:** `OkayTarget`, `FailTarget`, `Wildcard`,
`AltWildcard`, `AtEncap`, `PostLoop`, `CompareFalse`, `DataExtractBase`, `Timestamp`.

> **ABI/Risk R2 impact:** parser state is large (≥17 operational + config regs). The
> context-save story (Phase 4) must budget for this — it is not a handful of regs.

### 1.2 Two-level parsing model + `DataBound`

The patent separates **two levels** (Claim 2):

- **Level 1 — protocol headers:** *parse nodes* + *protocol tables*; state in
  `CurHdr`; next protocol looked up → `Next`.
- **Level 2 — sub-protocols / data headers:** *sub-parse nodes* + *sub-protocol
  tables*, iterated in a **loop**, for **TLV lists**, **flag-fields**, and
  **arrays**; state in `DataHdr`.

**`DataBound`** (`DataBndLoop.DataBound`) bounds the data elements within a header:
- init **∞** `0xFFFFFFFF`;
- `PLENCUR` sets `DataBound = CurHdr.Offset + CurHdr.Length − DataHdr.Offset`;
- `PLENDATABND` may only **tighten** it (else error);
- each iteration `DataBound −= DataHdr.Length`; the loop ends normally when
  `DataBound == 0`;
- data-context loads/lengths check **both** `DataBound` and `ParseLen`; over-bound →
  `STOP_TLV_LENGTH`.

### 1.3 Instruction set (families)

Full set (see [conformance §7](analysis/patent-conformance.md)); the **vertical-slice
subset** is marked ★. All-caps = hardware name; `prs.*` = assembler mnemonic.

- **Move / coprocessor** (custom-3): `prs.mv`, `prs.mv.x.p`, `prs.mv.p.x`;
  `CPPRSWRCAM/RDCAM/WRARRAY/RDARRAY` program the CAM/array from the integer side.
- **Load** ★ `PLOAD` (`prs.load*`) — §1.4. Loop-head loads: `PLOADTLVLOOP` ★,
  `PFLAGSLOOP(.rev)`, `PTLVFASTLOOP` ★ (single-byte type+length TLVs — IPv4/IPv6/TCP
  opts), `PLOOP`.
- **Length** ★ `PLENCUR/PLENDATA/PLENDATABND/PLENDATATLV/PLENDATAPAD/PLENDATATLVEOL`
  — `prs.lenset{,add,min}`, `.tlv*`, `.pad*`, `.eol*` — §1.5.
- **Store** ★ `PSTORE/PSTOREREG/PSTOREIMM` — to common metadata or a frame (`F`-bit);
  counter array-index; endian `E`-bit — §1.9.
- **Next / immediate:** `PNEXTNODE(.ov)`, `PSETIMM`, `PSETCODE`, `PSTP` ★, `PVARINT`
  (protobuf varint, zigzag), `PANDMASK`.
- **Extract / loop:** `PEXTRACT` (arbitrary contiguous bit-field), `PLOOP`.
- **Counters:** `PINCCNTR` (`prs.inc.cntr`/`prs.inc.encap`), `PSETCNTRBIT`,
  `PRESETCNTR` — §1.9.
- **CAM lookup** ★ `PCAM/PCAMNEXT/PCAMJUMP/PCAMJUMPLOOP/PCAMJUMPTLVLOOP` — §1.7.
- **Array lookup** `PARR/PARRNEXT/PARRJUMP/PARRJUMPLOOP` (twins of CAM).
- **Compare** ★ `PCMPIH/PCMPIB/PCMPINEB/PCMPILTB/LEB/GTB/GTEB` — §1.6.
- **Lifecycle:** `PINITPARSER` ★ (init from `a0..a7`), `PRUNTHREAD(.nokill)`,
  `PEVENTLOOP/PEVENTLOOPEND`.
- **Data extraction:** `PDATAEXTRACT` + pseudo-instrs (`PSEUDOMOVE/NIBBMOVE/
  STOREI16/STOREI8`) — fused multi-byte header→metadata copy (later phase).

Sub-register operand notation: size `[nbhw]` (nibble/byte/half/word), position
`<reg>[<pos>]`; `.stp` = end-of-node (S-bit); `.fail`/`.stop*` = on-false action.

### 1.4 Load-from-header (`PLOAD`) semantics

Loads 1/2/4/**8** bytes (per `Sz`; load `Sz==0` = 8 bytes) from the packet buffer
into a register. Attributes:
- **X-bit** — source: X set → data pointer `pdatptr+Offset`; clear → current pointer
  `pcurptr+Offset`.
- **E-bit** — endian swap (big-endian byte-swap before storing).
- **Shift** — left shift after the optional swap.
- **Blen** — number of high-order bits masked to zero (doubled when `Sz==0`).

Side effects (both are first-class ISA behavior):
1. **bounds check** — current: `CurHdr.Offset+Offset+n ≤ ParseLen`; data: also
   `Offset+n ≤ DataBound`. OOB → parser exits (`STOP_LENGTH`/`STOP_TLV_LENGTH`).
2. **load-sets-length** — if the load extends past `CurHdr.Length`/`DataHdr.Length`,
   that length is grown to cover the last byte loaded (the blog's Ethernet trick).

### 1.5 Length instructions

Set/check `CurHdr.Length` (`PLENCUR`), `DataHdr.Length` (`PLENDATA`/TLV/pad/EOL), or
`DataBound` (`PLENDATABND`). Length = `(field << Shift) + Len`; **D-bit / `.min`**
makes `Len` a minimum (computed length must be ≥ it); `Shift==7` = constant-length
check. All results are bounds-checked; failure exits with a code that depends on
protocol-vs-data context. `PLENCUR` also sets `DataHdr.Offset` (min-length start) and
initializes `DataBound` (§1.2). TLV/pad/EOL variants maintain the loop counters
(`NonPadCnt`, `PadLen`, `ConPad`) against `LoopSpec` limits.

### 1.6 Compare instructions

Compare a sub-register of `Accum` to an immediate. Variants: `PCMPIH` (half, eq/ne),
`PCMPIB`/`PCMPINEB` (byte, masked eq/ne), `PCMPILTB/LEB/GTB/GTEB` (nibble/byte/half/
word `< ≤ > ≥`). **On false**, the `Er` field selects the action (not just exit):
`stop` (parser), `stopnode`, `stopsub` (sub-node/loop), `fail`, or `cmpfail` → jump
to the `CompareFalse` handler. E.g. the IPv4 version check is
`prs.cmpi.b.fail paccum,0x40:0xf0` (value:mask).

### 1.7 CAM / array lookup

CAM entry = **20-bit key + 32-bit target** (address or code). Key union (recovered
§4): **shared** table (Shared 1..15, ≤16-bit match) or **non-shared** (8-bit match +
8-bit `Selector` derived from the PC: `(PC<<6)&0xFF00`). Lookup key = an `Accum`/
`Flags` sub-register (F-bit, Sz/Pos).

Result dispositions: **`PCAM`** → `Accum`; **`PCAMNEXT`** → `Next` (preserving control
bits); **`PCAMJUMP`** → jump to the returned address/handle code; **`PCAMJUMPLOOP`**
/ **`PCAMJUMPTLVLOOP`** → same, in a loop/TLV-loop iteration. **Miss actions**
(`.wild/.alt/.stop/.stopsub/.fail/.failsub`) select what happens on no match. Array
lookups (`PARR*`) are index-based twins with sub-array base indices.

### 1.8 End-of-node processing (`Common_End_of_Node`)

Runs when the **`.stp` / S-bit** is set (or at loop termination / via camjump code
handling). Two-stage algorithm (Claims 6–8):

1. **Check the `Loop` register first** (`DataBndLoop.Loop`):
   - **address** → live loop: advance **`DataHdr.Offset`** by the data-header length,
     jump there (next iteration);
   - **error code** → parser exits with the error;
   - **okay code** (`OKAY_RET` / `STOP_SUB_NODE_OKAY`) → fall through to `Next`.
2. **Then check `Next`:**
   - **address** → advance **`CurHdr.Offset`** by the header length, jump — **unless
     overlay**;
   - **overlay** node (`Next` bit `0x20000000`, V) → **offset does NOT advance**;
     pointers/lengths unchanged;
   - **encapsulation** node (`Next` bit `0x40000000`, E) → increment `Counters.Encap`,
     advance the metadata frame pointer (§1.9);
   - **error code** → exit with error; **okay code** (`STOP_OKAY`/NULL) → normal exit
     to `OkayTarget`.

Enforced limits: node count (`NodeCnt` vs `ParserConfig.MaxNodes`); loop iterations
(`NumLoops` vs `LoopSpec.MaxCnt`); encapsulation (`Encap` vs `MaxEncap`). `Next`/
`Loop` hold **address *or* code** (bit-31 encoding, §Phase-3).

### 1.9 Counters, encapsulation & metadata frames

- **Counters:** `Encap` + 7 user counters. `PINCCNTR` increments; per-counter max in
  `CounterLimitsConfig` with an **action on exceed** (stop / stop-error / exit-loop /
  don't-increment). Auto-reset at packet start; optional reset at encapsulation
  (`R*` bits). `PSETCNTRBIT` records event flags (single-occurrence enforcement);
  `PRESETCNTR` resets. Counters also index metadata arrays in stores (offset = base +
  counter × element-size).
- **Encapsulation & metadata frames:** metadata block = **common metadata** +
  **array of frames**. On each encapsulation the frame pointer advances by
  `RealFrameSize = 4*(FrameSize+1)` and `Encap` increments, bounded by `MaxEncap`
  (error if `EE`, overwrite-last if `EO`). Stores target common vs current frame via
  the `F`-bit.

### 1.10 Status / parser codes

Exit status is a **negative-byte parser code** (−1..−127; high bit set = code).
`STOP_FAIL(−12)` splits **normal** (>−12) from **abnormal** (≤−12) exits.
`ParserExitCode` holds `Error:16` + the exit instruction `Address:24`. Named codes in
the text: `OKAY_RET`, `STOP_OKAY`, `STOP_NODE_OKAY`, `STOP_SUB_NODE_OKAY`,
`STOP_LENGTH`, `STOP_TLV_LENGTH`, `STOP_LOOP_CNT`, `STOP_OPTION_LIMIT`,
`STOP_PADDING_LIMIT`. (The full numeric value table is a patent figure not in our
text — **TBD-from-figure**.)

### 1.11 Worked example — Ethernet + IPv4 (blog subset, real mnemonics)

```asm
ether_node:
    prs.load.h     paccum, pcurptr+12          ; EtherType; last off=13 ⇒ CurHdr.Length=14
    prs.cam.h.stp  pnext,  paccum[0], 1         ; shared table 1: EtherType→node; end-of-node
ipv4_node:
    prs.load.b     paccum, pcurptr             ; version + IHL
    prs.lensetmin.n pcurhdr, paccum[1], 4:20    ; CurHdr.Length = IHL×4, min 20; sets DataBound
    prs.cmpi.b.fail paccum, 0x40:0xf0           ; version nibble == 4 (value:mask), else exit
    prs.load.b     paccum, pcurptr+9           ; IP protocol
    prs.cam.b.stp  pnext,  paccum[0], 2         ; table 2: proto→node; end-of-node
```

The patent's fuller worked program (Ethernet/IPv4/TCP-options/GRE flag-fields, ~20
instructions using `prs.tlvfastloop`, `prs.flagsloop.rev`, `prs.camjumploop`,
`prs.runthread`) is the reference to grow the slice toward — see the patent text
around its multi-protocol example.

## Step-by-step tasks

1. Adopt the full register file (1.1); define `CurHdr`/`DataHdr` + pseudo-registers.
2. Specify the two-level model + `DataBound` lifecycle (1.2).
3. Write full semantics for each instruction family the slice needs (1.3–1.7).
4. Specify the two-stage end-of-node incl. overlay/encapsulation (1.8).
5. Specify counters, encapsulation, metadata frames (1.9) and parser codes (1.10).
6. Re-derive the worked example against the spec (1.11); then extend to VLAN stacking,
   IPv6 + extension-header **TLV loop**, and GRE flag-fields.

## Deliverables / artifacts

- This ISA spec, complete for the vertical slice, conformant to the patent.
- A per-instruction semantics table precise enough to implement the golden model.

## Exit criteria

- Every instruction used by the slice has unambiguous semantics, side effects, and
  error behavior matching the patent.
- The register file, two-level model, `DataBound`, and end-of-node algorithm are
  specified (not the blog's simplification).
- No cycle-count / microarchitecture language leaked in.

## Open questions

- **Decision:** which config/target registers are in-scope for the first slice
  (single encap level, no runthread) vs deferred?
- **TBD:** metadata-frame addressing details for the slice (one frame vs common).
- **TBD:** full `PVARINT`/data-extraction semantics — defer past the slice.

## References

Patent claims + detailed description; [`analysis/patent-conformance.md`](analysis/patent-conformance.md),
[`analysis/patent-encodings-recovered.md`](analysis/patent-encodings-recovered.md).
See also [references.md](references.md).
