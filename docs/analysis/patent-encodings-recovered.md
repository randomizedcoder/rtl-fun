# Patent encodings — bit-accurate reference

← [Conformance analysis](patent-conformance.md) · [Docs index](../README.md)

Bit-accurate encodings for US Patent 12,461,885, extracted from the **official
USPTO drawing sheets** ([`../references/uspto-patent-us12461885.pdf`](../references/uspto-patent-us12461885.pdf),
150 pages / 108 sheets) plus the register struct layouts from the text
([`../references/patent-us12461885.txt`](../references/patent-us12461885.txt)). All
instruction bit ranges are **pixel-verified** from the figure rulers.

> **Numbering convention:** the patent draws **bit 31/63 on the left → bit 0 on the
> right** (little-endian bit order), *not* the IETF bit-0-left order. The ASCII
> diagrams below preserve the **patent's** numbering so they match the drawings.
>
> **Page↔figure map:** `PDF page = FIG + 3` through FIG 44; FIG 47 is multi-sheet
> (pp. 50–54), shifting later figures. Key sources: **FIG 45** (p. 48) Parser Codes,
> **FIG 46** (p. 49) Func4 map, **FIG 47** (pp. 50–54) all instruction formats.

## 1. Instruction framing

- **32-bit** parser instructions: RISC-V **custom-0 opcode `[6:0] = 0b0001011`
  (0x0B)** + **`Fnc4 = [10:7]`** selecting the instruction group. 4-byte aligned.
- **64-bit** variant: >32-bit opcode space, 8-byte aligned (companion; we do 32-bit).
- **Coprocessor** moves + CAM/array programming: **custom-3 `0x7b`** (formats in
  FIG 43/44, §2.2 below — full coverage).

### 1.1 `Fnc4` opcode map (FIG 46, p. 49)

| Fnc4 | Instructions | Fnc4 | Instructions |
|-----:|--------------|-----:|--------------|
| `0000` | PLOAD, PLOADTLVLOOP, PTLVFASTLOOP | `1000` | PCAM, PCAMNEXT, PCAMJUMP, PCAMJUMPLOOP, PCAMJUMPTLVLOOP |
| `0001` | PFLAGSLOOP | `1001` | PARR, PARRNEXT, PARRJUMP, PARRJUMPLOOP |
| `0010` | PLENCUR, PLENDATA, PLENDATABND | `1010` | PNEXTNODE, PSETIMM, PSETCODE, PSTP, PVARINT, PANDMASK |
| `0011` | PLENDATATLV, PLENDATAPAD, PLENDATAEOL | `1011` | PCMPILTB, PCMPILTEB, PCMPIGTB, PCMPIGTEB |
| `0100` | PSTORE | `1100` | PCMPIH |
| `0101` | PSTOREREG | `1101` | PCMPIB |
| `0110` | PSTOREIMM | `1110` | PCMPNEIB |
| `0111` | PEXTRACT, PLOOP, PINCCNTR, PSETCNTRBIT, PRESETCNTR | `1111` | PRUNTHREAD, PINITPARSER, PEVENTLOOP, PEVENTLOOPEND, PDATAEXTRACT |

### 1.2 `Sz` field (FIG 17, p. 20)

| Sz | Size | Asm | Pos range | | Sz | Size | Asm | Pos range |
|---:|------|-----|-----------|-|---:|------|-----|-----------|
| 0 | nibble (4b) | `.n` | 0–15 | | 2 | half (16b) | `.h` | 0–3 |
| 1 | byte (8b) | `.b` | 0–7 | | 3 | word (32b) | `.w` | 0–1 |

**Load/store only:** `Sz` 1=byte, 2=half, 3=word, **0 = double word (8 bytes)**.
Sub-register position 0 = first byte (big-endian nibble 0 = high 4 bits).

## 2. 32-bit instruction formats (FIG 47)

Within each group, a discriminator field selects the specific instruction (tables
follow each diagram). All share `Fnc4=[10:7]`, `Opcode=[6:0]=0x0b`.

