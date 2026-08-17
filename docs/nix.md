# Nix development environment

← [Docs index](README.md)

This repo ships a **Nix flake** so everyone gets the *same* tools with one command.
No manual installs of Verilator, poppler, cocotb, etc. — `nix develop` provides them.
The layout mirrors the nearby **xdp2** project's modular `nix/` convention.

## Use it

```sh
nix develop            # enter the dev shell (first run fetches from the binary cache)
rtl-help               # list the available tools
```

If flakes aren't enabled system-wide:

```sh
nix --extra-experimental-features 'nix-command flakes' develop .
```

To enable flakes permanently:

```sh
test -d /etc/nix || sudo mkdir /etc/nix
echo 'experimental-features = nix-command flakes' | sudo tee -a /etc/nix/nix.conf
```

## Layout

```
flake.nix                     # description, inputs (nixpkgs + flake-utils), outputs
flake.lock                    # pinned inputs — commit this for reproducibility
nix/
  packages.nix                # tool groups (docs / rtl / sim / toolchain / riscv / common)
  cva6.nix                    # pinned CVA6 base-core source (fetchFromGitHub)
  cva6-patched.nix            # cva6-parser-src: patched CVA6 source (cacheable derivation)
  cva6-parser/decode.patch    # in-core decode patch (fu_t::PARSER + custom-0/3 routing)
  cva6-parser/issue-ex.patch  # in-core issue/EX/writeback/redirect patch + Flist parser files
  cva6-parser/mmio.patch      # SoC AXI MMIO parser peripheral (packet buf + flow_keys frame + regs, I5)
  cva6-parser/tb-backdoor.patch # sim-only XMR watcher for cva6-parser-test markers (I2/I4)
  cva6-baseline.nix           # cva6-baseline / cva6-parser builders (writeShellApplication)
  cva6-parser-test.nix        # cva6-parser-test: build patched model + run in-core custom-0 test
  cva6-parser-cosim.nix       # cva6-parser-cosim: table-driven in-core packet→flow_keys vs model (I5)
  parser-negative-control.nix # parser-negative-control: STOCK model must trap the custom-0 word (G11, N1)
  parser-trap-v7.nix          # cva6-parser-trap-v7: faulting instr must not corrupt an in-flight parser op (V7/G7, N4)
  parser-trap-v6.nix          # cva6-parser-trap-v6: async interrupt (msip) mid-parse must not corrupt an in-flight parser op (V6/G7, N5)
  parser-baseisa.nix          # cva6-parser-baseisa: RV64GC slice must still retire on the patched core (base-ISA regression, G11, N6)
  parser-config-wb.nix        # cva6-parser-config-wb: FU integrates under the 2nd config cv64a6_imafdc_sv39_wb (G10, N6)
  xdp2.nix                    # pinned xdp2 source (packet corpus, Phase 2)
  model.nix                   # golden-model apps: model-test, model-analyze, model-fuzz, pm-trace
  rtl.nix                     # parser-unit sim/lint/analyze/formal apps (Phase 5/6)
  devshell.nix                # mkShell: tools + CVA6_SRC/CV_SW_PREFIX + banner + rtl-help
  shell-functions/
    help.nix                  # the rtl-help function
scripts/
  cva6-baseline.sh            # body of the cva6-baseline app (Phase 0 sim baseline)
  cva6-parser-test.sh         # in-core custom-0 directed test (assemble ELF + run) (Phase 5)
  cva6-parser-cosim.sh        # table-driven in-core packet→flow_keys co-sim vs model (Phase 6, I5)
  parser-negative-control.sh  # negative control: assemble negctl.S, run on STOCK model, assert trap (G11, N1)
  parser-trap-v7.sh           # V7: assemble parser_trap_v7.S, run on patched model, assert no fault-corruption (G7, N4)
  parser-trap-v6.sh           # V6: assemble parser_trap_v6.S, run on patched model, assert no interrupt-corruption (G7, N5)
  parser-baseisa.sh           # base-ISA regression: assemble base_isa.S, run on patched model, assert RV64GC still retires (G11, N6)
                              # (the 2nd-config app reuses cva6-parser-test.sh with CVA6_TARGET=..._wb — no new script)
  model-test.sh, pm-trace.sh  # bodies of the golden-model apps (Phase 2)
  model-analyze.sh            # cppcheck + gcc -fanalyzer + clang-tidy + ASan/UBSan (Phase 6)
  model-fuzz.sh               # libFuzzer + ASan/UBSan harness runner (Phase 6)
  parser-sim.sh               # body of the parser-sim* apps; PARSER_MODE picks the level
  parser-analyze.sh           # verible + svlint SV static analysis (Phase 6)
  parser-formal.sh            # sv2v + SymbiYosys formal proof runner (Phase 6)
  parser-wrap-test.sh         # cva6_parser_wrap commit/flush state testbench (I1/G2)
  parser-coverage.sh          # Verilator line/toggle + functional cover-point closure (G12, N7)
```

