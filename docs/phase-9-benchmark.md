# Phase 9 — Benchmark

← [Phase 8](phase-8-fpga.md) · [Docs index](README.md) · [Overview](00-overview.md)

## Objective

Quantify the win. Measure **cycles per packet** and instruction counts for the
vertical slice, comparing parser instructions against plain RV64 code and a Linux
`flow_dissector`-style baseline — and test the central thesis that a wide packet
window (Risk R1) is what unlocks the speedup.

## Inputs / prerequisites

- Phase 8 FPGA build with cycle/IPC counters (and/or Phase 6 cycle-accurate sim).
- Phase 7 toolchain (to build all parser variants).
- Phase 2 corpus (identical inputs across all implementations).

## Design detail

### 9.1 Implementations under test

| # | Implementation | Purpose |
|---|----------------|---------|
| A | Idiomatic RV64 C flow parser | naive software baseline |
| B | Hand-optimized RV64 (unrolled, minimal loads) | strong software baseline |
| C | Parser instructions, **L1D** packet source | isolates instruction-count win |
| D | Parser instructions, **wide packet window** | the full thesis (Risk R1) |
| — | Linux `flow_dissector` (reference numbers) | context vs production software |

C-vs-D is the key experiment: if D ≫ C, the bandwidth thesis holds; if C ≈ D, the
win was never memory-bound and the wide window isn't worth its cost.

### 9.2 Metrics

- **cycles/packet** (headline) — hardware cycle counter (Phase 8) or cycle-accurate
  sim, per packet class.
- **static instruction count** per parsed header — expect ≈15:1 parser-vs-integer
  for Internet protocols (blog reference).
- **IPC** — parser IPC is lower (~0.4 reference) but does far more per instruction;
  report it honestly to show *why* the net throughput still wins (~4.3× reference).
- **area / timing** — parser-unit LUT/FF/BRAM and Fmax from Phase 8 (the cost side
  of the trade).

### 9.3 Methodology

- Identical corpus for every implementation; report per-class *and* aggregate.
- Warm vs cold packet buffer stated explicitly.
- Multiple runs; report distribution, not just a mean.
- Separate parse *compute* from packet *ingress* so we measure the parser, not the
  MAC/DMA.
- Reproducible harness in `bench/` with pinned tool versions.

### 9.4 Reporting

```
                 cycles/packet   (lower is better)   — illustrative shape
 A  RV64 naive        ██████████████████  ~100
 B  RV64 optimized    ███████████         ~60
 C  parser (L1D)      ████                 ~15
 D  parser (wide)     ██                   ~5
```

Present as a table + bar chart, with instruction-count and IPC alongside, and a
plain-language verdict on whether the thesis held. **Numbers above are the blog's
illustrative targets, not results** — real figures come from the FPGA/sim runs.

### 9.5 Feedback loop

Findings feed back into the ISA (Risk R6 — granularity): if a class of headers is
still integer-bound, that's a candidate for a new/adjusted parser instruction. Log
these as proposals; the ISA is expected to iterate.

## Step-by-step tasks

1. Implement variants A–D and wire up the `flow_dissector` reference.
2. Build the `bench/` harness (same corpus, per-class + aggregate, N runs).
3. Collect cycles/packet, instruction counts, IPC (from Phase 8 counters / sim).
4. Pull area/timing from the Phase-8 vendor reports.
5. Run the C-vs-D experiment; state whether the bandwidth thesis held.
6. Write the results report; file ISA-iteration proposals from what you learned.

## Deliverables / artifacts

- `bench/` harness + raw data.
- A results report: tables, charts, and a verdict on speedup + the wide-window
  thesis.
- A short list of ISA-improvement proposals for the next iteration.

## Exit criteria

- cycles/packet, instruction count, and IPC reported for A–D + baseline over the
  full corpus.
- The C-vs-D (bandwidth) question is answered with data.
- Parser-unit area/timing documented.

## Open questions

- **TBD:** which packet classes to weight (traffic-mix assumptions).
- How to fairly represent `flow_dissector` (kernel context vs bare-metal loop)?
- **Decision:** measure on FPGA, cycle-accurate sim, or both? (Recommend both —
  sim for coverage, FPGA for the headline number.)

## References

Blog performance section (15:1, IPC 0.4 vs 1.4, ~4.3× speedup); flow_dissector.
See [references.md](references.md).