```
PLOAD / PLOADTLVLOOP  (Fnc4=0000)      PLOAD: D=0, X=src ; PLOADTLVLOOP: X=0,D=1
3 3 2   2       2     2 1                 1
1 0 9   7       3     0 9                 0       6           0
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|X|D|Sz | Blen| |Shift|E| | | Offset| | | | Fnc4| | | Opcode| | |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

PTLVFASTLOOP  (Fnc4=0000, X=1, D=1)
3 3 2           2     2   1               1
1 0 9           3     0   8               0       6           0
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|X|D| | Rsvd| | |Shift|F2 | | | |Len| | | | Fnc4| | | Opcode| | |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

PFLAGSLOOP  (Fnc4=0001)                R=[27] reverses flag bit order (.rev)
3   2   2 2                               1
1   9   7 6                               0       6           0
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|Pos|Sz |R| | | | | | | Mask| | | | | | | | Fnc4| | | Opcode| | |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

Length group  (Fnc4=0010 cur/data/bnd, 0011 tlv/pad/eol)
3 3 2   2       2     2   1               1
1 0 9   7       3     0   8               0       6           0
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|S|D|Sz | |Pos| |Shift|F2 | | | |Len| | | | Fnc4| | | Opcode| | |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

PSTORE  (Fnc4=0100)                    J=[23] src Accum(0)/Flags(1)
3 3 2   2       2 2     1                 1
1 0 9   7       3 2     9                 0       6           0
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|S|F|Sz | |Pos| |J|Sind | | | Offset| | | | Fnc4| | | Opcode| | |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

PSTOREREG  (Fnc4=0101)                 PSTOREIMM  (Fnc4=0110)
3 3 2   2         2     1     1         3 3 2   2               1     1
1 0 9   7         2     9     0         1 0 9   7               9     0
+-...(Reg[27:23],Pos[22:20])...-+      +-...(Value[27:20])...-+
|S|F|Sz | | Reg | | Pos |Offset|Fnc4|Op |S|F|Sz | | Value |Offset|Fnc4|Op

CAM group  (Fnc4=1000)                 Array group  (Fnc4=1001): Base[19:11] replaces Share+Miss
3 3 2   2       2     2 1       1         1
1 0 9   7       3     0 9       5         0       6           0
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|S|D|Sz | |Pos| |Func3|F| Share | |Miss | | Fnc4| | | Opcode| | |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

Next/set group  (Fnc4=1010)            A=[27]: PANDMASK=1 else 0
3 3 2   2 2                               1
1 0 9   7 6                               0       6           0
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|S|V|Pos|A| | | | | | |Payload| | | | | | | Fnc4| | | Opcode| | |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

PEXTRACT / PLOOP  (Fnc4=0111, Fun=00/01)
3 3 2   2         2           1           1
1 0 9   7         2           6           0       6           0
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|S|V|Fun| |Preg | | |BitPos | | BitLength | Fnc4| | | Opcode| | |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

Counters PINCCNTR/PSETCNTRBIT/PRESETCNTR  (Fnc4=0111, Fun=10/11)
3 3 2   2         2   2 1     1           1
1 0 9   7         2   0 9     6           0       6           0
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|S|V|Fun| |Cntr | |Val|F|Bnum | | Rsvd| | | Fnc4| | | Opcode| | |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

PCMP* byte-compare LTB/LTEB/GTB/GTEB  (Fnc4=1011, Func3 selects op)
3 3 2   2       2     2   1               1
1 0 9   7       3     0   8               0       6           0
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|S|D|Sz | |Pos| |Func3|Er | | | Value | | | Fnc4| | | Opcode| | |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

PCMPIH (Fnc4=1100)                     PCMPIB/PCMPNEIB (Fnc4=1101/1110)
3   2   2 2               1             3   2     2               1
1   9   7 6               0             1   9     6               8
+..(N[27],Value[26:11])..+             +..(Pos[29:27],Value[26:19],Mask[18:11])..+
|Er |Pos|N| Value |Fnc4|Op             |Er | Pos | Value | Mask |Fnc4|Op

PRUNTHREAD (Fnc4=1111,F2=00)  |  PINITPARSER/PEVENTLOOP*(F2=01/10)  |  PDATAEXTRACT(F2=11)
|S|D|F2|N| FuncNum |Fnc4|Op   |  |Rv |F2 | Rsvd |Fnc4|Op            |  |S|D|F2|InsIndex|InsNum|Fnc4|Op
```