## Runnable apps (`nix run .#<name>`)

One `writeShellApplication` per runner; each puts its tools on `PATH` via
`runtimeInputs` and is shellcheck-clean at build time.

| App | What it does | Phase |
|-----|--------------|------:|
| `cva6-baseline` | build the **stock** CVA6 Verilator model | 0 |
| `cva6-parser` | build the **parser-patched** CVA6 Verilator model (compare vs baseline) | 5 |
| `cva6-parser-test` | build patched model + run the in-core custom-0 directed test | 5 |
| `cva6-parser-cosim` | table-driven in-core packet→flow_keys co-sim vs the model (22/22) | 6 |
| `parser-negative-control` | negative control (G11): the **stock** core must trap the custom-0 parser word (illegal-instruction) | 6 |
| `cva6-parser-trap-v7` | V7 (G7): a faulting instruction (`ecall`) that flushes an in-flight parser op must not corrupt its committed result | 6 |
| `cva6-parser-trap-v6` | V6 (G7): an async machine software interrupt (`msip`) mid-parse that flushes an in-flight parser op must not corrupt its committed result | 6 |
| `cva6-parser-baseisa` | base-ISA regression (G11): a directed RV64GC slice (integer/M/A/F/D/CSR/branches) must still retire correctly on the patched core | 6 |
| `cva6-parser-config-wb` | 2nd-config integration (G10): the parser FU must issue/execute/retire under `cv64a6_imafdc_sv39_wb` (write-back cache) too | 6 |
| `model-test` | golden-model unit + corpus tests | 2 |
| `model-analyze` | cppcheck + gcc `-fanalyzer` + clang-tidy + ASan/UBSan run | 6 |
| `model-fuzz` | libFuzzer + ASan/UBSan on random packets (`FUZZ_SECONDS=`) | 6 |
| `pm-trace` | single-step a parse (optionally `-- x.pcap`) | 2 |
| `parser-sim` | parser-unit smoke test, optimized (`-O3`) | 5 |
| `parser-sim-suite` | directed suite: pos/neg/boundary/corner packets | 6 |
| `parser-sim-trace` | + VCD waveform (`--trace-structs`) → `build/parser/parser.vcd` | 5 |
| `parser-sim-debug` | `-O0 -ggdb` + waveform, for gdb | 5 |
| `parser-lint` | `--lint-only -Wall`, no build (fast strict lint) | 5 |
| `parser-analyze` | extra SV lint: verible + svlint | 6 |
| `parser-formal` | sv2v + SymbiYosys proof of `parser_execute` safety | 6 |
| `parser-wrap-test` | `cva6_parser_wrap` commit/flush state testbench (I1/G2) | 5 |
| `parser-coverage` | Verilator line/toggle + functional cover-point closure (G12); gates on 100% of the §2.6.5 cross-product bins | 6 |

### CVA6: unpatched vs patched, layered for caching

The in-core parser integration is split into small derivations so `/nix/store`
caches each step and only the changed layer rebuilds:

