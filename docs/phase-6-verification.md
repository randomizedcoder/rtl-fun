# Phase 6 — Verification

← [Phase 5](phase-5-rtl.md) · [Docs index](README.md) · [Phase 7 »](phase-7-toolchain.md)

## Objective

Prove the [RTL](phase-5-rtl.md) is **bit-identical to the golden model**
([Phase 2](phase-2-reference-model.md)) across the whole corpus — including every
malformed packet — via co-simulation, directed tests, and fuzzing. This is the
correctness gate for the project.

## Inputs / prerequisites

- Phase 5 RTL running in Verilator.
- Phase 2 golden model + serialized corpus (`{bytes, flow_keys, status}`).

## Design detail

### 6.1 Co-simulation harness

```
                 corpus vector {bytes, expected_flow_keys, expected_status}
                          │
             ┌────────────┴─────────────┐
             ▼                          ▼
     cocotb drives RTL           C golden model
     (Verilator DUT)            (DPI-C or separate run)
             │                          │
        flow_keys_rtl              flow_keys_model
        status_rtl                 status_model
             └────────────┬─────────────┘
                          ▼
                 assert bit-exact equality
                 (fields AND exit status)
```

Use **cocotb** to load each packet into `parser_pktbuf`, set `pktbase/pktlen`,
launch the parse program, and read back the metadata buffer + status. Compare to
the model — ideally the model linked in via **DPI-C** so both run on identical
inputs in one process.

### 6.2 Test tiers

1. **Directed** — the Phase-1 worked example and one clean packet per protocol
   combination; easiest to debug first.
2. **Corpus replay** — every well-formed and malformed vector from Phase 2.
3. **Fuzzing** — randomized/mutated packets fed to model and RTL simultaneously;
   any output or status divergence is a bug (in RTL, model, or the spec — all
   worth finding). Emphasize malformed structure (Risk R4): truncation, bad
   lengths, zero-length TLVs, deep VLAN/ext-header stacks.

### 6.3 What we assert

- `flow_keys` fields bit-exact.
- Exit **status** matches (complete vs each error class) — a parser that gets the
  right key but the wrong bounds/exit behavior is still wrong.
- **Liveness:** the RTL always terminates — loop guards prevent hangs on
  zero-length/looping inputs (checked with a cycle watchdog in the TB).

### 6.4 Coverage

- **Functional coverage:** every instruction, every qualifier (`.stp/.fail`),
  every CAM sub-table, each error-exit class, min/max IHL, N ext-headers, stacked
  VLAN.
- **Code/toggle coverage** via Verilator where practical.
- Define a numeric target (**TBD**, coordinate w/ Phase 2 corpus size) that gates
  "done."

### 6.5 CI

- Run directed + corpus tiers on every push; a bounded fuzz budget nightly.
- Fail the build on any mismatch, any watchdog timeout, or coverage regression.
- Pin tool versions (Verilator/cocotb) for reproducibility.

## Step-by-step tasks

1. Stand up the cocotb testbench around the Verilator DUT.
2. Link the golden model via DPI-C (or a compare harness over serialized outputs).
3. Implement the three test tiers (directed → corpus → fuzz).
4. Add field + status assertions and the liveness watchdog.
5. Wire functional/code coverage and set the target.
6. Add CI: per-push directed+corpus, nightly fuzz; fail on mismatch/timeout.

## Deliverables / artifacts

- `tb/` cocotb testbench + DPI-C bridge to the model.
- A fuzzing harness and a coverage report.
- CI config that gates merges on RTL == model.

## Exit criteria

- RTL == golden model (fields **and** status) over the entire corpus.
- Fuzzing finds no divergence within the budget; no watchdog timeouts.
- Coverage target met.

## Open questions

- **Decision:** DPI-C in-process compare vs. offline output diff. (Recommend
  DPI-C — same inputs, no serialization skew.)
- **TBD:** coverage % and fuzz budget that define "signed off."
- Do we also cross-check against Spike once Phase 7 lands? (Nice-to-have.)

## References

cocotb, Verilator; Phase 2 model/corpus. See [references.md](references.md).