### 2.1 Per-group discriminators

| Group (Fnc4) | Field | Values |
|--------------|-------|--------|
| Length `0010` | `D`,`F2[20:19]` | PLENCUR (F2=00), PLENDATA (01), PLENDATABND (10, D=0) |
| Length `0011` | `F2` | PLENDATATLV (00), PLENDATAPAD (01), PLENDATAEOL (10) |
| CAM `1000` | `D`,`Func3[23:21]` | PCAM (000), PCAMNEXT (D=1,000), PCAMJUMP (001), PCAMJUMPLOOP (010), PCAMJUMPTLVLOOP (011) |
| Array `1001` | `D`,`Func3` | PARR (000), PARRNEXT (D=1), PARRJUMP (001), PARRJUMPLOOP (010) |
| Next `1010` | `Pos[29:28]`,`A[27]` | PNEXTNODE (00), PSETIMM (01), PSETCODE (10,V=0), PSTP (10), PVARINT (11), PANDMASK (A=1) |
| Extract/loop `0111` | `Fun[29:28]` | PEXTRACT (00), PLOOP (01), PINCCNTR (10), PRESETCNTR (11); PSETCNTRBIT (10,V=1) |
| Compare `1011` | `Func3[23:21]` | PCMPILTB (000), PCMPILTEB (001), PCMPIGTB (010), PCMPIGTEB (011) |
| Lifecycle `1111` | `F2[29:28]` | PRUNTHREAD (00), PINITPARSER (01), PEVENTLOOP (10,Rv=00), PEVENTLOOPEND (10,Rv=01), PDATAEXTRACT (11) |

### 2.2 Custom-3 coprocessor formats (FIG 43/44)

Standard RISC-V R-form on `Opcode[6:0]=0x7b` with `CoP=[31:29]=000` (parser
coprocessor), `Cpreg=[28:24]` (which `p` register), control bits `C/D[23] S[22]
I[21] R[20]`, `Rs=[19:15]`, `Func3=[14:12]`, `Rd=[11:7]`.

```
Coprocessor R-form (custom-3)          CPPRSWRIMM (I=1): imm11 = Imm1 + (Imm2<<5)
3     2         2 2 2 2 1         1     3     2         2 2 2 2           1
1     8         3 2 1 0 9         4     1     8         3 2 1 0           4
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| CoP | Cpreg |C|S|I|R| Rs  |Func3|Rd…  | CoP | Cpreg |C|S|I| Imm2  |Func3|Imm1…
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
(full ASCII diagrams: run tools/bitgen/bitgen.py)
```

Discriminators & assembly (FIG 43/44):

| Instr | S | I | R | Func3 | D-bit | assembly |
|-------|---|---|---|-------|-------|----------|
| CPPRSRD | 0 | 0 | 0 | 000 | — | `prs.mv.x.p ireg,preg` (read p→int) |
| CPPRSWR | 0 | 0 | 0 | 001 | — | `prs.mv.p.x preg,ireg` (write int→p) |
| CPPRSWRIMM | 0 | 1 | — | 001 | — | `prs.ld.immed preg,imm` (11-bit imm) |
| CPPRSRDCAM | 0 | 0 | 1 | 000 | — | `prs.cam.read ireg,ireg` |
| CPPRSWRCAM | 0 | 0 | 1 | 001 | `[23]=D` | `prs.cam.write ireg,preg` (D=0) / `prs.cam.delete ireg` (D=1) |
| CPPRSRDARRAY | 1 | 0 | 1 | 000 | — | `prs.array.read ireg,ireg` |
| CPPRSWRARRAY | 1 | 0 | 1 | 001 | `[23]=D` | `prs.array.write ireg,preg` (D=0) / `prs.array.delete ireg` (D=1) |