```
cva6-src  (fetched)  ->  cva6-parser-src  (patched source; cheap, cached)
                              |                      |
                              v                      v
                        cva6-baseline           cva6-parser
                        (stock build)           (patched build)
```

`cva6-parser-src` (`nix build .#cva6-parser-src`) applies `nix/cva6-parser/*.patch`
to the pinned source in a cached derivation — editing the patch does **not** force
a Verilator rebuild until you actually build a model. `cva6-baseline` and
`cva6-parser` are the **same** builder (`nix/cva6-baseline.nix`) over the two
sources, into separate work dirs, so you can build both and compare/validate the
patch elaborates with no regression. The `.patch` is a plain unified diff, so it
reviews independently of the fetched tree.

The `parser-sim*` targets share **one** script body (`scripts/parser-sim.sh`,
selected by `PARSER_MODE`) so build flags can't drift between debug levels — the
pattern to copy when a phase needs several build variants. See
[phase-5-rtl.md](phase-5-rtl.md) §5.6. The verification targets (`*-analyze`,
`*-fuzz`, `parser-formal`, `parser-sim-suite`) are detailed in
[phase-6-verification.md](phase-6-verification.md).

`flake.nix` stays thin: it imports `nix/packages.nix` and `nix/devshell.nix` and
exposes `devShells.default` and a `formatter` (`nix fmt`). New modules (build
derivations, script runners) become their own `nix/<name>.nix` and are wired into
`outputs` — same pattern xdp2 uses for its many build/bench modules.

## What's in the shell (and why)

Grouped in [`nix/packages.nix`](../nix/packages.nix) by the phase they serve:

| Group | Tools | For |
|-------|-------|-----|
| **docs** | `poppler-utils` (pdftotext/pdftoppm/pdfimages), `python3` | patent-figure extraction, `tools/bitgen/bitgen.py`, scripts (today) |
| **rtl** | `verilator`, `verible`, `svlint`, `gtkwave`, `yosys` | SystemVerilog design + lint (Phase 5) |
| **sim** | `python3` + `cocotb`, `pytest`, `scapy` | co-simulation testbenches + corpus (Phase 2/6) |
| **toolchain** | `spike`, `qemu` | RISC-V ISA sim + emulation (Phase 7) |
| **riscv** | `pkgsCross.riscv64-embedded` `gcc`/`binutils` | bare-metal RISC-V cross compiler (CVA6 sim, `.insn` tests) |
| **common** | `git`, `gh`, `gnumake`, `gcc`, `ripgrep`, `jq`, `curl` | everyday work |

The RISC-V cross toolchain is the **bare-metal** (`riscv64-none-elf`, newlib)
target — CVA6's Verilator sim runs freestanding ELFs with no OS. It is fully
cached in `cache.nixos.org` (no source build). The prefix is `riscv64-none-elf-`
(exported as `$CV_SW_PREFIX`).

## Extending

- **Add a tool:** drop it into the right group in `nix/packages.nix`. Verify the
  attribute name first with `nix eval --raw nixpkgs#<attr>.pname`.
- **Add a buildable binary / derivation:** create `nix/<thing>.nix` returning a
  derivation, import it in `flake.nix`, and expose it under `packages.<name>` so
  `nix build .#<name>` works.
- **Add a script:** package it as a `pkgs.writeShellApplication` in
  `nix/<name>.nix` (put its tools in `runtimeInputs`; keep the body in
  `scripts/<name>.sh` and `readFile` it). This sets up PATH reproducibly *and*
  runs `shellcheck` at build time, so a broken script fails the build. Expose it
  under `apps.<name>` (run with `nix run .#<name>`) — see `nix/cva6-baseline.nix`.
- Always **commit `flake.lock`** so builds are reproducible; bump inputs with
  `nix flake update` when you intend to.

## Rationale

- **One environment for all contributors** — no "works on my machine"; the pinned
  `flake.lock` makes it byte-identical.
- **Grows with the project** — we start with the docs/PDF tooling we use today and
  extend the same modular structure as the model, RTL, and toolchain phases land.
- **Matches xdp2** — same conventions as the sibling project, so context transfers.
