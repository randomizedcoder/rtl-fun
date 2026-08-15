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
  packages.nix                # tool groups (docs / rtl / sim / toolchain / common)
  devshell.nix                # mkShell: tools + banner + rtl-help
  shell-functions/
    help.nix                  # the rtl-help function
```

`flake.nix` stays thin: it imports `nix/packages.nix` and `nix/devshell.nix` and
exposes `devShells.default` and a `formatter` (`nix fmt`). New modules (build
derivations, script runners) become their own `nix/<name>.nix` and are wired into
`outputs` — same pattern xdp2 uses for its many build/bench modules.

## What's in the shell (and why)

Grouped in [`nix/packages.nix`](../nix/packages.nix) by the phase they serve:

| Group | Tools | For |
|-------|-------|-----|
| **docs** | `poppler-utils` (pdftotext/pdftoppm/pdfimages), `python3` | patent-figure extraction, `bitgen.py`, scripts (today) |
| **rtl** | `verilator`, `verible`, `svlint`, `gtkwave`, `yosys` | SystemVerilog design + lint (Phase 5) |
| **sim** | `python3` + `cocotb`, `pytest`, `scapy` | co-simulation testbenches + corpus (Phase 2/6) |
| **toolchain** | `spike`, `qemu` | RISC-V ISA sim + emulation (Phase 7) |
| **common** | `git`, `gh`, `gnumake`, `gcc`, `ripgrep`, `jq`, `curl` | everyday work |

RISC-V **cross-GCC** is left commented in `nix/packages.nix` until the Phase-7
toolchain work starts (it can build from source on first use); enable the
`pkgsCross.riscv64-embedded.buildPackages.gcc` line then.

## Extending

- **Add a tool:** drop it into the right group in `nix/packages.nix`. Verify the
  attribute name first with `nix eval --raw nixpkgs#<attr>.pname`.
- **Add a buildable binary / derivation:** create `nix/<thing>.nix` returning a
  derivation, import it in `flake.nix`, and expose it under `packages.<name>` so
  `nix build .#<name>` works.
- **Add a script runner / check:** same pattern under `apps.<name>` (run with
  `nix run .#<name>`) or `checks.<name>` (run with `nix flake check`).
- Always **commit `flake.lock`** so builds are reproducible; bump inputs with
  `nix flake update` when you intend to.

## Rationale

- **One environment for all contributors** — no "works on my machine"; the pinned
  `flake.lock` makes it byte-identical.
- **Grows with the project** — we start with the docs/PDF tooling we use today and
  extend the same modular structure as the model, RTL, and toolchain phases land.
- **Matches xdp2** — same conventions as the sibling project, so context transfers.