(For write/CAM/array ops `Rd=[11:7]=00000`; for reads `Cpreg=00000` and `Rs` holds
the key/index.)

## 3. Next-node address / code word & CAM key

```
Next-node ADDRESS word (bit31=0)                 Next-node CODE word (bit31=1)
3 3 2 2 2 2     2                                 3 3 2 2 2 2     2
1 0 9 8 7 6     3                             0   1 0 9 8 7 6     3               7             0
+-+-+-+-+-+-+-+-+ ... +                           +-+-+-+-+-+-+-+-+ ... +
|0|E|V|N|N| |0| Address (24-bit rel) |            |1|E|V|N|N| |0| ones (all 1s) | Code (8b) |
+-+-+-+-+-+-+-+-+ ... +                           +-+-+-+-+-+-+-+-+ ... +
   NE^ NV^                                           NE^ NV^
Address = ParserInstrBase | (4*Address).  Control bits: E encap(0x40000000), V overlay(0x20000000), NE/NV next-.
```
```
CAM key — shared form (Shared!=0)      CAM key — selector form (Shared==0)
1       1                              1       1
9       5                     0        9       5               7             0
+-+-...-+-+ ... +-+                     +-+-...-+-+ ... +-+ ... +-+
|Shared | Match (up to 16b) |          | 0000  | Selector | Match (8b) |
+-+-...-+-+ ... +-+                     +-+-...-+-+ ... +-+ ... +-+
                                       Selector = (PC<<6)&0xFF00
```

## 4. Parser Codes (FIG 45, p. 48)

Negative-byte codes; `STOP_FAIL(−13)` splits normal (>−13) from abnormal (≤−13).
Stored sign-extended in `ParserExitCode.Error`.

| Code | val | 8-bit | Code | val | 8-bit | Code | val | 8-bit |
|------|----:|-------|------|----:|-------|------|----:|-------|
| OKAY | 0 | — | STOP_UNKNOWN_PROTO | −15 | 0xF1 | STOP_FAIL_CMP | −20 | 0xEC |
| OKAY_RET | −1 | 0xFF | STOP_ENCAP_DEPTH | −16 | 0xF0 | STOP_LOOP_CNT | −21 | 0xEB |
| OKAY_USE_WILD | −2 | 0xFE | STOP_UNKNOWN_TLV | −17 | 0xEF | STOP_PADDING_LIMIT | −22 | 0xEA |
| OKAY_USE_ALT_WILD | −3 | 0xFD | STOP_TLV_LENGTH | −18 | 0xEE | STOP_OPTION_LIMIT | −23 | 0xE9 |
| STOP_OKAY | −4 | 0xFC | STOP_BAD_FLAG | −19 | 0xED | STOP_MAX_NODES | −24 | 0xE8 |
| STOP_NODE_OKAY | −5 | — | STOP_LENGTH | −14 | 0xF2 | STOP_COMPARE | −25 | 0xE7 |
| STOP_SUB_NODE_OKAY | −6 | — | STOP_FAIL | −13 | 0xF3 | STOP_CNTR1..7 | −26..−32 | 0xE6..0xE0 |

*(The figure prints STOP_NODE_OKAY / STOP_SUB_NODE_OKAY 8-bit as 0xFD/0xFE,
colliding with OKAY_USE_ALT_WILD/OKAY_USE_WILD — reproduced as-drawn.)*

## 5. Parser registers (64-bit)

