# Environment & versions

Phase 0 deliverable: a reproducible record of the tools the project builds on.
Everything below is provided by the Nix flake (`nix develop`) — see
[nix.md](nix.md). Versions are pinned by [`flake.lock`](../flake.lock); this table
is the human-readable snapshot.

## Captured

- **Date:** 2026-08-14
- **nixpkgs:** `nixos-unstable`, pinned in `flake.lock` (rev of 2026-08-12)
- **Host:** Linux x86_64

## Tool versions (from `nix develop`)

| Tool | Version | Phase | Role |
|------|---------|------:|------|
| Verilator | 5.050 (2026-07-01, rev v5.050) | 5/6 | SystemVerilog simulation |
| verible-verilog-format | v0.0-4023-gc1271a00 | 5 | SV formatter + lint |
| svlint | 0.9.5 | 5 | SV linter |
| Yosys | 0.67 | 5 | elaboration / synthesis sanity |
| GTKWave | 3.3.128 | 6 | waveform viewer |
| Spike | 1.1.1-dev | 7 | golden RISC-V ISA simulator |
| QEMU (riscv64) | 11.0.3 | 7 | functional emulation |
| Python | 3.13.15 | 2/6 | scripts + cocotb |
| cocotb | 2.0.1 | 6 | Python co-sim testbenches |
| scapy | 2.7.0 | 2 | packet-corpus generation |
| pytest | 9.1.1 | 6 | test runner |
| poppler-utils (pdftotext) | 26.06.0 | docs | patent PDF extraction |
| GCC | 15.3.0 | — | golden C model host compiler |
| GNU Make | 4.4.1 | — | build driver |

## Known follow-ups

- **Python pin.** `nix/packages.nix` pins `python313` only because cocotb did not
  yet support Python 3.14. nixpkgs' current default `python3` is already **3.14.7**.
  Bump `pythonEnv` back to the latest nixpkgs Python once a cocotb that supports it
  ships — re-check with `nix eval nixpkgs#python3Packages.cocotb.version` and drop
  the explicit pin.
- **RISC-V cross-GCC.** Left commented in `nix/packages.nix`; enable at Phase 7
  (`.insn` macros / toolchain work). May build from source the first time.
- **CVA6 checkout.** Base-core commit hash to be recorded here once the stock CVA6
  Verilator sim baseline is stood up (Phase 0 task 4 / Phase 4).

## How to regenerate this snapshot

Enter the shell and print versions:

```sh
nix develop --command bash -c '
  verilator --version; svlint --version; yosys --version
  spike --help 2>&1 | head -1; qemu-system-riscv64 --version | head -1
  python3 --version; python3 -c "import cocotb, scapy; print(cocotb.__version__, scapy.__version__)"
  pdftotext -v 2>&1 | head -1; gcc --version | head -1; make --version | head -1
'
```
