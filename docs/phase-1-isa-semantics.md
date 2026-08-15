# Phase 1 — ISA operational semantics (normative)

← [Phase 1 overview](phase-1-isa-spec.md) · [Docs index](README.md) · [Phase 2 »](phase-2-reference-model.md)

## 0. Purpose & status

This is the **normative, per-instruction operational specification** for the
vertical-slice parser ISA. Where [`phase-1-isa-spec.md`](phase-1-isa-spec.md) is
the human-readable overview (register file, families, rationale), *this* document
is the precise behavioural contract: one pseudocode routine per instruction, plus
the shared primitives they call, precise enough that
[Phase 2](phase-2-reference-model.md) can implement each `execute_*` function
directly from it and [Phase 6](phase-6-verification.md) can treat any RTL/model
divergence as a bug.

- **Authority:** US Patent 12,461,885 B2. Line cites `Lnnnn` refer to
  [`references/patent-us12461885.txt`](references/patent-us12461885.txt); the
  pseudocode below mirrors the patent's own embedded pseudocode, transcribed and
  de-ligatured, with bugfixes to obvious OCR typos noted inline.
- **Bit-accurate encodings** (fields, `Sz`/`Pos` tables, address/code words, parser
  codes) live in
  [`analysis/patent-encodings-recovered.md`](analysis/patent-encodings-recovered.md);
  this document is *semantics only* and does not restate bit positions.
