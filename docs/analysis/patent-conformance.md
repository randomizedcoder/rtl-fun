# Patent-conformance analysis

← [Docs index](../README.md) · [Overview](../00-overview.md)

**Purpose.** We are building this to help Tom Herbert, so the design must follow
his instructions as closely as possible. This doc compares our current design-doc
set against **US Patent 12,461,885 B2 "Parser instructions for CPUs"** (local copy:
[`../references/patent-us12461885.txt`](../references/patent-us12461885.txt); line
cites `Lnnnn` refer to that file) and lists concrete corrections.

> **Headline finding.** Our docs were written from the *blog post*, which is a
> ~6-instruction teaser. The **patent specifies a full parser ISA**: **32 × 64-bit
> parser registers**, **~40+ instructions**, a **two-level parsing model** with a
> `databound`, a **`Loop` register distinct from `Next`**, **encapsulation levels +
> metadata frames**, **counters**, a concrete **RISC-V encoding** (custom-0 `0x0b`
> + 4-bit function field; coprocessor moves in custom-3 `0x7b`), and a **negative-
> byte parser-code** status scheme. Everything we wrote is *directionally*
> conformant, but it is a small subset and diverges on several specifics below.

---

## 1. Verdict at a glance

| Area | Our docs | Patent | Status |
|------|----------|--------|--------|
| Parser registers | 6 (`pktbase/pktlen/pcurptr/pcurhdr/paccum/pnext`) + flat metadata | 32 × 64-bit `p`-regs (operational + config + target) | 🔴 **Major gap** |
| Two-level parsing (headers vs data/TLV/flag-field sub-nodes) + `databound` | Not modeled (TLV treated as generic loop) | First-class (Claim 2); `DataBound` register | 🔴 **Major gap** |
| End-of-node algorithm | advance `pcurptr` by `pcurhdr`, jump `pnext` | check **Loop reg first**, then **Next**; overlay; encapsulation | 🔴 **Divergent/incomplete** |
| Instruction set | 8 classes / ~8 mnemonics | ~40+ instructions (load/len/store/cam/arr/loops/cmp/cntr/varint/dataextract/lifecycle) | 🟠 **Partial** |
| Load attributes | bounds + implicit length | + endian-swap, shift, mask, X source (hdr vs data) | 🟠 **Partial** |
| Compare | `.fail` = exit only | eq/ne/lt/le/gt/ge + mask + 5 on-false actions | 🟠 **Partial** |
| CAM / array lookup | sub-tables → `pnext` | cam/camnext/camjump/camjumploop/camjumptlvloop (+array twins); miss actions; PC-derived selector | 🟠 **Partial** |
| Encoding & formats | custom-0..3 partitioned *by class*; guessed funct map | custom-0 `0x0b` + **4-bit function**; custom-3 for moves; 24-bit CAM / 16-bit PC-rel next; control bits E/V/NE/NV | 🔴 **Divergent** |
| Status / exit codes | generic enum | **negative-byte parser codes**, `STOP_FAIL(−12)` normal/abnormal split, `ParserExitCode` reg | 🟠 **Partial** |
| Counters | none | 7 user + encap; inc/setbit/reset; limits+actions; array-index | 🔴 **Missing** |
| Encapsulation + metadata frames | flat buffer | encap level, per-frame metadata, frame-ptr advance, limits | 🔴 **Missing** |
| Naming / mnemonics | blog-style `prs.*` | matches (`prs.lensetmin.n`, `prs.cmpi.b.fail`) | 🟢 **On track** |
| Core parsing invariant (len + next-type + `next_off = off+len`) | yes | Claim 1 | 🟢 **Conformant** |
| Load-sets-length trick | yes | Claim 12 (L1918–1920) | 🟢 **Conformant** |

**Bottom line:** the *architecture* we chose (parser unit + parser regs + wide
packet window + CAM) is right and matches the patent's intent. The *ISA content*
in Phase 1/3/4 needs a substantial expansion to match Herbert's actual design.

---

## 2. Register model (🔴 major gap)

Patent register file: **32 × 64-bit `p` registers** (L923, L1315); logical names
capitalized, ABI names lowercase `p…`.

**Operational registers we are missing or mis-modeled:**

