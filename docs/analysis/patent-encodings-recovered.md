# Recovered encodings from the patent text

← [Conformance analysis](patent-conformance.md) · [Docs index](../README.md)

The patent's **figure images did not survive** the Google-Patents HTML→PDF export
(`pdfimages` finds exactly one 73×69 logo in the whole file). However, the register
**struct layouts**, the **`Sz` tables**, the **address/code encoding**, the **CAM
key structure**, and the **control bits** all survived as prose/inline C-structs.
This note crystallizes those, with line cites into
[`../references/patent-us12461885.txt`](../references/patent-us12461885.txt), so the
phase docs have one authoritative source.

> **Still genuinely missing (needs official USPTO drawing sheets):** the exact
> **bit positions of fields *within* each 32-bit instruction word** (FIG. of each
> instruction format), and the **"Parser Codes" master value table** (the numeric
> value of each `STOP_*` code). These remain **TBD-from-figure**.

## 1. Instruction framing & alignment (L1099–1105, L1159–1174, L1815–1817)

- **32-bit** parser instructions: RISC-V **custom-0 primary opcode `0x0b`** + a
  **4-bit function field** selecting the instruction. 4-byte aligned targets.
- **64-bit** variant: uses the >32-bit opcode space; 8-byte aligned. 32- and 64-bit
  forms may branch to / fall through each other if aligned.
- **Coprocessor** move / CAM-array-programming instructions: **custom-3 `0x7b`**,
  `CoP = 0` = parser coprocessor.
- Addresses are 64-bit. Two relative forms:
  - **CAM / instruction-relative:** 24-bit → `ParserInstrBase | (4 * addr)` (L1169).
  - **PC-relative (`PNEXTNODE`):** 16-bit → `PC + (addr << 2)` (L1172–1174).

## 2. Address-or-code encoding (L1317–1321, L1280–1300)

A 32-bit value in `Next`/`Loop`/CAM-target/array-target encodes **either** an
address **or** a parser code, selected by **bit 31**:

```
 bit31 = 0  → 24-bit relative address in bits[23:0]; control bits in [30:24]
 bit31 = 1  → parser code (negative −1..−128; sign-extends to 16/32/64-bit)
```

**Control bits (address form, bits 24–30)** (L1281–1293):

| Bit | Name | Meaning |
|-----|------|---------|
| E  | encapsulation | on transition to next node, increment encapsulation level |
| V  | overlay | on transition, **do not** change pointers/offsets (overlay node) |
| NE | next-encapsulation | next→its-next transition increments encap level |
| NV | next-overlay | next→its-next transition is overlay |

Masks seen in text: encapsulation `0x40000000`, overlay `0x20000000`. When a **code**
is returned into `ParserExitCode.Error`, control bits are filled with 1s so the
value reads as a negative byte −1..−127 (L1297–1300).

## 3. `Sz` field (two meanings) (L1214–1224)

- **General sub-register instructions:** `Sz` = 0 nibble / 1 byte / 2 half / 3 word;
  bit-width = `4 * (1 << Sz)`.
- **Load / store instructions:** `Sz` = 1 byte / 2 half / 3 word / **0 = double word
  (8 bytes)**.

**Sub-register position** (L1226–1229): counted from the first byte in memory =
position 0 (low-order byte, little-endian). Nibble 0 = **high** 4 bits of the first
byte; nibble 1 = low 4 bits.

## 4. CAM key structure (L1252–1278)

CAM entry = **20-bit key + 32-bit target**. Key is a union selected by the 4 high
bits (`Shared`):

```c
union {
  struct { Match:16; Shared:4 /* non-zero */ } Shared;      // 1..15 shared tables, up to 16-bit match
  struct { Match:8; Selector:8; Shared:4 /* zero */ } NonShared;  // 8-bit match
}
```

- **Shared ≠ 0:** one of 15 shared tables; match up to 16 bits (EtherType, etc.).
- **Shared == 0:** non-shared table; 8-bit `Selector` **derived from the PC** of the
  CAM instruction: `Selector = (PC << 6) & 0xFF00`. Two non-shared tables must not
  collide in that PC-derived selector (mitigate with NOPs) (L1274–1278).
- **Array lookup** (L1302–1313): 32-bit entries; sub-arrays identified by a base
  index + count; no "miss" (all indices must be set); default entry =
  `PANDA_STOP_OKAY`.

## 5. Parser register file — recovered struct layouts

