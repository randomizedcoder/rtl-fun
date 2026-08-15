# model/ — golden reference model (Phase 2)

The C reference implementation of the parser-instruction ISA — the single
architectural source of truth that Phase-6 co-simulation checks the RTL against.
See [docs/phase-2-reference-model.md](../docs/phase-2-reference-model.md) for the
design and [docs/phase-1-isa-semantics.md](../docs/phase-1-isa-semantics.md) for
the normative per-instruction semantics each `execute_*` implements 1:1.

## Layout

```
model/
  libparsermodel/
    parser.h    machine state (pstate), parser-code enum, decoded-instr + API
    parser.c    pm_extract_subreg, every execute_*, common_end_of_node, pm_run
    program.c   the parse program as a decoded-instruction table + CAM tables
                (Ethernet -> VLAN -> IPv4/IPv6 -> IPv6 ext hdrs -> TCP/UDP)
    pcap.{h,c}  minimal classic-pcap reader (first packet of a capture)
  test/
    test.h        dependency-free assert harness (EXPECT/EXPECT_EQ + tally)
    test_main.c   directed unit tests + corpus smoke tests
```

## Design

A **decoded-instruction interpreter**: `program.c` is a table of decoded
instructions that `pm_run` walks with a PC loop; each opcode dispatches to an
`execute_*`. The same table is what Phase 3 encodes to bits and Phase 6 runs on
RTL — so the model and the silicon share one program, not two hand-kept copies.

## Build & run

```sh
nix run .#model-test        # unit + corpus smoke tests (corpus auto-pinned)
```

`model-test` compiles the library + tests and runs them. The packet corpus is the
pinned xdp2 `proto_audit` pcap set (`nix/xdp2.nix`), injected as `CORPUS_DIR`;
override `CORPUS_DIR` to point at your own captures. To debug a parse step by
step use [`nix run .#pm-trace`](../tools/README.md).

Direct build (from the repo root):

```sh
gcc -std=c11 -O2 -Wall -Wextra -I model/libparsermodel \
    model/test/test_main.c \
    model/libparsermodel/parser.c \
    model/libparsermodel/program.c \
    model/libparsermodel/pcap.c -o pm-test
CORPUS_DIR=/path/to/pcap_templates ./pm-test
```

## Scope

Covered: Ethernet, 802.1Q/802.1ad VLAN (incl. stacked QinQ), IPv4 (with options),
IPv6 (with hop-by-hop / routing / fragment / dest-opts extension headers), TCP,
UDP → `flow_keys`; plus the §2.3 hostile/malformed matrix and a whole-corpus
robustness sweep (all Ethernet pcaps terminate cleanly).

Deferred to a later slice: true TLV *extraction* loops (DataHdr/DataBound with
`camjumptlvloop`, e.g. per-option extraction, GRE flag-fields) and tunnel
protocols (GRE/GTP/VXLAN). `flow_keys` needs neither.
