# Phase 1 — ISA specification

← [Phase 0](phase-0-scope-and-stack.md) · [Docs index](README.md) · [Phase 2 »](phase-2-reference-model.md)

## Objective

Define, precisely and implementation-independently, the **parser registers** and
the **semantics of every parser instruction** — mirroring Herbert's blog. This
doc is the human-readable spec; [Phase 2](phase-2-reference-model.md) turns it
into an executable golden model, and [Phase 3](phase-3-encoding.md) into bits.

> **Layer rule:** no cycle counts here. Semantics only.

## Inputs / prerequisites

- Phase 0 scope (the vertical slice defines which instructions we must cover).
- Blog + patent as the semantic source.

## Design detail

### 1.1 Parser registers

| Register | Role |
|----------|------|
| `pktbase` | Pointer to the first byte of the packet in memory. |
| `pktlen` | Total packet length (bytes). Bound for all loads. |
| `pcurptr` | Pointer to the first byte of the **current header** (the cursor). |
| `pcurhdr` | Length of the current header. Advances the cursor at end-of-node. |
| `paccum` | Accumulator: destination of loads; source for CAM lookups & compares. |
| `pnext` | Address of the next parse node (set by CAM lookup / next-node logic). |
| *(metadata buffer)* | Output region addressed by store-to-metadata instructions. |

Cursor invariant at all times: `pktbase ≤ pcurptr` and
`pcurptr + pcurhdr ≤ pktbase + pktlen` (a violation traps/exits the parser).

**ABI note (Risk R2):** prefer keeping as much cursor state as practical in
ordinary integer registers so parser instrs compose with plain C. Dedicated
parser regs are kept minimal; their save/restore on context switch is specified
here (**TBD:** exact CSR-vs-shadow mechanism, resolved with Phase 4).

### 1.2 Instruction classes

Mirroring the blog:

1. **Move** — copy values between integer registers and parser registers.
2. **Load-from-header** — load 1/2/4/8 bytes from the current header into a parser
   register, with two side effects:
   - **bounds check:** last byte offset must be `< pktlen`, else parser exits on
     error;
   - **implicit length:** if the last loaded offset ≥ `pcurhdr`, set
     `pcurhdr = last_offset + 1` (the *load-sets-length trick*).
3. **Store-to-metadata** — write a register to the metadata buffer (builds the
   flow key).
4. **Length** — explicitly set/check current header length from a field, with a
   multiplier and enforced minimum (`lensetmin`); also checks against `pktlen`.
5. **Compare** — logical compare of a value; on failure trap to a handler or exit
   the parser (e.g. verify IP version == 4).
6. **CAM / array lookup** — look up a key (EtherType, IP proto, port…) in a
   numbered sub-table; result is the next node address into `pnext`.
7. **Loop** — allow loops in parser processing (e.g. IPv6 ext-header / TLV chains).
8. **Runthread** — schedule a worker thread for deeper per-layer processing
   (out of scope for the first slice, specified but not implemented).

### 1.3 End-of-node processing (`.stp`)

A `.stp`-qualified instruction ends the node. End-of-node:

1. advance the cursor: `pcurptr += pcurhdr`;
2. if `pnext` is a valid node address → jump (set PC = `pnext`);
3. else → exit the parser (parse complete) and return to the caller.

### 1.4 Instruction mnemonics (baseline set)

Herbert-style syntax; suffixes: `.b/.h/.w/.d` = byte/half/word/double,
`.n` = nibble, `.stp` = end-of-node, `.fail` = exit-on-false.