64-bit `p` registers; logical name (ABI name, p#). Structs are verbatim field
widths from the text.

| Reg (ABI, p#) | Layout / meaning | Cite |
|---------------|------------------|------|
| `ObjectRef` (pobjref, p0) | 64-bit opaque PDU reference | L1323 |
| `CurHdr` (pcurhdr, p1) | `Offset` + `Length` of current **protocol** header | L1326–1330 |
| `DataHdr` (pdathdr, p2) | `Offset` + `Length` of current **data** header (e.g. a TLV) | L1332–1337 |
| `PktLen` (ppktlen, p3) | `AllLen:32, ParseLen:16, Rsvd:7, F:1, P:1` | L1343–1351 |
| `FrameOffFnumSeqno` (pfofnsq, p4) | `FrameOffset` (÷4), `FuncNum`, `Seqno` | L1353–1364 |
| `PktInfo` (ppktinf, p5) | `PktCtx:16, Checksum:16, NextWorkItem:16, IFID:8, L:1, N:1, D:1, Rsvd:5` | L1388–1395 |
| `NodeLoopCnt` (pndlcnt, p6) | `NumLoops:16, NonPadCnt:8, PadLen:8, ConPad:8, NodeCnt:8` | L1425–1430 |
| `Counters` (pcount, p7) | `Encap:8, Cntr1..Cntr7:8` | L1445–1454 |
| `PktHdrBase` (phdrbas, p8) | 64-bit base of packet headers | L1463 |
| `MetadataBase` (pmdbase, p9) | base of common metadata + frame array | L1466–1470 |
| `ParserInstrBase` (pinbase, p10) | 64-bit base of parser code | — |
| `Next` (pnext, p11) | address/code (§2) = next node | L1483 |
| `PendingWork` (ppendwk, p12) | pending work-item index (0xFFFF none) | L1491 |
| `DataBndLoop` (pdbndlp, p13) | `DataBound` (init ∞ `0xFFFFFFFF`) + `Loop` (address/code; default `OKAY_RET`) | L1496–1512 |
| `ParserExitCode` (pexcode, p14) | `Address:24, Rsvd:24, Error:16` | L1519–1525 |
| `Accum` (paccum, p15) | accumulator | L1527 |
| `Flags` (pflags, p16) | flag-loop register / 2nd accumulator | L1531–1533 |

**Pseudo-registers** (assembly operands, not real regs): `pcurptr = PktHdrBase +
CurHdr.Offset`; `pdatptr = PktHdrBase + DataHdr.Offset` (L943, L1900).

### Configuration registers

- `ParserConfig` (pconfig, p17): `MaxNodes:16, MaxEncap:8, MaxFrames:8, FrameSize:8,
  FrameOffset:8, EE:1, EO:1, NumPfuncs:6, PrsBuff:8`. `RealFrameSize =
  4*(FrameSize+1)`; buffer size `=(PrsBuff+1)*64`. (L1540–1563)
- `CounterLimitsConfig` (pcntlim): `Rsvd:1, E1..E7:1, Cntr1..7:8` (per-counter max +
  error-on-exceed). (L1578–1592)
- `CounterArrayConfig` (pctarcf): `Rsvd:1, O1..O7:1, Cntr1..7:8` (max array index +
  overwrite-last). (L1598–1612)
- `CouterArraySzResEncConfig` (pctarsz): `Rsvd:1, R1..R7:1, Cntr1..7:8` (element
  size −1, range 1..256 + reset-on-encapsulation). (L1624–1642)
- `LoopSpec` (ploopsp): `MaxCnt:16, MaxNon:16, MaxPlen:8, MaxCPad:8, Disp:2, E:1,
  Rsvd:13`. (L1648–1663)
- `TLVSpec` (ptlvsp): `IgnVal:8, IgnMask:8, PAD1:8, PADN:8, EOL:8, Disp:2, P:1, N:1,
  E:1, Rsvd:19`. (L1681–1691)

### Target / exception registers (address holders)

`OkayTarget` (pokay), `FailTarget` (pfail), `Wildcard`, `AltWildcard`, `AtEncap`,
`PostLoop`, `CompareFalse`, `DataExtractBase` (p30), `Timestamp` (L1711–1762).

## 6. Metadata layout (L1466–1470, L1180–1183, L1249)

`MetadataBase` → **common metadata** (whole-object) followed by an **array of
metadata frames**. Current frame pointer = `MetadataBase + 4*FrameOffFnumSeqno.
FrameOffset`. Stores select common-vs-frame via the instruction `F`-bit. Block size
`= ((4*FrameOffset + 4*(FrameSize+1) + 63)/64)*64`.

## 7. `DataBound` fully-qualified loop address (L1508–1512)

```
if (!IS_RET_CODE(DataBndLoop.Loop))
    TempAddress = ParserInstrBase | (DataBndLoop.Loop & 0xFFFFFF)
```

`IS_RET_CODE(X) = (X < 0)`; `IS_NOT_OK_CODE(X) = (X ≤ STOP_FAIL)`; `IS_OK_CODE(X) =
IS_RET_CODE(X) && X > STOP_FAIL`. `STOP_FAIL = −12` splits normal (>−12) from
abnormal (≤−12) exits (L1813, L1823–1825).