```
CurHdr (p1) / DataHdr (p2)
 63                             32 31                              0
+---------------------------------+---------------------------------+
|             Offset              |             Length              |
+---------------------------------+---------------------------------+

Counters (p7)
 63     56 55     48 47     40 39     32 31     24 23     16 15      8 7       0
+---------+---------+---------+---------+---------+---------+---------+---------+
|  Cntr7  |  Cntr6  |  Cntr5  |  Cntr4  |  Cntr3  |  Cntr2  |  Cntr1  |  Encap  |
+---------+---------+---------+---------+---------+---------+---------+---------+

CounterLimitsConfig
 63     56 55     48 47     40 39     32 31     24 23     16 15      8 7 6 5 4 3 2 1 0
+---------+---------+---------+---------+---------+---------+---------+-+-+-+-+-+-+-+-+
|  Cntr7  |  Cntr6  |  Cntr5  |  Cntr4  |  Cntr3  |  Cntr2  |  Cntr1  |E7 …      E1|R|
+---------+---------+---------+---------+---------+---------+---------+-+-+-+-+-+-+-+-+

ParserExitCode (p14)              TLVSpec (FIG 41)
 63           48 47   24 23     0   [45]E [44]N [43]P [42:40]Disp [39:32]EOL
+---------------+-------+---------+  [31:24]PADN [23:16]PAD1 [15:8]IgnMask [7:0]IgnVal
|  Error (code) | Rsvd  | Address |
+---------------+-------+---------+
```

Remaining register struct layouts (field widths from the text, LSB-first C-bitfield
order): `PktLen{AllLen:32,ParseLen:16,Rsvd:7,F:1,P:1}`, `NodeLoopCnt{NumLoops:16,
NonPadCnt:8,PadLen:8,ConPad:8,NodeCnt:8}`, `DataBndLoop{DataBound + Loop}` (both
address/code-encoded), `ParserConfig{MaxNodes:16,MaxEncap:8,MaxFrames:8,FrameSize:8,
FrameOffset:8,EE:1,EO:1,NumPfuncs:6,PrsBuff:8}`, `LoopSpec{MaxCnt:16,MaxNon:16,
MaxPlen:8,MaxCPad:8,Disp:2,E:1}`. See the [conformance analysis](patent-conformance.md)
§2 and the patent text for cites.

### 5.1 Register map p0–p31 + initialization (FIG 42)

| p# | Reg | Init | p# | Reg | Init |
|---:|-----|------|---:|-----|------|
| p0 | ObjectRef | from work item | p16 | Flags | — |
| p1 | CurHdr | 0 | p17 | ParserConfig | one-time |
| p2 | DataHdr | 0 | p18 | CounterLimitsConfig | one-time |
| p3 | PktLen | AllLen from msg; ParseLen=min(pktlen,(PrsBuff+1)·64); F,P=1 | p19 | CounterArrayConfig | one-time |
| p4 | FrameOffFnumSeqno | Seqno set; FrameOff=0 | p20 | CounterArraySzResEncConfig | one-time |
| p5 | PktInfo | PktCtx, Checksum | p21 | LoopSpec | per use |
| p6 | NodeLoopCnt | 0 | p22 | TLVSpec | per use |
| p7 | Counters | 0 | p23 | OkayTarget | one-time |
| p8 | PktHdrBase | from pkt ctx | p24 | FinalTarget *(a.k.a. FailTarget)* | one-time |
| p9 | MetadataBase | from pkt ctx | p25 | Wildcard | per CAM |
| p10 | ParserInstrBase | 0xFFFF | p26 | AltWildcard | per CAM |
| p11 | Next | STOP_OKAY | p27 | AtEncap | one-time |
| p12 | PendingWork | 0xFFFF | p28 | PostLoop | per loop |
| p13 | DataBndLoop | DataBound=0xFFFFFFFF, Loop=OKAY_RET | p29 | CompareFalse *(fig: "CompFlase")* | per compare |
| p14 | ParserExitCode | — | p30 | DataExtractBase | one-time |
| p15 | Accum | — | p31 | Timestamp | from work item |

## 6. Provenance — 100% coverage

All encodings are pixel-verified from the USPTO drawing sheets: instruction formats
+ Parser Codes + `Fnc4` map (FIG 45/46/47), the **custom-3 coprocessor** formats
(FIG 43/44), register layouts and the p0–p31 init table (FIG 42, 24, 27, 37, 41).
**No remaining gaps** — the parser ISA encoding is fully specified. The ASCII
diagrams here are generated by [`bitgen.py`](../../tools/bitgen/bitgen.py) from the
verified field tables (`python3 tools/bitgen/bitgen.py`, from the repo root).
