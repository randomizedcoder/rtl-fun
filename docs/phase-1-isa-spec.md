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

> **➡ Normative spec:** this file is the overview. The precise, per-instruction
> **operational semantics** — one pseudocode routine per instruction plus the shared
> primitives and the two-stage end-of-node algorithm, patent-cited and precise enough
> for the golden model — are in
> [**`phase-1-isa-semantics.md`**](phase-1-isa-semantics.md). That is the Phase-1
> deliverable [Phase 2](phase-2-reference-model.md) binds to.

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
- **E-bit / `.be`** — field byte order. Network fields are big-endian; `E=1` (assembler suffix
  `.be`) keeps the big-endian value (its true numeric value — the common case), `E=0` (bare
  mnemonic) byte-swaps to the opposite order. (Model: `read_be` then `E ? keep : byteswap`.)
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
`STOP_PADDING_LIMIT`. The **full Parser Codes table with numeric values**
(`STOP_FAIL=−13`, `STOP_LENGTH=−14`, … `STOP_CNTR7=−32`) is recovered in
[`analysis/patent-encodings-recovered.md`](analysis/patent-encodings-recovered.md) §4.

### 1.11 Worked example — Ethernet + IPv4 (blog subset, real mnemonics)

```asm
ether_node:
    prs.load.h.be  paccum, pcurptr+12          ; EtherType (big-endian); last off=13 ⇒ CurHdr.Length=14
    prs.cam.h.stp  pnext,  paccum[0], 1         ; shared table 1: EtherType→node; pnext ⇒ Next (D=1); end-of-node
ipv4_node:
    prs.load.b     paccum, pcurptr             ; version + IHL (single byte, no .be)
    prs.lensetmin.n pcurhdr, paccum[1], 4:20    ; CurHdr.Length = IHL×4, min 20; sets DataBound
    prs.cmpi.b.fail paccum[0], 0x40:0xf0        ; version nibble == 4 (value:mask), else exit
    prs.load.b     paccum, pcurptr+9           ; IP protocol (single byte, no .be)
    prs.cam.b.stp  pnext,  paccum[0], 2         ; table 2: proto→node; pnext ⇒ Next (D=1); end-of-node
```

The patent's fuller worked program (Ethernet/IPv4/TCP-options/GRE flag-fields, ~20
instructions using `prs.tlvfastloop`, `prs.flagsloop.rev`, `prs.camjumploop`,
`prs.runthread`) is the reference to grow the slice toward — see the patent text
around its multi-protocol example.

### 1.12 Assembly notation (frozen)

The assembler/disassembler notation is **frozen** here (Phase-7 prose-freeze). Every spelling below
encodes to the exact same bits as the positional "Hybrid" form; `objdump` prints the canonical
spelling and it reassembles unchanged. Implemented by `tools/parser-gen` + the binutils patch
(see [phase-7-toolchain.md](phase-7-toolchain.md) §7.3).

**Dotted suffixes** — fold an attribute/discriminator bit into the mnemonic, exactly like the size
suffix `.b/.h/.w/.n/.d`:

| Suffix | Field → value | Meaning | Applies to |
|--------|---------------|---------|------------|
| `.be` | `E`=1 | field is big-endian — keep its numeric value (bare = `E`=0 = byte-swap) | load |
| `.stp` | `S`=1 | end-of-node (set the group's S bit) | cam, length family |
| `.stop`/`.stopnode`/`.stopsub`/`.fail` | `Er`=0/1/2/3 | compare on-false action (bare = `.fail` = 3) | cmp family |
| `.wild`/`.alt`/`.stop`/`.stopsub`/`.fail`/`.failsub` | `Miss` | CAM miss disposition | cam |

**Mnemonic aliases** — fold bits into the mnemonic name:

| Alias | Canonical encoding |
|-------|--------------------|
| `prs.lenset` / `prs.lensetmin` | the length op with `D`=0 / `D`=1 folded into the name (replaces `prs.lencur`); `D`=1 is thus the alias, **not** a `.min` suffix |
| `prs.lensetconst` | the length op with `Shift`=7 (constant length) + `Pos`=0 pinned — the separate spelling for the `mult:min` constant-length sentinel |
| `prs.cmpi.<sz>[.action]` / `prs.cmpine.<sz>[.action]` | the compare family with `Sz` + `Er` folded into the name — **deferred** (targets compare variants with no encoder yet) |

`prs.lensetadd` and the `pdathdr`/`pdatabnd` (`F2`=1/2) length targets are out of the current
encoder's scope (no golden-model op) and are not part of the frozen gas set.

**Operands:**

| Form | Field(s) | Meaning |
|------|----------|---------|
| `pcurptr+N` | load `Offset` | packet displacement from the current pointer (bare `pcurptr` = 0) |
| `pmeta+N` | store/storeimm `Offset` | displacement into the **metadata frame** (store targets the metadata, not the packet) |
| `paccum[i]` | `Pos` | Accum sub-register index |
| `value:mask` | cmp `Value`+`Mask` | joint immediate pair |
| `mult:min` | length `Shift`+`Len` | `Shift = log2(mult)`, mult ∈ {1,2,4,…,64}; `Len = min`. `Shift==7` is the constant-length sentinel, spelled `prs.lensetconst` (see above). |

**Destination decoration** — each op names its destination pseudo-register as the leading operand.
For most ops it is fixed by the opcode (disassembly derives it); for `prs.cam` the destination
**selects** the `D` bit — a single `prs.cam` mnemonic (there is no separate `prs.camnext`), matching
the patent's disassembly:

| Pseudo-reg | Meaning |
|------------|---------|
| `paccum` | load destination (fixed); `prs.cam … paccum` ⇒ Accum (`D`=0) |
| `pnext` | `prs.cam … pnext` ⇒ Next (`D`=1) — the destination selects the CAM `D` bit |
| `pcurhdr` | length family (in scope): required cosmetic dest, always `F2`=0 (CurHdr). `pdathdr` (`F2`=1, DataHdr) is deferred — no encoder yet |

Note: `prs.cam…stp` (the S bit inside the CAM word) and a standalone `prs.stp` (a `next`-group word)
have the same run-time effect (end-of-node) but are **different encodings** — not interchangeable at
the bit level.

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
- ✅ A per-instruction semantics spec precise enough to implement the golden model:
  [`phase-1-isa-semantics.md`](phase-1-isa-semantics.md) (normative pseudocode +
  shared primitives + `Common_End_of_Node` + the patent's worked trace + the
  Phase-2 `execute_*` binding).

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