| Mnemonic | Meaning |
|----------|---------|
| `prs.mov  pdst, rs` / `prs.mov rd, psrc` | move between integer & parser regs |
| `prs.load.{b,h,w,d} paccum, pcurptr+imm` | load field (bounds + implicit length) |
| `prs.store.{b,h,w,d} meta+imm, psrc` | store to metadata buffer |
| `prs.lensetmin.n pcurhdr, paccum[i], M:MIN` | set var length = nibble×M, min MIN |
| `prs.cmpi.n.fail paccum, imm` | compare nibble == imm; exit on false |
| `prs.cam.{b,h}[.stp] pnext, paccum[i], subtbl` | CAM lookup → `pnext` (opt. end-of-node) |
| `prs.loop ...` | loop primitive (ext-hdr/TLV chains) |
| `prs.runthread ...` | schedule deep-processing worker (deferred) |

Field selectors like `paccum[0]`/`paccum[1]` pick a sub-field (half-word / nibble)
of the accumulator.

### 1.5 Worked example — Ethernet + IPv4 (from the blog)

```asm
ether_node:
    prs.load.h     paccum, pcurptr+12         ; load EtherType; last off=13 ⇒ pcurhdr=14
    prs.cam.h.stp  pnext,  paccum[0], 1        ; sub-table 1: EtherType→node; end-of-node
                                               ;   0x0800 ⇒ pnext = ipv4_node
ipv4_node:
    prs.load.b     paccum, pcurptr             ; byte 0: version + IHL
    prs.lensetmin.n pcurhdr, paccum[1], 4:20   ; len = IHL_nibble×4, min 20, ≤ pktlen
    prs.cmpi.n.fail paccum, 4                   ; version nibble must be 4, else exit
    prs.load.b     paccum, pcurptr+9           ; IP protocol
    prs.cam.b.stp  pnext,  paccum[0], 2        ; sub-table 2: proto→node; end-of-node
                                               ;   6⇒tcp_node, 17⇒udp_node
```

Notes tying back to semantics:
- Ethernet length is set *implicitly* by the EtherType load (offset 13 ⇒ 14).
- IPv4 length is set *explicitly* and range-checked by `lensetmin`.
- The version compare guards against a lying EtherType.
- Each `.stp` advances the cursor and dispatches to the next node or exits.

### 1.6 Error / exit behavior

The parser exits (returns to caller with a status) on: out-of-bounds load,
length-check failure (`lensetmin` min or `pktlen` overflow), failed `.fail`
compare, or `.stp` with no valid `pnext`. A status code distinguishes *complete*
from each *error* class. Malformed-packet handling is a first-class concern
(Risk R4) and is exercised hard in Phases 2 & 6.

## Step-by-step tasks

1. Freeze the parser-register set and invariants (1.1).
2. Write full semantic prose for each instruction class (1.2), including all side
   effects and traps.
3. Specify `.stp` end-of-node and the exit/status model (1.3, 1.6).
4. Enumerate the baseline mnemonics + operand forms (1.4).
5. Cover the vertical slice's extra needs: IPv6 fixed header + **ext-header chain
   loop**, VLAN stacking. Note where `prs.loop` is required.
6. Re-derive the blog's Ethernet/IPv4 example against the spec (1.5) as a
   self-check.

## Deliverables / artifacts

- This ISA spec, complete for the vertical slice (Eth/VLAN/IPv4/IPv6+ext/TCP/UDP).
- A per-instruction semantics table precise enough to implement the golden model
  directly.

## Exit criteria

- Every instruction used by the slice has unambiguous semantics, side effects, and
  error behavior.
- The worked example type-checks against the spec.
- No cycle-count or microarchitecture language leaked in.

## Open questions

- **Decision:** how are IPv6 extension-header chains expressed — `prs.loop` + CAM,
  or an unrolled node chain? (Affects loop-instruction semantics.)
- **TBD:** exact metadata-buffer addressing model (absolute vs base+offset).
- **TBD:** parser-register save/restore mechanism (CSR? shadow file?) — co-decide
  with Phase 4.
- Runthread: fully specify now or stub until deep-processing is in scope?

## References

Blog worked example & instruction classes; patent for TLV/flag-field handling.
See [references.md](references.md).
