# nix/packages.nix
#
# Tool definitions for the rtl-fun dev shell, grouped by what they're for so it
# is obvious which phase each tool serves (see docs/nix.md and the phase docs).
#
# Usage in flake.nix:
#   packages = import ./nix/packages.nix { inherit pkgs; };
#   ... packages.allPackages ...
#
{ pkgs }:

let
  # Python environment for scripts + HDL verification.
  #  - cocotb : Python co-simulation testbenches (Phase 6)
  #  - pytest : test runner
  #  - scapy  : build/mutate the packet corpus (Phase 2)
  # Pinned to 3.13: cocotb 2.0.1 does not yet support the current default (3.14).
  # TODO(python): nixpkgs default python3 is now 3.14.x — bump this back to the
  # latest provided Python once a cocotb supporting it ships, and drop the pin.
  # Re-check: nix eval nixpkgs#python3Packages.cocotb.version  (see docs/environment.md)
  pythonEnv = pkgs.python313.withPackages (ps: [
    ps.cocotb
    ps.pytest
    ps.scapy
  ]);

  # Docs & reference tooling — what we use *today* (PDF extraction, diagrams).
  docsTools = [
    pkgs.poppler-utils # pdftotext / pdftoppm / pdfimages (patent figures)
    pythonEnv # docs/analysis/bitgen.py and other scripts
  ];

  # RTL design & lint (Phase 5).
  rtlTools = [
    pkgs.verilator # fast SystemVerilog simulation (Phase 5/6)
    pkgs.verible # SystemVerilog formatter + lint
    pkgs.svlint # SystemVerilog linter
    pkgs.gtkwave # waveform viewer
    pkgs.yosys # synthesis / elaboration sanity (optional)
  ];

  # ISA simulation & toolchain (Phase 7).
  toolchainTools = [
    pkgs.spike # RISC-V ISA simulator (golden ISA reference)
    pkgs.qemu # RISC-V functional emulation
    # RISC-V cross GCC (Phase 7) — enable when the toolchain work starts; may
    # build from source the first time:
    #   pkgs.pkgsCross.riscv64-embedded.buildPackages.gcc
  ];

  # Common utilities used everywhere.
  common = [
    pkgs.git
    pkgs.gh
    pkgs.gnumake
    pkgs.gcc
    pkgs.ripgrep
    pkgs.jq
    pkgs.curl
    pkgs.coreutils
    pkgs.bashInteractive
  ];

  allPackages = docsTools ++ rtlTools ++ toolchainTools ++ common;
in
{
  inherit pythonEnv docsTools rtlTools toolchainTools common allPackages;
}
