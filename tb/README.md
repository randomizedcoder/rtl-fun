# tb/ — cocotb / Verilator testbench (Phase 6)

Co-simulation harness: drive the RTL parser unit and the golden C
[`model/`](../model/README.md) over the same [`corpus/`](../corpus/README.md),
compare outputs cycle-by-transaction, and fail on any divergence. Directed tests
plus fuzz campaigns, with emphasis on malformed packets.

Runs under `nix develop` (cocotb 2.0.1, Verilator 5.050).

*Empty until Phase 6. See [`docs/phase-6-verification.md`](../docs/phase-6-verification.md).*
