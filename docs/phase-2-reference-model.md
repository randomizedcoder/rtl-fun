# Phase 2 — Golden reference model

← [Phase 1](phase-1-isa-spec.md) · [Docs index](README.md) · [Phase 3 »](phase-3-encoding.md)

## Objective

Turn the [ISA spec](phase-1-isa-spec.md) into an **executable golden model** in C —
the single source of architectural truth. Everything downstream (RTL, sims, the
toolchain) is verified *against this model*, not against prose.

## Inputs / prerequisites

- Phase 1 ISA spec (semantics for every instruction).
- Phase 0 slice + `flow_keys` output struct.

## Design detail

### 2.1 Shape of the model

A small C library, `libparsermodel`, that models parser state and executes each
instruction as a pure function with explicit side effects:

```c
typedef struct {
    const uint8_t *pktbase;
    uint32_t pktlen;
    uint32_t pcurptr;     /* offset from pktbase */
    uint32_t pcurhdr;
    uint64_t paccum;
    uint32_t pnext;       /* next node id */
    uint8_t  meta[META_SZ];
    int      status;      /* OK / EXIT_COMPLETE / EXIT_OOB / EXIT_LEN / EXIT_CMP ... */
} pstate;

/* one execute_* per instruction, mirroring Phase 1 semantics exactly */
int  execute_load (pstate*, unsigned width, int32_t disp);   /* bounds + implicit length */
int  execute_lensetmin_n(pstate*, unsigned nib, unsigned mul, unsigned min);
int  execute_cmpi_n_fail(pstate*, unsigned nib, unsigned imm);
int  execute_cam  (pstate*, unsigned width, unsigned field, unsigned subtbl, int stp);
int  execute_store(pstate*, unsigned width, uint32_t moff);
/* ...move, loop, runthread... */
```

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

## Step-by-step tasks

1. Define `pstate` + the status-code enum matching Phase 1 §1.6.
2. Implement one `execute_*` per instruction, with side effects & traps.
3. Encode the slice's parse program on top of `execute_*`.
4. Build the corpus generator: hand cases + fuzzer; emit `{bytes, flow_keys, status}`.
5. Self-check: run the model over the corpus; hand-verify a sample of outputs.
6. Freeze a serialized corpus format that Phase 6 can replay in cocotb.

## Deliverables / artifacts

- `model/libparsermodel` (C) + unit tests.
- `corpus/` with well-formed + malformed vectors and expected outputs.
- A stable, documented corpus file format.

## Exit criteria

- Model parses the entire corpus and produces expected `flow_keys` + status,
  including every malformed case (no crashes, no hangs — loop guards work).
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