| Patent reg (ABI) | Holds | Our status |
|------------------|-------|-----------|
| `CurHdr` (pcurhdr, p1) | **offset + length** of current protocol header (one reg) | We split into `pcurptr`/`pcurhdr`. Patent keeps offset+length together; `pcurptr` is a **pseudo-register** = `PktHdrBase+CurHdr.Offset` (L943, L1326). **Rename/realign.** |
| `DataHdr` (pdathdr, p2) | offset + length of current **data header** (e.g. a TLV) | ❌ missing — needed for sub-parsing |
| `PktLen` (ppktlen, p3) | `AllLen`(32) + `ParseLen`(16) + F/P bits | We have flat `pktlen`; patent distinguishes whole-packet vs in-buffer parse length (L1339–1351) |
| `DataBndLoop` (pdbndlp, p13) | **`DataBound` + `Loop` register** packed | ❌ missing — the two most important missing pieces (§3, §4) |
| `Next` (pnext, p11) | address **or** code, with control bits E/V/NE/NV | We have `pnext` as plain address; missing code-encoding + control bits |
| `Accum` (paccum, p15) | accumulator | ✅ have it |
| `Flags` (pflags, p16) | flags for flag-field loops / 2nd accumulator | ❌ missing |
| `Counters` (pcount, p7) | `Encap` + `Cntr1..7` | ❌ missing (§6) |
| `NodeLoopCnt` (pndlcnt, p6) | loop/pad/node counters | ❌ missing |
| `MetadataBase` (pmdbase, p9) | base of common metadata + frame array | We have a flat "metadata buffer"; missing frame model (§5) |
| `FrameOffFnumSeqno` (pfofnsq, p4) | metadata **FrameOffset** + FuncNum + Seqno | ❌ missing |
| `ParserExitCode` (pexcode, p14) | Error(16) + Address(24) | We reference "status" but not this reg (§7) |
| `PktHdrBase`/`ParserInstrBase`/`ObjectRef`/`PktInfo`/`PendingWork` | bases + work-item state | ❌ missing |

**Config registers** (limits/properties), all missing from our docs: `ParserConfig`
(MaxNodes/MaxEncap/MaxFrames/FrameSize/EE/EO…), `CounterLimitsConfig`,
`CounterArrayConfig`, `CouterArraySzResEncConfig`, `LoopSpec`
(MaxCnt/MaxNon/MaxPlen/MaxCPad/Disp/E), `TLVSpec` (L1535–1709).

**Target/exception registers** (address holders), all missing: `OkayTarget`,
`FailTarget`, `Wildcard`/`AltWildcard`, `AtEncap`, `PostLoop`, `CompareFalse`,
`DataExtractBase`, `Timestamp` (L1711–1762).

**Action → Phase 1 & Phase 4:** replace our 6-register table with the patent's
register file (at least the operational + the config/target regs the first vertical
slice touches). Adopt `CurHdr`/`DataHdr` (offset+length) and the `pcurptr`/`pdatptr`
pseudo-registers. This also revisits Risk R2 (context-save) — the real state is
much larger than we assumed.

---

## 3. Two-level parsing model + `databound` (🔴 major gap)

The patent (Claim 2; L735–786, L1496–1512) makes **sub-protocol parsing**
first-class and distinct from protocol-header parsing:

- **Level 1 — protocol headers:** parse nodes + protocol tables; state in `CurHdr`.
- **Level 2 — sub-protocols / data headers:** *sub-parse nodes* + *sub-protocol
  tables*, looped, for **TLV lists**, **flag-fields**, and **arrays**; state in
  `DataHdr`.

**`DataBound`** (`DataBndLoop.DataBound`) = "the maximum length of all the data
elements included within the protocol header" (Claim 6, L120). Lifecycle:
- init **infinity** `0xFFFFFFFF` (L1501, L3765);
- `PLENCUR` sets `DataBound = CurHdr.Offset + CurHdr.Length − DataHdr.Offset`
  (L2305–2306);
- `PLENDATABND` may only **tighten** it (error otherwise, L2342);
- each loop iteration `DataBound −= DataHdr.Length` (L2115, L3809); loop ends
  normally when `DataBound == 0` (L777, L1950, L2052).
- Loads/lengths in data context check against **both** `DataBound` **and**
  `ParseLen`; over-bound → `STOP_TLV_LENGTH` (L1914–1916, L2324).

**Our docs** treat TLV / IPv6-ext / VLAN as a generic `prs.loop` and have no
`DataHdr`, no sub-nodes, no `databound`. This is the single biggest conceptual gap.