- **Normative language:** MUST / MUST NOT / SHALL as in RFC 2119.
- **Layer rule:** no cycle counts, no pipeline behaviour, no "wait" latency here.
  The patent's `Wait_for_more_data()` (a streaming-buffer artifact) is modelled as
  the predicate in [§2.9](#29-streaming-model) — it changes *which bytes are
  available*, never a result value.

### 0.1 Slice instruction set (what this doc specifies)

The Phase-0 slice is Ethernet → VLAN(·stacked) → IPv4/IPv6(+ext-hdr TLV loop) →
TCP(+options)/UDP → `flow_keys`. That needs exactly these instructions; everything
else in the ISA ([overview §1.3](phase-1-isa-spec.md)) is **out of scope for the
slice** and specified in a later phase.

| Family | Instructions (this doc) | § |
|--------|-------------------------|---|
| Lifecycle | `PINITPARSER` | [4.1](#41-pinitparser) |
| Load | `PLOAD` | [4.2](#42-pload) |
| Length | `PLENCUR`, `PLENDATA`, `PLENDATATLV` | [4.3](#43-length-family) |
| Compare | `PCMPIB`, `PCMPINEB`, `PCMPI{LT,LE,GT,GE}B` | [4.4](#44-compare-family) |
| CAM | `PCAM`, `PCAMNEXT`, `PCAMJUMP`, `PCAMJUMPLOOP`, `PCAMJUMPTLVLOOP` | [4.5](#45-cam-family) |
| Loop heads | `PLOADTLVLOOP`, `PTLVFASTLOOP`, `PFLAGSLOOP` | [4.6](#46-loop-heads) |
| Store | `PSTORE`, `PSTOREIMM` | [4.7](#47-store-family) |
| Counters | `PINCCNTR` | [4.8](#48-counters) |
| Control | `PSTP`, `PNEXTNODE`, `PSETCODE` | [4.9](#49-control--next) |
| End-of-node | `Common_End_of_Node` (not an instruction; the `.stp`/loop epilogue) | [5](#5-common_end_of_node) |

Deferred to a later phase (present in the ISA, not in the slice): `PARR*`,
`PVARINT`, `PEXTRACT`, `PDATAEXTRACT`+pseudo-moves, `PSETCNTRBIT`/`PRESETCNTR`,
`PLENDATABND`/`PLENDATAPAD`/`PLENDATATLVEOL`, `PRUNTHREAD`/`PEVENTLOOP*` (single-
threaded model — see [4.10](#410-deferred-in-the-slice)).

### 0.2 Notation

- `reg.field` — a named sub-field of a 64-bit `p` register (layouts:
  [encodings §5](analysis/patent-encodings-recovered.md)). E.g. `CurHdr.Offset`,
  `PktLen.ParseLen`, `DataBndLoop.DataBound`, `NodeLoopCnt.NonPadCnt`.
- All arithmetic is unsigned on the field's width unless stated. **Length
  arithmetic in the length family is truncated to 9 bits** (patent L2272).
- `pcurptr`, `pdatptr` are **pseudo-registers** (computed, never stored) —
  [§1.2](#12-pseudo-registers).
- Parser codes are **negative** small integers ([§1.4](#14-parser-codes)); a value
  is "a code" iff `IS_RET_CODE(x) ≜ (x < 0)` (patent L1823).

---

## 1. Machine model

### 1.1 Architectural state

The full 32×64-bit register file is in
[overview §1.1](phase-1-isa-spec.md#11-parser-register-file) and
[encodings §5.1](analysis/patent-encodings-recovered.md#51-register-map-p0p31--initialization-fig-42).
The state the **slice** reads or writes — and therefore what the golden model's
`pstate` MUST carry — is:

| State | Reg (field) | Meaning |
|-------|-------------|---------|
| `pkthdrbase` | PktHdrBase (p8) | base address of the packet header buffer |
| `all_len` | PktLen.AllLen | length of the whole PDU (bytes) |
| `parse_len` | PktLen.ParseLen | bytes currently available in the parse buffer |
| `P` | PktLen.P | "all header bytes present" flag ([§2.9](#29-streaming-model)) |
| `cur.{off,len}` | CurHdr (p1) | offset+length of the current **protocol** header |
| `dat.{off,len}` | DataHdr (p2) | offset+length of the current **data** header (TLV) |
| `databound` | DataBndLoop.DataBound | bytes remaining for data elements ([§3](#3-databound-lifecycle)) |
| `loop` | DataBndLoop.Loop | loop continuation: address **or** code |
| `accum` | Accum (p15) | load target; length/compare/lookup source |
| `flags` | Flags (p16) | flag-field bitmap (2nd accumulator) |
| `next` | Next (p11) | next node: address **or** code, + control bits E/V/NE/NV |
| `encap` | Counters.Encap | encapsulation depth / metadata-frame index |
| `cntr[1..7]` | Counters.Cntr1..7 | user counters (loop/option bounds) |
| `nlc.*` | NodeLoopCnt (p6) | `NumLoops`, `NonPadCnt`, `PadLen`, `ConPad`, `NodeCnt` |
| `meta_common`, frame ptr | MetadataBase (p9), FrameOffFnumSeqno (p4) | store targets ([§2.7](#27-store-addressing)) |
| `code` | ParserExitCode.Error (p14) | exit status (parser code) |
| `pc` | — | index of the executing parser instruction (for CAM selector & jumps) |

Config/target registers the slice consults are read-only after init:
`ParserConfig` (MaxNodes, MaxEncap, FrameSize, FrameOffset, EE, EO),
`LoopSpec` (MaxCnt, MaxNon, MaxPlen), `TLVSpec` (IgnVal, IgnMask, PAD1, PADN, EOL),
`OkayTarget`, `FailTarget`, `Wildcard`, `AltWildcard`, `CompareFalse`.

### 1.2 Pseudo-registers

Never stored; recomputed on read (patent L943, L1900):

```
pcurptr ≜ PktHdrBase + CurHdr.Offset      // current protocol header
pdatptr ≜ PktHdrBase + DataHdr.Offset      // current data header (TLV)
```

### 1.3 Sub-register access

`Sz`/`Pos` select a sub-field of a 64-bit register. **General** encoding
(compare/store/CAM): `Sz` 0=nibble, 1=byte, 2=half, 3=word. **Load/store data
size**: `Sz` 0=**8 bytes**, 1=byte, 2=half, 3=word (patent L1902, L2456;
[encodings §1.2](analysis/patent-encodings-recovered.md#12-sz-field-fig-17-p-20)).
Position 0 is the first (most significant, big-endian) sub-register; nibble 0 is
the high 4 bits of byte 0.

```
ExtractSubReg(val, Sz, Pos):
    width = (Sz==0) ? 4 : 8 << (Sz-1)          // nibble/byte/half/word = 4/8/16/32
    # big-endian sub-register numbering within the 64-bit register
    shift = 64 - width - Pos*width
    return (val >> shift) & ((1<<width) - 1)
```

> **Note (Sz overload).** In `ExtractSubReg` and compare/store, `Sz==0` is a
> *nibble*. In `PLOAD`/`PLOADTLVLOOP` byte-count computation, `Sz==0` is *8 bytes*.
> The two never share a code path — load uses `Sz` for byte count, `ExtractSubReg`
> is only called by compare/store/length/CAM. Keep them distinct in the model.

### 1.4 Parser codes

Exit/continuation status is a negative byte
([encodings §4](analysis/patent-encodings-recovered.md#4-parser-codes-fig-45-p-48)).
Only the codes the slice can produce are listed; the model MUST use these exact
values so Phase-6 co-sim compares real status.

```
OKAY               =   0     STOP_FAIL          = -13   // normal | abnormal split
OKAY_RET           =  -1     STOP_LENGTH        = -14
STOP_OKAY          =  -4     STOP_UNKNOWN_PROTO = -15
STOP_NODE_OKAY     =  -5     STOP_TLV_LENGTH    = -18
STOP_SUB_NODE_OKAY =  -6     STOP_LOOP_CNT      = -21
                             STOP_OPTION_LIMIT  = -23
                             STOP_MAX_NODES     = -24
IS_RET_CODE(x) ≜ (x < 0)                       // L1823
IS_OK_CODE(x)  ≜ IS_RET_CODE(x) && (x > STOP_FAIL)   // "normal" exit  (L1825)
```

`STOP_FAIL(-13)` splits normal (`> -13`) from abnormal (`≤ -13`) exits. A normal
exit terminates parsing successfully at `OkayTarget`; an abnormal exit records the
error in `ParserExitCode` and terminates at `FailTarget`.

---

## 2. Shared primitives

Every instruction is defined in terms of these. They mirror the patent's helper
functions so the golden model can factor identically.

### 2.1 Termination helpers

```
Fail_Parser(code):    ParserExitCode.Error = code;  goto FailTarget;  // abnormal, no return
Parser_Exit(code):    (IS_OK_CODE(code)) ? Okay_Parser() : Fail_Parser(code)
Okay_Parser():        ParserExitCode.Error = STOP_OKAY;  goto OkayTarget;  // normal, no return
```

`Fail_Parser`/`Okay_Parser`/`Parser_Exit` never return; in the model they set
`code` and unwind (return a sentinel the driver treats as "parser done").

### 2.2 Load source address & bounds

Mirrors patent L1900–1920.

```
Get_Load_Src_Addr(Offset, n, X):        // n = number_of_bytes
    if (X)  base_off = DataHdr.Offset     // data-header pointer
    else    base_off = CurHdr.Offset      // current-header pointer
    # bounds check (MUST run before dereference)
    if (X):
        if (Offset + n > DataBndLoop.DataBound)        Fail_Parser(STOP_TLV_LENGTH)
        if (DataHdr.Offset + Offset + n > PktLen.ParseLen) Fail_Parser(STOP_TLV_LENGTH)
    else:
        if (CurHdr.Offset + Offset + n > PktLen.ParseLen)  Fail_Parser(STOP_LENGTH)
    return PktHdrBase + base_off + Offset
```

### 2.3 Load & transform

Mirrors patent L1904–1912.

```
LoadReadBytes(addr, n, Shift, Blen, E):
    v = read n bytes at addr
    if (E && n > 1)  v = byteswap(v, n)     // big-endian → host
    v = v << Shift
    mask_bits = (n == 8) ? Blen*2 : Blen    // Sz==0 (8 bytes): Blen doubled (L1911)
    v = v & (ALL_ONES >> mask_bits)          // zero the top mask_bits bits
    return v
```

### 2.4 Load-sets-length

The blog's "load sets length" trick (patent L1918–1920, Claim 12). Applied by the
caller of a load **after** a successful bounds check:

```
Grow_Length_From_Load(Offset, n, X):
    if (X):  extent = Offset + n
             if (extent > DataHdr.Length)  DataHdr.Length = extent
    else:    extent = CurHdr.Offset + Offset + n   // relative to header start
             if (extent - CurHdr.Offset > CurHdr.Length)
                 CurHdr.Length = extent - CurHdr.Offset
```

> A load whose extent exceeds the header's current length grows that length to
> cover the last byte read — i.e. a load doubles as a "header is at least this
> long" check. Only ever grows; never shrinks.

### 2.5 Length computation

`ExtractLenFromArgs` implements the two length variants (patent L2270–2286).

```
ExtractLenFromArgs(D, src, Sz, Pos, Shift, Len, fail_code):
    field = ExtractSubReg(src, Sz, Pos)
    if (!D):
        if (Shift == 7):
            length = Len                         // constant-length check
        else:
            length = (field << Shift) + Len       // variable length
        length &= 0x1FF                           // 9-bit truncation (L2272)
    else:   # D set: Len is a MINIMUM
        length = (field << Shift) & 0x1FF
        if (length < Len)  Fail_Parser(fail_code) // minimum-length check failed
    return length
```

`DataHdr.Offset` is set by the length instruction to `CurHdr.Offset + Len` (the
minimum, or the constant) when `D` or `Shift==7` — see [§4.3](#43-length-family).

### 2.6 CAM lookup & miss

Mirrors patent L2774+; key formats in
[encodings §3](analysis/patent-encodings-recovered.md#3-next-node-address--code-word--cam-key).

```
CommonCamLookup(Sz, Pos, F, Share):
    key_src = F ? Flags : Accum
    match   = ExtractSubReg(key_src, Sz, Pos)
    if (Share != 0):  cam_key = (Share << 15) | match           // shared table
    else:             cam_key = ((PC<<6) & 0xFF00) | (match & 0xFF)  // PC-derived selector
    entry = CAM[cam_key]                        // 20-bit key → 32-bit target
    return entry ? entry.target : 0xFFFFFFFFFFFFFFFF   // all-ones = miss

CommonCamMiss(Miss):                            // Miss = 3-bit disposition
    switch (Miss):
        wild    -> return Wildcard              // address/code
        alt     -> return AltWildcard
        stop    -> Parser_Exit(STOP_UNKNOWN_PROTO)   // no return
        stopsub -> Loop = STOP_SUB_NODE_OKAY; Common_End_of_Node()  // no return
        fail    -> Fail_Parser(STOP_UNKNOWN_PROTO)   // no return
        failsub -> Fail_Parser(STOP_TLV_LENGTH)      // no return
```

### 2.7 Store addressing

Mirrors patent L2152, L2263–2262-note (`F`-bit, counter array index `Sind`).

```
Get_Store_Dest_Addr(Offset, F, Sind):
    if (Sind selects a counter cntrK):
        idx = Counters.CntrK
        Offset = Offset + idx * element_size    // counter-indexed metadata array
    if (F):   base = MetadataBase + 4*FrameOffFnumSeqno.FrameOffset   // current frame
    else:     base = MetadataBase                                     // common metadata
    if (Offset out of the frame/common region)  return NULL           // silently skipped
    return base + Offset
```

### 2.8 Compare error dispatch

`Common2BitError(Er)` selects the on-false action for the compare family
(patent L3057, assembly note L3078). `Er` is a 2-bit field:

```
Common2BitError(Er):
    switch (Er):
        0 (stop)     -> Parser_Exit(STOP_FAIL_CMP≈STOP_COMPARE)   // stop parser
        1 (stopnode) -> Common_End_of_Node()                      // end this node
        2 (stopsub)  -> Loop = STOP_SUB_NODE_OKAY; Common_End_of_Node()  // end sub-node/loop
        3 (fail)     -> Fail_Parser(STOP_FAIL)                    // abnormal fail
    # (the .cmpfail → CompareFalse-handler jump is a later-phase variant)
```

### 2.9 Streaming model

The patent targets a streaming parse buffer, so several routines contain
`while (PktLen.ParseLen < TempLast && !PktLen.P) Wait_for_more_data()`. In the
golden model the whole packet is present, so:

- `PktLen.P = 1` always (all header bytes present),
- the `while` loop is a **no-op**, and
- the subsequent `if (PktLen.ParseLen < TempLast) Fail_Parser(...)` becomes the
  real, value-affecting bounds check.

This is a modelling simplification only; it changes no result. RTL that streams
MUST reproduce the same final `{flow_keys, code}`.

---

## 3. DataBound lifecycle

`DataBndLoop.DataBound` bounds the data elements (TLVs/flags/array) inside the
current protocol header (Claim 6, patent L120, L1501, L2305, L2115, L777).

1. **Init** to ∞ = `0xFFFFFFFF` at parser start and after every `.stp` transition
   to a new protocol node (patent L3766, L3789).
2. **`PLENCUR`** sets `DataBound = CurHdr.Offset + CurHdr.Length − DataHdr.Offset`
   (patent L2305) — i.e. the bytes between the end of the minimum header and the
   end of the computed header, which is the option/TLV region.
3. **`PLENDATABND`** (deferred) may only *tighten* it (error if it would grow).
4. **Each loop iteration** decrements: at `.stp` inside a data loop,
   `DataBound −= DataHdr.Length` (patent L2115, L3809).
5. **Normal loop end** when `DataBound == 0` (patent L777, L2050); the loop head
   detects this, sets `Loop = STOP_SUB_NODE_OKAY`, and calls `Common_End_of_Node`.
6. Data-context loads/lengths check against **both** `DataBound` **and**
   `ParseLen`; over-bound → `STOP_TLV_LENGTH` (patent L1914).

---

## 4. Per-instruction semantics

Each instruction is `execute_*(...)` in Phase 2. `S` is the stop bit; when set, the
instruction ends by calling [`Common_End_of_Node`](#5-common_end_of_node) (which
does not return). "MNR" = *may not return* (calls a termination or EON helper).

### 4.1 PINITPARSER

Initialise parser state for a new PDU from integer registers `a0..a7`
(`regs[10..17]`) (patent L3147).

```
execute_initparser(a0..a7):                       // MNR: never, it's the entry
    InitializeParser(a0,a1,a2,a3,a4,a5,a6,a7)
    # per encodings §5.1: CurHdr=DataHdr=0, NodeLoopCnt=Counters=0,
    # DataBound=0xFFFFFFFF, Loop=OKAY_RET, Next=STOP_OKAY, ParseLen=min(...),
    # P=F=1, config regs from the work item.
```

### 4.2 PLOAD

Load 1/2/4/8 bytes from a header pointer into `Accum`, with endian/shift/mask
transforms and the two mandatory side effects (bounds + load-sets-length)
(patent L1925).

```
execute_load(Sz, X, E, Shift, Blen, Offset):      // MNR (bounds)
    n = (Sz==0) ? 8 : (1 << (Sz-1))
    addr = Get_Load_Src_Addr(Offset, n, X)         // §2.2  (bounds; MNR)
    Accum = LoadReadBytes(addr, n, Shift, Blen, E) // §2.3
    Grow_Length_From_Load(Offset, n, X)            // §2.4  (load-sets-length)
```

> The patent's PLOAD pseudocode (L1925) folds the length-grow into
> `LoadReadBytes`; we split it out as [§2.4](#24-load-sets-length) for clarity.
> Behaviour is identical.

### 4.3 Length family

Set `CurHdr.Length` / `DataHdr.Length` and (for `PLENCUR`) `DataHdr.Offset` +
`DataBound`. Shared computation in [§2.5](#25-length-computation). Assembler:
`prs.lenset` (D=0), `prs.lensetmin` (D=1), `prs.lensetadd` (accumulate);
`prs.lensettlv` = `PLENDATATLV`.

**PLENCUR** — set current protocol-header length (patent L2287):

```
execute_lencur(D, Sz, Pos, Shift, Len, S):        // MNR
    TempILen = Len + (D ? 1 : 0)                    // minimum ≥ 1 when D
    TempLen  = ExtractLenFromArgs(D, Accum, Sz, Pos, Shift, TempILen, STOP_LENGTH)
    TempLast = CurHdr.Offset + TempLen
    # streaming no-op (§2.9), then real bound:
    if (PktLen.ParseLen < TempLast || TempLen < CurHdr.Length)
        Fail_Parser(STOP_LENGTH)
    CurHdr.Length = TempLen
    if (D || Shift == 7)
        DataHdr.Offset = CurHdr.Offset + TempILen  // options start after min hdr
    DataBndLoop.DataBound = CurHdr.Offset + CurHdr.Length - DataHdr.Offset   // §3.2
    if (S) Common_End_of_Node()
```

**PLENDATA** — set `DataHdr.Length` for a non-TLV sub-node (patent L2314):

```
execute_lendata(D, Sz, Pos, Shift, Len, S):       // MNR
    TempILen = Len + (D ? 1 : 0)
    TempLen  = ExtractLenFromArgs(D, Accum, Sz, Pos, Shift, TempILen, STOP_TLV_LENGTH)
    TempLast = DataHdr.Offset + TempLen
    if (TempLen > DataBndLoop.DataBound ||
        PktLen.ParseLen < TempLast || TempLen < DataHdr.Length)
        Fail_Parser(STOP_TLV_LENGTH)
    DataHdr.Length = TempLen
    if (S) Common_End_of_Node()
```

**PLENDATATLV** — `DataHdr.Length` for one TLV, maintaining option-count limits
(patent L2365):

```
execute_lendatatlv(D, Sz, Pos, Shift, Len, S):    // MNR
    TempILen = Len + (D ? 1 : 0)
    if (NodeLoopCnt.NonPadCnt >= LoopSpec.MaxNon)
        Common_Loop_Limit_Exceeded(STOP_OPTION_LIMIT)   // MNR
    NodeLoopCnt.NonPadCnt++
    TempLen  = ExtractLenFromArgs(D, Accum, Sz, Pos, Shift, TempILen, STOP_TLV_LENGTH)
    TempLast = DataHdr.Offset + TempLen
    if (TempLen > DataBndLoop.DataBound ||
        PktLen.ParseLen < TempLast || TempLen < DataHdr.Length)
        Fail_Parser(STOP_TLV_LENGTH)
    DataHdr.Length = TempLen
    NodeLoopCnt.ConPad = 0                          // reset consecutive-pad run
    NodeLoopCnt.PadLen = 0
    if (S) Common_End_of_Node()                     // .stp advances DataHdr, decrements DataBound (§5)
```

### 4.4 Compare family

Compare an `Accum` sub-register to an immediate; on false, dispatch via
[`Common2BitError`](#28-compare-error-dispatch). Assembler suffixes select `Er`:
`.stop`→0, `.stopnode`→1, `.stopsub`→2, none/`.fail`→3 (patent L3078).

**PCMPIB** (masked byte equality, patent L3054) / **PCMPINEB** (inequality, L3065):

```
execute_cmpib(Pos, Value, Mask, Er, S):           // MNR on false
    Temp = ExtractSubReg(Accum, /*byte*/1, Pos)
    if ((Temp & Mask) != Value)  Common2BitError(Er)
    if (S) Common_End_of_Node()

execute_cmpineb(Pos, Value, Mask, Er, S):         // MNR on false
    Temp = ExtractSubReg(Accum, 1, Pos)
    if ((Temp & Mask) == Value)  Common2BitError(Er)
    if (S) Common_End_of_Node()
```

**PCMPI{LT,LE,GT,GE}B** (nibble/byte/half/word ordered compare, patent L3101):

```
execute_cmpord(Func3, Sz, Pos, Value, Er, S):     // MNR on false
    TempVal = ExtractSubReg(Accum, Sz, Pos)
    Temp = (Func3==0) ? TempVal <  Value :
           (Func3==1) ? TempVal <= Value :
           (Func3==2) ? TempVal >  Value :
                        TempVal >= Value
    if (!Temp)  Common2BitError(Er)
    if (S) Common_End_of_Node()
```

> The IPv4 version check `prs.cmpi.b.fail paccum, 0x40:0xf0` is
> `execute_cmpib(Pos=0, Value=0x40, Mask=0xf0, Er=3, S=0)`: `(byte0 & 0xf0)==0x40`,
> else `Fail_Parser(STOP_FAIL)`.

### 4.5 CAM family

CAM lookup on an `Accum`/`Flags` sub-register; result → `Accum`, → `Next`, or a
jump. Miss → [`CommonCamMiss`](#26-cam-lookup--miss). Patent L2774–2850.

**PCAM** (→Accum) / **PCAMNEXT** (→Next, preserving control bits):

```
execute_cam(Sz, Pos, F, Share, Miss, S):          // MNR on miss
    TempRes = CommonCamLookup(Sz, Pos, F, Share)
    if (TempRes == ALL_ONES)  TempRes = CommonCamMiss(Miss)
    Accum = TempRes
    if (S) Common_End_of_Node()

execute_camnext(Sz, Pos, F, Share, Miss, S):      // MNR on miss
    TempRes = CommonCamLookup(Sz, Pos, F, Share)
    if (TempRes == ALL_ONES)  TempRes = CommonCamMiss(Miss)
    # low 24 bits = new address/code; preserve control bits [30:24] of old Next
    Next = (TempRes & 0xFFFFFF) | (Next & 0x7F000000)
    if (S) Common_End_of_Node()
```

**PCAMJUMP** — jump to the looked-up address, or act on a returned code
(patent L2805):

```
execute_camjump(Sz, Pos, F, Share, Miss, S):      // MNR (jumps / EON)
    TempRes = CommonCamLookup(Sz, Pos, F, Share)
    if (TempRes == ALL_ONES)  TempRes = CommonCamMiss(Miss)
    if (!IS_RET_CODE(TempRes)):
        Goto_Relative_Ins_Addr(TempRes & 0xFFFFFF)   // jump; no return
    elif (TempRes == OKAY_RET):    pass               // fall through
    elif (TempRes == STOP_OKAY):   Okay_Parser()
    elif (TempRes == STOP_NODE_OKAY):  Common_End_of_Node()
    elif (TempRes == STOP_SUB_NODE_OKAY):
        DataBndLoop.Loop = STOP_SUB_NODE_OKAY; Common_End_of_Node()
    else:  Parser_Exit(TempRes)                       // abnormal
    if (S) Common_End_of_Node()
```

**PCAMJUMPLOOP** — CAM-jump in a loop iteration; any non-`OKAY_RET` code becomes a
loop exit (patent L2834):

```
execute_camjumploop(Sz, Pos, F, Share, Miss, S):  // MNR
    TempRes = CommonCamLookup(Sz, Pos, F, Share)
    if (TempRes == ALL_ONES)  TempRes = CommonCamMiss(Miss)
    if (!IS_RET_CODE(TempRes)):
        Goto_Relative_Ins_Addr(TempRes & 0xFFFFFF)
    elif (TempRes != OKAY_RET):
        DataBndLoop.Loop = TempRes; Common_End_of_Node()   // loop exit
    if (S) Common_End_of_Node()
```

**PCAMJUMPTLVLOOP** — as `PCAMJUMPLOOP`, plus the "ignore unknown TLV" check on a
CAM miss before miss processing (patent L3640):

```
execute_camjumptlvloop(Sz, Pos, F, Share, Miss, S):   // MNR
    TempRes = CommonCamLookup(Sz, Pos, F, Share)
    if (TempRes == ALL_ONES):
        TempType = ExtractSubReg(Accum, Sz, Pos)
        if ((TempType & TLVSpec.IgnMask) == TLVSpec.IgnVal):
            Goto_Loop_Head()                    // ignore this TLV, next iteration
        TempRes = CommonCamMiss(Miss)           // not ignorable → miss processing
    if (!IS_RET_CODE(TempRes)):
        Goto_Relative_Ins_Addr(TempRes & 0xFFFFFF)
    elif (TempRes != OKAY_RET):
        DataBndLoop.Loop = TempRes; Common_End_of_Node()
    if (S) Common_End_of_Node()
```

### 4.6 Loop heads

Loop heads run at the top of each iteration; they initialise `Loop`/`NodeLoopCnt`
on the first pass and detect normal loop termination.

```
Common_Loop_Head():                               // patent L1949, L2018
    if (IS_RET_CODE(DataBndLoop.Loop)):           // first iteration
        NodeLoopCnt &= 0xFFFF000000000000          // clear loop counts
        DataBndLoop.Loop = PC & 0xFFFFFF           // Loop = address of this head
```

**PLOADTLVLOOP** — load the TLV type into `Accum`; head of a generic TLV loop
(patent L1948):

```
execute_loadtlvloop(Sz, Shift, Blen, Offset):     // MNR
    Common_Loop_Head()
    if (DataBndLoop.DataBound == 0):              // normal end of TLV loop
        DataBndLoop.Loop = STOP_SUB_NODE_OKAY
        Common_End_of_Node()                       // no return
    n = (Sz==0) ? 8 : (1 << (Sz-1))
    addr = Get_Load_Src_Addr(Offset, n, /*X=*/1)  // always data pointer
    Accum = LoadReadBytes(addr, n, Shift, Blen, /*E=*/0)
    # TLV type now in Accum for the following PCAMJUMPTLVLOOP
```

**PTLVFASTLOOP** — specialised head for 1-byte-type + 1-byte-length TLVs (IPv4/
IPv6/TCP options), handling PAD1/PADN/EOL inline (patent L2044). Loads type+length
(2 bytes), handles padding via `TLVSpec.{PAD1,PADN,EOL}`, else falls through with
the type in `Accum` and length applied:

```
execute_tlvfastloop(...):                          // MNR
  _padding_loop:
    if (IS_RET_CODE(DataBndLoop.Loop)):           // first iteration
        NodeLoopCnt &= 0xFFFF000000000000
        DataBndLoop.Loop = PC & 0xFFFFFF
    if (DataBndLoop.DataBound == 0):
        DataBndLoop.Loop = STOP_SUB_NODE_OKAY; Common_End_of_Node()
    TempLast = DataHdr.Offset + 2                  // need type+length bytes
    if (DataBndLoop.DataBound == 1 || PktLen.ParseLen < TempLast):
        # single byte left, or truncated — treat per EOL/PAD1 rules, else fail
        ... (EOL / STOP_TLV_LENGTH; full padding rules deferred with §4.10)
    type = byte@[DataHdr.Offset]; len = byte@[DataHdr.Offset+1]
    handle PAD1 (type==PAD1 → 1-byte, goto _padding_loop),
           PADN/EOL per TLVSpec, else set DataHdr.Length=len and fall through
```

> For the slice we implement `PTLVFASTLOOP` far enough to walk well-formed IPv4/TCP
> options and to *safely reject* the malformed corpus cases (len=0 non-advance,
> len>remaining). Full PAD-run/EOL accounting (`ConPad`, `PadLen`, `MaxCPad`) is
> refined in the phase that adds `PLENDATAPAD`/`PLENDATATLVEOL`.

**PFLAGSLOOP** — head of a flag-field loop (GRE); `Accum` ← index of the next set
flag bit (patent L1979, L2600):

```
execute_flagsloop(Sz, Pos, R, Mask):              // MNR
    if (IS_RET_CODE(DataBndLoop.Loop)):           // first iteration
        TempVal = ExtractSubReg(Accum, Sz, Pos)
        TempVal = (TempVal & Mask) | (Flags & ~0xFFFF)
        if (R)  TempVal = ReverseByteBits(TempVal, 2)  // .rev: logical bit order
        Flags = TempVal
        DataBndLoop.Loop = PC & 0xFFFFFF
        NodeLoopCnt &= 0xFFFF000000000000
    if (Flags == 0):                              // normal termination
        DataBndLoop.Loop = STOP_SUB_NODE_OKAY; Common_End_of_Node()
    TempWhich = FFS(Flags)                         // first set bit, from 0
    Accum = TempWhich
    Flags &= ~(1 << TempWhich)                     // consume that flag
```

### 4.7 Store family

Write `Accum`/`Flags`/immediate to common metadata or the current frame; this is
how `flow_keys` fields are populated. Patent L2160, L2234.

**PSTORE**:

```
execute_store(Sz, F, Pos, J, Sind, E, Offset, S): // MNR (EON)
    addr = Get_Store_Dest_Addr(Offset, F, Sind)
    if (addr == NULL)  goto _leave                 // out-of-region → silent skip
    TempVal = J ? Flags : Accum
    if (Sz == 0):  Temp = TempVal; n = 8
    else:          Temp = ExtractSubReg(TempVal, Sz, Pos); n = 1 << (Sz-1)
    if (E)  Temp = ByteSwap(Temp, Sz)
    StoreToMemory(Temp, addr, n)
  _leave:
    if (S) Common_End_of_Node()
```

**PSTOREIMM** (store a sign-extended 7-bit immediate, patent L2234):

```
execute_storeimm(Sz, F, Value, Offset, S):        // MNR (EON)
    addr = Get_Store_Dest_Addr(Offset, F, 0)
    if (addr == NULL)  goto _leave
    if (Sz == 0):  Temp = Value; n = 4            // Sz==0 → 4-byte store here
    else:          Temp = SignExtend(Value, 7);  n = 1 << (Sz-1)
    StoreToMemory(Temp, addr, n)
  _leave:
    if (S) Common_End_of_Node()
```

### 4.8 Counters

**PINCCNTR** — increment a user counter or the encap counter, enforcing its limit
(patent L2623). `prs.inc.cntr cntrK` / `prs.inc.encap`.

```
execute_inccntr(Cntr, Val, F, Bnum, S):           // MNR on limit (per action)
    if (Cntr == ENCAP):
        Counters.Encap += Val
        if (Counters.Encap > ParserConfig.MaxEncap):  on-exceed per EE/EO (§5)
    else:
        limit  = CounterLimitsConfig.CntrK
        action = CounterLimitsConfig.EK           // stop|stop-err|exit-loop|no-inc
        if (Counters.CntrK + Val > limit):  apply action    // MNR for stop*/exit-loop
        else:                               Counters.CntrK += Val
    if (S) Common_End_of_Node()
```

### 4.9 Control / next

**PSTP** — pure end-of-node marker (patent L2518): `Common_End_of_Node()`.

**PNEXTNODE** — set `Next` to a 16-bit PC-relative address (with control bits),
then optionally EON (patent L2476):

```
execute_nextnode(V, Payload, S):                  // MNR (EON)
    addr = PC + (Payload << 2)                     // 16-bit PC-relative, ×4
    Next = (addr & 0xFFFFFF) | (Next & 0x7F000000) | (V ? OVERLAY_BIT : 0)
    if (S) Common_End_of_Node()
```

**PSETCODE** — set `Next` to a parser **code** (bit-31 set), e.g. an early
`STOP_OKAY` (patent L2501):

```
execute_setcode(Code, S):                         // MNR (EON)
    Next = CODE_BIT | (Code & 0xFF)
    if (S) Common_End_of_Node()
```

### 4.10 Deferred in the slice

Present in the ISA but **not required** to parse the slice; specified in a later
phase. Listed here so the model's dispatch table is complete and traps them:

- **`PRUNTHREAD` / `PEVENTLOOP` / `PEVENTLOOPEND`** — worker-thread scheduling
  (patent L3157). The slice runs single-threaded and inline, so `PRUNTHREAD`
  reduces to its `if (S) Common_End_of_Node()` tail; the event loop is the model's
  driver, not an instruction.
- **`PARR*`** (array-lookup twins of CAM), **`PVARINT`**, **`PEXTRACT`**,
  **`PDATAEXTRACT`** + pseudo-moves.
- **`PSETCNTRBIT` / `PRESETCNTR`**, **`PLENDATABND` / `PLENDATAPAD` /
  `PLENDATATLVEOL`** (full PAD/EOL accounting).

---

## 5. Common_End_of_Node

The `.stp` / loop epilogue. **Two stages: `Loop` first, then `Next`** (Claims 6–8;
patent L124–147, L3651–3668, [conformance §4](analysis/patent-conformance.md#4-end-of-node--control-flow-divergentincomplete)).
Never returns.

```
Common_End_of_Node():
  # ── Stage 1: the Loop register (data-header / sub-node level) ───────────────
  if (!IS_RET_CODE(DataBndLoop.Loop)):            // Loop holds an ADDRESS → live loop
      DataBndLoop.DataBound -= DataHdr.Length      // consume this element (§3.4)
      DataHdr.Offset        += DataHdr.Length      // advance to next data header
      DataHdr.Length         = 0
      Goto_Relative_Ins_Addr(DataBndLoop.Loop)     // next iteration; no return
  elif (!IS_OK_CODE(DataBndLoop.Loop)):           // Loop holds an ERROR code
      Fail_Parser(DataBndLoop.Loop)                // no return
  # else: Loop holds an OKAY code (OKAY_RET / STOP_SUB_NODE_OKAY) → fall through

  # ── Stage 2: the Next register (protocol-header level) ──────────────────────
  if (!IS_RET_CODE(Next)):                         // Next holds an ADDRESS
      # node-count limit
      NodeLoopCnt.NodeCnt++
      if (NodeLoopCnt.NodeCnt > ParserConfig.MaxNodes)  Fail_Parser(STOP_MAX_NODES)

      if (Next & ENCAP_BIT /*0x40000000*/):        // encapsulation node
          Counters.Encap++
          if (Counters.Encap > ParserConfig.MaxEncap):
              if (ParserConfig.EE)  Fail_Parser(STOP_ENCAP_DEPTH)
              else                  Counters.Encap--    // clamp; EO may overwrite last frame
          else:
              FrameOffFnumSeqno.FrameOffset += (ParserConfig.FrameSize + 1)  // advance frame

      if (Next & OVERLAY_BIT /*0x20000000*/):      // overlay node → do NOT advance
          pass                                     // offsets/pointers/lengths unchanged
      else:                                         // normal transition
          CurHdr.Offset += CurHdr.Length           // advance to next protocol header
          DataHdr.Offset = CurHdr.Offset           // reset data header to header start
          CurHdr.Length  = 0
          DataHdr.Length = 0
          DataBndLoop.DataBound = 0xFFFFFFFF         // reset to ∞ (§3.1)
      DataBndLoop.Loop = OKAY_RET                    // arm Loop for the next node's loops
      Goto_Relative_Ins_Addr(Next & 0xFFFFFF)        // jump to next node; no return
  elif (IS_OK_CODE(Next)):                          // Next holds an OKAY code (STOP_OKAY/NULL)
      Okay_Parser()                                  // normal exit → OkayTarget
  else:                                             // Next holds an ERROR code
      Fail_Parser(Next)                              // abnormal exit → FailTarget
```

Key points the slice depends on:

- **Loop advances `DataHdr`; Next advances `CurHdr`** — different pointers
  (patent L124–147). This is what makes TLV loops and protocol transitions
  distinct.
- **Overlay** (`0x20000000`): re-interpret the same bytes under a new node without
  advancing (e.g. IPv4/IPv6 dispatched from Ethernet without re-reading).
- **Encapsulation** (`0x40000000`): bump `Encap`, advance the metadata frame so a
  new layer's `flow_keys` land in a fresh frame.
- After a normal protocol transition, `DataBound` is reset to ∞ and `Loop` to
  `OKAY_RET` so the next node starts clean.

---

## 6. Worked program — Ethernet · IPv4 · IP-options · TCP

The patent's own worked example (L3765–3826), re-derived against the pseudocode
above, with the patent's exact numeric trace. Packet: Ethernet(14) → IPv4(IHL=7 ⇒
28 bytes, i.e. 8 bytes of options) → TCP(20). This is the reference *program* the
golden model runs and the RTL must reproduce.

```asm
ether_node:
    prs.load.h      paccum, pcurptr+12        ; EtherType @12..13 → Accum; grows CurHdr.Length→14
    prs.cam.h.stp   pnext,  paccum[0], 1      ; shared table 1: EtherType→ipv4_node; .stp

ipv4_node:
    prs.load.b      paccum, pcurptr           ; version+IHL byte → Accum
    prs.lensetmin.n pcurhdr, paccum[1], 4:20  ; CurHdr.Length = IHL×4 (min 20); sets DataHdr.Offset, DataBound
    prs.cmpi.b.fail paccum, 0x40:0xf0         ; (byte0 & 0xf0)==0x40 (IPv4), else Fail_Parser(STOP_FAIL)
    prs.load.b      paccum, pcurptr+9         ; IP protocol @9 → Accum
    prs.camnext     pnext,  paccum[0], 2      ; table 2: proto→tcp_node (into Next, no .stp yet)

ip_options_loop:                              ; walk IPv4 options as TLVs
    prs.loadtlvloop paccum, pdatptr           ; head: load option type; DataBound==0 ⇒ exit loop
    prs.camjumptlvloop paccum[0], 3           ; table 3: option type→handler; ignore unknown per TLVSpec
    ...
    prs.lensettlv.b.stp pdathdr, paccum[1]    ; DataHdr.Length = option length; .stp → advance DataHdr, DataBound-=len

tcp_node:
    prs.lensetmin.n.stp pcurhdr, paccum, 4:20 ; TCP hdr len (min 20); .stp with no Next → STOP_OKAY
```

**Trace** (patent Points 1–7):

| Point | After | CurHdr.Off | CurHdr.Len | DataHdr.Off | DataHdr.Len | DataBound |
|------:|-------|-----------:|-----------:|------------:|------------:|----------:|
| 1 | `load.h @12` (ether) | 0 | 14 (grown) | 0 | 0 | ∞ |
| 2 | `cam.h.stp` → ipv4 | 14 | 0 | 14 | 0 | ∞ |
| 3 | `lensetmin 4:20` | 14 | 28 | 34 | 0 | 8 |
| 4 | `lensettlv.b` (opt len=8) | 14 | 28 | 34 | 8 | 8 |
| 5 | `.stp` of the TLV | 14 | 28 | 42 | 0 | 0 |
| 6 | 2nd `loadtlvloop` (DataBound==0 ⇒ exit) → tcp | 42 | 0 | 42 | 0 | ∞ |
| 7 | `lensetmin.n.stp` (TCP=20), no Next | — | 20 | 62 | 0 | 0 → exit `STOP_OKAY` |

At Point 2, `.stp` transitions to a new protocol node: `CurHdr.Offset` advances by
14 (the Ethernet length), `DataHdr.Offset` follows, lengths reset, `DataBound`←∞
(patent L3789). At Point 3, `lensetmin` sets `CurHdr.Length=28`,
`DataHdr.Offset=14+20=34`, `DataBound=14+28−34=8` — priming the option walk (patent
L3796). At Point 5, the TLV `.stp` advances `DataHdr.Offset` by the option length
(→42) and decrements `DataBound` to 0 (patent L3810). At Point 6, the loop head
sees `DataBound==0`, exits the loop, and (no PostLoop) transitions to TCP with
`CurHdr.Offset=14+28=42` (patent L3816). At Point 7, the TCP `.stp` finds no `Next`
and the parser terminates normally with `STOP_OKAY` (patent L3826).

**Extensions the slice adds** (same machinery): VLAN via an **overlay/encap** node
between `ether_node` and the L3 dispatch (stacked VLAN = loop over the overlay);
IPv6 via a **`PLOADTLVLOOP` + `PCAMJUMPTLVLOOP`** extension-header walk keyed on
Next-Header; UDP as a straight-line node with no options.

---

## 7. Phase-2 binding

Each routine above maps 1:1 to a Phase-2 `execute_*`. The
[Phase 2 `pstate`](phase-2-reference-model.md#21-shape-of-the-model) already
carries the [§1.1](#11-architectural-state) fields; the signatures below refine the
Phase-2 stubs to match this spec exactly.

| Instruction | Phase-2 function | Notes |
|-------------|------------------|-------|
| PINITPARSER | `execute_initparser(a0..a7)` | sets init state per encodings §5.1 |
| PLOAD | `execute_load(sz,x,e,shift,blen,off)` | §2.2 bounds + §2.4 grow |
| PLENCUR | `execute_lencur(D,sz,pos,shift,len,S)` | sets DataHdr.Offset + DataBound |
| PLENDATA | `execute_lendata(D,sz,pos,shift,len,S)` | |
| PLENDATATLV | `execute_lendatatlv(D,sz,pos,shift,len,S)` | option-count limit |
| PCMPIB / PCMPINEB | `execute_cmpib/cmpineb(pos,val,mask,er,S)` | |
| PCMPI{LT,LE,GT,GE}B | `execute_cmpord(func3,sz,pos,val,er,S)` | |
| PCAM / PCAMNEXT | `execute_cam/camnext(sz,pos,f,share,miss,S)` | |
| PCAMJUMP{,LOOP,TLVLOOP} | `execute_camjump{,loop,tlvloop}(...)` | jumps / loop-exit |
| PLOADTLVLOOP | `execute_loadtlvloop(sz,shift,blen,off)` | X=1 always |
| PTLVFASTLOOP | `execute_tlvfastloop(...)` | 1B type+len fast path |
| PFLAGSLOOP | `execute_flagsloop(sz,pos,r,mask)` | GRE flags |
| PSTORE / PSTOREIMM | `execute_store/storeimm(...)` | metadata/frame |
| PINCCNTR | `execute_inccntr(cntr,val,f,bnum,S)` | limit action |
| PSTP / PNEXTNODE / PSETCODE | `execute_stp/nextnode/setcode(...)` | |
| (epilogue) | `common_end_of_node()` | Loop-first, then Next |

---

## 8. Exit criteria & conformance

**Phase-1 exit criteria — met by this document:**

- ✅ Every instruction the slice uses has unambiguous pseudocode, side effects, and
  error behaviour, each mirroring the patent (Lnnnn cited).
- ✅ Register state, pseudo-registers, sub-register access, `DataBound` lifecycle,
  and the two-stage `Common_End_of_Node` are specified — not the blog's single-
  cursor simplification.
- ✅ Parser codes are the patent's negative-byte scheme with the `STOP_FAIL`
  normal/abnormal split.
- ✅ No cycle-count / microarchitecture language (streaming waits reduced to the
  [§2.9](#29-streaming-model) no-op).
- ✅ A 1:1 binding to the Phase-2 golden model ([§7](#7-phase-2-binding)) and the
  patent's own numeric trace re-derived against the spec ([§6](#6-worked-program--ethernet--ipv4--ip-options--tcp)).

**Open questions (carried to Phase 2 / later phases):**

- **PTLVFASTLOOP padding accounting** — full `ConPad`/`PadLen`/`MaxCPad` and EOL
  handling land with `PLENDATAPAD`/`PLENDATATLVEOL`. The slice needs only correct
  walking + safe rejection of malformed options ([4.6](#46-loop-heads)).
- **CAM miss dispositions** — the slice exercises `wild`/`stopsub`/`fail`; confirm
  `alt`/`failsub` corpus coverage in Phase 6.
- **Metadata-frame layout** — one frame for the single-encap slice; multi-frame
  addressing (`FrameSize`, `FrameOffset`) is [4.7](#47-store-family)/§5 but its
  concrete `flow_keys` mapping is a Phase-2 decision.
- **`Common2BitError` Er=0 code** — patent text names `STOP_FAIL_CMP`/`STOP_COMPARE`
  inconsistently; the model will pin one value and Phase-6 will assert on it.

## References

Patent claims + detailed description (`Lnnnn` →
[`references/patent-us12461885.txt`](references/patent-us12461885.txt));
[`analysis/patent-encodings-recovered.md`](analysis/patent-encodings-recovered.md)
(bit-accurate encodings, parser codes, register layouts);
[`analysis/patent-conformance.md`](analysis/patent-conformance.md) (gap analysis);
[overview §1](phase-1-isa-spec.md). Downstream:
[Phase 2 golden model](phase-2-reference-model.md),
[Phase 3 encoding](phase-3-encoding.md).
