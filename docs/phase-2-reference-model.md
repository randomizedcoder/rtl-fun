# Phase 2 — Golden reference model

← [Phase 1](phase-1-isa-spec.md) · [Docs index](README.md) · [Phase 3 »](phase-3-encoding.md)

## Objective

Turn the [ISA spec](phase-1-isa-spec.md) into an **executable golden model** in C —
the single source of architectural truth. Everything downstream (RTL, sims, the
toolchain) is verified *against this model*, not against prose.

> Each `execute_*` below implements, 1:1, a routine in the normative
> [**Phase-1 operational semantics**](phase-1-isa-semantics.md) — that doc's
> pseudocode, shared primitives, parser codes, and `Common_End_of_Node` are the
> contract this model must reproduce bit-for-bit (see its
> [§7 Phase-2 binding](phase-1-isa-semantics.md#7-phase-2-binding)).

## Inputs / prerequisites

- Phase 1 ISA spec (semantics for every instruction).
- Phase 0 slice + `flow_keys` output struct.

## Design detail

### 2.1 Shape of the model

A small C library, `libparsermodel`, that models parser state and executes each
instruction as a pure function with explicit side effects:

The model mirrors the patent register file and the **two-level** state (protocol
header vs data header) — not the blog's single-cursor simplification. See
[Phase 1 §1.1–1.2](phase-1-isa-spec.md).

```c
typedef struct { uint32_t off, len; } hdr_t;      /* CurHdr / DataHdr */

typedef struct {
    const uint8_t *pkthdrbase;
    uint32_t all_len, parse_len;   /* PktLen.AllLen / ParseLen */
    hdr_t    cur;                  /* CurHdr  (offset+length)  */
    hdr_t    dat;                  /* DataHdr (offset+length)  */
    uint32_t databound;            /* DataBndLoop.DataBound (init 0xFFFFFFFF) */
    int32_t  loop;                 /* DataBndLoop.Loop (address or parser code) */
    uint64_t accum, flags;         /* Accum / Flags */
    int32_t  next;                 /* Next (address or parser code) */
    uint8_t  encap;                /* Counters.Encap */
    uint8_t  cntr[7];              /* Counters.Cntr1..7 */
    uint8_t *meta_common, *meta_frame;   /* common metadata + current frame */
    int      code;                 /* ParserExitCode.Error (parser code, negative) */
} pstate;

/* one execute_* per instruction, mirroring Phase 1 semantics exactly.
   pcurptr = pkthdrbase + cur.off ; pdatptr = pkthdrbase + dat.off  */
int execute_load(pstate*, unsigned sz, int x, int e, unsigned shift,
                 unsigned blen, int32_t disp);          /* bounds + load-sets-length */
int execute_lensetmin(pstate*, unsigned sz, unsigned pos, unsigned mul, unsigned min);
int execute_cmpi(pstate*, int op, unsigned sz, unsigned pos, uint32_t val,
                 uint32_t mask, int on_false);          /* eq/ne/lt/le/gt/ge; stop/node/sub/fail */
int execute_cam(pstate*, unsigned sz, unsigned pos, int f, unsigned share,
                int disp_kind, int stp);                /* →accum/next/jump/loop */
int execute_store(pstate*, unsigned sz, int frame, unsigned pos, int sind, uint32_t off);
int common_end_of_node(pstate*);   /* Loop-first, then Next; overlay/encap */
/* ...move, length family, tlvfastloop, flagsloop, counters, runthread... */
```

Parser codes are **negative bytes** (`OKAY_RET`, `STOP_OKAY`, `STOP_SUB_NODE_OKAY`,
`STOP_LENGTH`, `STOP_TLV_LENGTH`, `STOP_LOOP_CNT`, `STOP_OPTION_LIMIT`,
`STOP_PADDING_LIMIT`, …) with `STOP_FAIL(−12)` splitting normal/abnormal — the
model's `code` output must use them so Phase-6 co-sim compares real status.

The model is **bit-exact and deterministic**: the same rounding, the same
bounds/length side effects, the same error codes the RTL must reproduce.

### 2.2 Parse programs

The vertical slice's parser is expressed as data/functions calling `execute_*`
in the order of the Phase-1 worked example (Ethernet → VLAN → IPv4/IPv6+ext →
TCP/UDP), producing a `flow_keys`. This doubles as the reference *program* the RTL
runs.

### 2.3 Packet corpus (the hard part)

The model's value is only as good as its inputs. Build a corpus that is
**deliberately hostile**, because parsers fail on malformed input (Risk R4):

Well-formed:
- IPv4/IPv6 × TCP/UDP, with and without VLAN (incl. stacked VLAN).
- IPv6 with 0..N extension headers.
- Min-size and jumbo frames; various IHL values (5..15).

Malformed / adversarial:
| Case | What it probes |
|------|----------------|
| IPv4 IHL = 0 | below-minimum length handling |
| IPv4 IHL = 15 but packet truncated | length vs `pktlen` bound |
| IPv6 ext-header pointing past EOF | loop bound / OOB load |
| TLV length = 0 | non-advancing loop / infinite-loop guard |
| TLV length > remaining | OOB advance |
| VLAN stacked to absurd depth | loop bound |
| 1-byte / N-byte truncated packet | every load's bounds check |
| Unaligned headers | byte-aligner correctness (shared w/ RTL) |
| EtherType lying about payload | `cmpi.fail` version guard |
| Nested encapsulation | cursor advance / node dispatch |

Each corpus entry is stored with metadata: raw bytes + expected `flow_keys` +
expected exit status. Generate with a mix of hand-authored cases and a fuzzer.

### 2.4 Role in verification

```
        packet corpus
             │
     ┌───────┴────────┐
     ▼                ▼
 C golden model   RTL (Phase 6)
     │                │
  flow_keys A     flow_keys B
     │                │
     └──────┬─────────┘
            ▼
     bit-exact compare  (mismatch ⇒ bug in RTL, model, or spec)
```

### 2.5 Implementation status (this repo)

The model is built as a **decoded-instruction interpreter**, not direct C control
flow: the program is a table of decoded `instr`s (`program.c`) that a PC loop
(`pm_run`) walks, so the *same* table is what Phase 3 encodes to bits and Phase 6
replays on RTL. Each opcode dispatches to one `execute_*` mirroring the Phase-1
semantics 1:1.

Files (`model/`):
- `libparsermodel/parser.{h,c}` — machine state (`pstate`), the parser-code enum,
  `pm_extract_subreg`, every `execute_*`, `common_end_of_node`, and `pm_run`.
- `libparsermodel/program.c` — the parse program as a decoded table plus its CAM
  tables. Nodes: ether, vlan (802.1Q/802.1ad, self-looping for stacking), ipv4,
  ipv6, ip6ext (HBH/routing/dest-opts, `len=(ExtLen+1)*8`), ip6frag (fixed 8),
  done ("no next header" → clean stop), tcp, udp. IPv6 next-header routing uses
  its own CAM table (`share=3`) so it never pollutes IPv4's next-protocol table.
- `libparsermodel/pcap.{h,c}` — minimal classic-pcap reader (first packet).
- `test/` — a dependency-free assert harness (`test.h`) + unit, malformed, and
  corpus tests, including a robustness sweep over the whole corpus.

**Coverage:** Ethernet · VLAN (single + stacked QinQ) · IPv4 (incl. options via
IHL) · IPv6 (0..N hop-by-hop / routing / fragment / dest-opts extension headers) ·
TCP · UDP → `flow_keys`. Notably, VLAN and the IPv6 ext-header chain needed no new
opcodes — only new nodes and CAM tables (the ext-header loop is expressed as CAM
transitions bounded by the node-count guard).

**Corpus:** rather than hand-rolling packets, the corpus is the
[xdp2](https://github.com/randomizedcoder/xdp2) `samples/proto_audit/pcap_templates`
set (378 protocol pcaps), **pinned by commit + narHash** via `nix/xdp2.nix` so the
vectors are reproducible. The Nix wrapper injects that path as `CORPUS_DIR`.
The whole-corpus sweep runs every Ethernet pcap (306 of 378) and requires each to
terminate with a valid parser code — all do, no crashes/hangs.

**Deferred to a later slice:** true TLV *extraction* loops (DataHdr/DataBound with
`camjumptlvloop`, e.g. extracting individual IPv6 options or GRE flag-fields) and
tunnel/encapsulation protocols (GRE/GTP/VXLAN). `flow_keys` needs neither.

**Run:** `nix run .#model-test` (unit + corpus smoke tests, corpus auto-pinned).
Debug a single parse with `nix run .#pm-trace [-- some.pcap]`, which prints the
machine state before every instruction (see [tools/README](../tools/README.md)).

> Regression found & fixed during bring-up: on a node transition the `Next`
> register held a return code (`P_STOP_OKAY = 0xFFFFFFFC`) whose low bits fall
> inside `NEXT_CTRL_MASK`; `execute_camnext`/`execute_nextnode` were OR-ing those
> stale bits into the target, spuriously setting the ENCAP/OVERLAY control bits so
> `Common_End_of_Node` took the overlay path and never advanced `CurHdr.Offset`.
> Control bits must come from the *target encoding*, never a carried-over code.

## Step-by-step tasks

1. Define `pstate` + the status-code enum matching Phase 1 §1.6.
2. Implement one `execute_*` per instruction, with side effects & traps.
3. Encode the slice's parse program on top of `execute_*`.
4. Build the corpus generator: hand cases + fuzzer; emit `{bytes, flow_keys, status}`.
5. Self-check: run the model over the corpus; hand-verify a sample of outputs.
6. Freeze a serialized corpus format that Phase 6 can replay in cocotb.

## Deliverables / artifacts

- `model/libparsermodel` (C) + unit tests. ✅
- Pinned reproducible corpus (`nix/xdp2.nix` → xdp2 `proto_audit`), wired as
  `nix run .#model-test`. ✅
- `tools/pm-trace` single-step debugger. ✅
- Well-formed (VLAN/QinQ, IPv6 ext headers) + hostile/malformed (§2.3) vectors
  with expected outputs, plus a whole-corpus robustness sweep. ✅

## Exit criteria

- ✅ **Directed:** model parses `eth [+ VLAN] + ipv4/ipv6 [+ ext hdrs] + tcp/udp`
  producing the expected `flow_keys` + exit status.
- ✅ **Hostile:** every §2.3 malformed case (IHL=0, IHL=15 truncated, ext header
  past EOF, absurd VLAN nesting, truncation, version/EtherType lies) terminates
  with the expected parser code — no crashes, no hangs (loop + node guards work).
- ✅ **Corpus:** all 306 Ethernet pcaps in the pinned corpus terminate cleanly
  (`nix run .#model-test` → all checks green).
- The model, not the prose, is treated as the semantic authority from here on.

## Open questions

- **Decision:** model language stays C (matches eventual DPI-C co-sim & toolchain);
  confirm no reason to prefer Rust/Python.
- **TBD:** corpus size / coverage target for "done" (coordinate with Phase 6).
- How closely should the model mimic the *encoding* (Phase 3) vs. stay at the
  semantic level? (Recommendation: semantic now, add an encoder/decoder in Phase 3.)

## References

Patent for TLV/flag-field edge cases; flow_dissector for expected `flow_keys`
semantics. See [references.md](references.md).