**Action → Phase 1 (add the two-level model + databound), Phase 2 (model must
implement DataHdr + databound and the malformed-TLV cases against it), Phase 4
(register state).**

---

## 4. End-of-node & control flow (🔴 divergent/incomplete)

Our `.stp` = "advance `pcurptr` by `pcurhdr`, jump `pnext`". The patent's
`Common_End_of_Node` (Claims 6–8; L124–147, L323–336, L3651–3668) is a two-stage
algorithm:

1. **Check the `Loop` register first** (`DataBndLoop.Loop`):
   - **address** → live loop: advance **`DataHdr.Offset`** by data-header length,
     jump there (next iteration);
   - **error code** → parser exits with the error;
   - **okay code** (`OKAY_RET` / `STOP_SUB_NODE_OKAY`) → fall through to `Next`.
2. **Then check `Next`:**
   - **address** → advance **`CurHdr.Offset`** by the header length and jump —
     **unless overlay**;
   - **overlay node** (Next bit `0x20000000`) → **offset does NOT advance** (L3666);
   - **encapsulation node** (Next bit `0x40000000`) → increment encap level, advance
     metadata frame pointer (L3661, §5);
   - **error code** → exit with error; **okay code** (`STOP_OKAY`/NULL) → normal exit
     to `OkayTarget`.

Key divergences to fix: (a) the **`Loop` register checked before `Next`**; (b)
**data-header vs current-header** advance are different; (c) **overlay** nodes;
(d) **encapsulation** handling; (e) `Next`/`Loop` hold **address *or* code**, not
just an address. Also **node-count limit** (`NodeCnt` vs `ParserConfig.MaxNodes`)
and **loop-iteration limits** (`NumLoops` vs `LoopSpec.MaxCnt`).

**Action → Phase 1 §1.3 (rewrite end-of-node), Phase 4 (control path & redirect),
Phase 5 (RTL `parser_eon.sv` must implement both stages + overlay/encap).**

---

## 5. Encapsulation & metadata frames (🔴 missing)

Patent (Claim 10; L951, L1466–1470, L3651–3668): metadata block = **common
metadata** followed by an **array of metadata frames**. On each encapsulation layer
the **frame pointer advances by the frame size** (`RealFrameSize =
4*(ParserConfig.FrameSize+1)`), `Counters.Encap` increments (either via a Next
encapsulation bit or `prs.inc.encap`), bounded by `ParserConfig.MaxEncap` (error if
`EE`, overwrite-last if `EO`). Stores target **common metadata** *or* the **current
frame** via an `F`-bit (L2152).

**Our docs** have a single flat metadata buffer and no encapsulation concept.

**Action → Phase 1 (store instr + metadata model), Phase 4 (metadata frame
addressing), Phase 0 (the flow-dissector slice has one encap level, so this can be
staged — but the model must exist).**

---

## 6. Counters (🔴 missing)

Patent (Claim 11; L1441–1461, L2623–2748): 7 user counters + encap; instructions
`PINCCNTR` (`prs.inc.cntr`/`prs.inc.encap`), `PSETCNTRBIT` (event flags,
single-occurrence enforcement), `PRESETCNTR`. Per-counter **max** with **action on
exceed** (stop / stop-error / exit-loop / don't-increment); **auto-reset** at packet
start and optionally at encapsulation; counters double as **array indices** for
metadata stores (offset = base + counter×element-size).

**Our docs** have none. Loop/option/padding bounds in the patent are largely
counter-driven, so this ties into §3/§4.

**Action → Phase 1 (add counter instrs + registers).**

---

## 7. Instruction set — per-class conformance (🟠 partial)

Patent instruction families (agent-verified against L928–3345). ✅ = in our docs,
🟠 = partially, ❌ = missing.

- **Move / coprocessor** (custom-3 `0x7b`): `prs.mv`, `mv.x.p`, `mv.p.x`;
  `CPPRSRD/WR/WRIMM`, `CPPRSWRCAM/RDCAM/RDARRAY/WRARRAY` (program CAM/array from
  integer side). 🟠 (we mention move; miss CAM/array programming instrs)
- **Load** `PLOAD` + attributes **X**(hdr/data), **Sz**(1/2/4/**8**), **E**(endian
  swap), **Shift**, **Blen**(mask high bits); load-sets-length. 🟠 (we miss
  endian/shift/mask/X and the 8-byte `Sz==0` case)
- **Loop heads:** `PLOADTLVLOOP`, `PFLAGSLOOP(.rev)`, `PTLVFASTLOOP`, `PLOOP`. ❌
  (we only had a generic `prs.loop`)
- **Length:** `PLENCUR/PLENDATA/PLENDATABND/PLENDATATLV/PLENDATAPAD/PLENDATATLVEOL`
  with `lenset{,add,min}`, `tlv*`, `pad*`, `eol*` families; D-bit min-length;
  `Shift==7` = constant-length check. 🟠 (we had only `lensetmin`)
- **Store:** `PSTORE/PSTOREREG/PSTOREIMM`, F-bit frame/common, counter array index,
  E-bit swap. 🟠 (we had a generic store)
- **16-bit/next:** `PNEXTNODE(.ov)`, `PSETIMM`, `PSETCODE`, `PSTP`, `PVARINT`
  (protobuf varint, zigzag), `PANDMASK`. ❌ mostly (we had `.stp` only)
- **Extract/loop:** `PEXTRACT` (arbitrary bit-field), `PLOOP`. ❌
- **Counters:** `PINCCNTR/PSETCNTRBIT/PRESETCNTR`. ❌
- **CAM:** `PCAM/PCAMNEXT/PCAMJUMP/PCAMJUMPLOOP/PCAMJUMPTLVLOOP` + miss actions
  (`.wild/.alt/.stop/.stopsub/.fail/.failsub`) + share/PC-derived selector. 🟠
- **Array:** `PARR/PARRNEXT/PARRJUMP/PARRJUMPLOOP` (twins of CAM). ❌
- **Compare:** `PCMPIH/PCMPIB/PCMPINEB/PCMPILTB/LEB/GTB/GTEB` — eq/ne/lt/le/gt/ge,
  mask, on-false actions (stop/stopnode/stopsub/fail/cmpfail→handler). 🟠 (we had
  `cmpi.fail` only)
- **Lifecycle:** `PINITPARSER`, `PRUNTHREAD(.nokill)`, `PEVENTLOOP/END`. 🟠 (we
  deferred runthread; miss init/event-loop)
- **Data extraction:** `PDATAEXTRACT` + pseudo-instructions
  (`PSEUDOMOVE/NIBBMOVE/STOREI16/STOREI8`) — fused multi-byte header→metadata copy.
  ❌

**Action → Phase 1:** expand the instruction table to the full families above (at
minimum everything the vertical slice needs: load, len (+tlv), store, cam(+jump/
loop/tlvloop), tlvfastloop, flagsloop, cmp, inc.cntr, runthread, initparser). Mark
protobuf/varint/data-extract as later-phase.

---

## 8. Encoding & formats (🔴 divergent)

Our Phase 3 partitions `custom-0..3` **by instruction class** and guesses funct3.
The patent is specific (L1099–1105, L1169–1321, L1815–1817):

- **32-bit** parser instructions: RISC-V **custom-0 primary opcode `0x0b`** + a
  **4-bit function field** selecting the instruction (not a class-per-opcode split).
  A **64-bit** variant uses the >32-bit opcode space (companion doc).
- **Coprocessor move/CAM/array-programming** instructions: **custom-3 `0x7b`**,
  `cpreg/CoP = 0` = parser coprocessor.
- **Addressing:** CAM targets = **24-bit instruction-relative** (`ParserInstrBase |
  4*addr`); `PNEXTNODE` = **16-bit PC-relative** (`PC+(addr<<2)`); bit31 selects
  address (0) vs parser-code (1).
- **`Sz` meaning is instruction-class-dependent** (general 0=nibble/1=byte/2=half/
  3=word; **load/store** 0=**8 bytes**/1=byte/2=half/3=word; length has its own map)
  (L1214–1224, L2456).
- **Next-register control bits:** E(encap 0x40000000)/V(overlay 0x20000000)/NE/NV
  (L1281–1297).
- Targets 4-byte aligned (32-bit) / 8-byte aligned (64-bit).

**Action → Phase 3:** rewrite around custom-0 `0x0b` + 4-bit function + custom-3
moves; encode the address/code and control-bit scheme; capture the class-dependent
`Sz` tables. Keep the machine-readable table idea but seed it from the patent's
fields. **Caveat:** the exact per-field bit positions live in patent *figures* that
did not survive text extraction (see §10) — flag those as "from figures, TBD from
PDF".

---

## 9. Status / exit codes (🟠 partial)

Patent (L1807–1825, L1513–1525): status is a **negative byte parser code** (−1..
−127; high bit set = code); `STOP_FAIL(−12)` splits **normal** (> −12) from
**abnormal** exits; `ParserExitCode` holds `Error(16)+Address(24)`. Named codes in
text: `OKAY_RET`, `STOP_OKAY`, `STOP_NODE_OKAY`, `STOP_SUB_NODE_OKAY`,
`STOP_LENGTH`, `STOP_TLV_LENGTH`, `STOP_LOOP_CNT`, `STOP_OPTION_LIMIT`,
`STOP_PADDING_LIMIT`.

**Our docs** use a generic status enum. **Action → Phase 1/2:** adopt the parser-
code scheme and the named codes; the golden model's status output must use them so
Phase-6 co-sim compares real codes.

---

## 10. What the patent text does *not* pin down

**Update after inspecting the PDF:** the Google-Patents PDF is the HTML print
export and contains **no drawing images** (`pdfimages` finds exactly one 73×69 logo
in all 49 pages), so the figures cannot be read from our copy. However, most of
what the figures would show **survived as prose / inline C-structs** and is now
crystallized in **[patent-encodings-recovered.md](patent-encodings-recovered.md)**:
the register struct layouts (L1343–1762), the **`Sz` tables** (L1214–1224), the
**address/code encoding** and **E/V/NE/NV control bits** (L1280–1321), the **CAM key
union + PC-derived selector** (L1252–1278), and instruction framing (custom-0 `0x0b`
+ 4-bit function; custom-3 moves).

**Genuinely still missing (needs official USPTO drawing sheets):** the exact **bit
positions of fields within each 32-bit instruction word**, and the **"Parser Codes"
master value table** (numeric value per `STOP_*` code). These stay **TBD-from-
figure**. To recover them, fetch the official patent drawing sheets (the
`patentimages` PDF, not the HTML export) or cross-reference the XDP2 sources.

---

## 11. Prioritized action list

| # | Change | Doc(s) | Priority |
|---|--------|--------|----------|
| 1 | Replace 6-register table with the patent register file (operational + slice-relevant config/target regs); adopt `CurHdr`/`DataHdr` + `pcurptr`/`pdatptr` | Phase 1, Phase 4 | **P0** |
| 2 | Add the two-level parsing model + `DataBound` lifecycle | Phase 1, Phase 2, Phase 4 | **P0** |
| 3 | Rewrite end-of-node: Loop-then-Next, data-vs-current advance, overlay, encapsulation, address-or-code | Phase 1, Phase 4, Phase 5 | **P0** |
| 4 | Expand the instruction set to the full families (§7); keep varint/data-extract as later-phase | Phase 1 | **P0** |
| 5 | Re-base encoding on custom-0 `0x0b` + 4-bit function + custom-3 moves; control bits; class-dependent `Sz`; mark bit positions TBD-from-figure | Phase 3 | **P1** |
| 6 | Add counters, encapsulation levels, metadata-frame model | Phase 1, Phase 4 | **P1** |
| 7 | Adopt the negative-byte parser-code status scheme + named codes | Phase 1, Phase 2 | **P1** |
| 8 | Add load attributes (endian/shift/mask/X) and compare variants + on-false actions | Phase 1 | **P1** |
| 9 | Update Risk R2 (context state is large: 32 regs) and the overview's "Herbert-style ISA" line to reflect full-ISA scope | Overview | **P2** |
| 10 | Read the patent **PDF figures** to recover exact bit fields; reconcile with XDP2 | Phase 3, references | **P2** |

**Recommended sequencing:** apply P0 to Phase 1/2/4 first (they define semantics and
the golden model), then P1 encoding/counters/codes, then P2. None of this changes
the project's *architecture* (ADR-001 stands) — it deepens the ISA content to match
Herbert's design.

## 12. Provenance

Derived from a full read of the patent claims (L57–217) plus two structured
extractions of the detailed description (instruction set L928–3345; register/control
model L1315–1825, L3505–3826). Ligature artifacts (`�` = `fi`/`fl`) were resolved
throughout. Exact bit-level encodings pending the PDF figures (§10).
