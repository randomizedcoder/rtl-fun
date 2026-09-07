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
    pythonEnv # tools/bitgen/bitgen.py and other scripts
  ];

  # RTL design & lint (Phase 5).
  rtlTools = [
    pkgs.verilator # fast SystemVerilog simulation (Phase 5/6)
    pkgs.verible # SystemVerilog formatter + lint
    pkgs.svlint # SystemVerilog linter
    pkgs.gtkwave # waveform viewer
    pkgs.yosys # synthesis / elaboration sanity (optional)
  ];

  # ISA simulation & toolchain (Phase 7 + CVA6 baseline).
  toolchainTools = [
    pkgs.spike # RISC-V ISA simulator (golden ISA reference)
    pkgs.qemu # RISC-V functional emulation
  ];

  # RISC-V cross toolchain (bare-metal / newlib) — needed to compile the
  # CVA6 sim test programs (hello-world) and, later, the .insn parser tests.
  #
  # Bare-metal (riscv64-none-elf, newlib) rather than the linux-gnu cross used
  # in ~/Downloads/xdp2: CVA6's Verilator sim runs freestanding ELFs with no OS.
  # Same "native cross-compiler on x86_64" idea as xdp2's crossSystem pattern,
  # just the embedded target. Fully cached in cache.nixos.org (no source build).
  # Toolchain prefix is `riscv64-none-elf-` (pass to CVA6 as CV_SW_PREFIX).
  riscvToolchain = [
    pkgs.pkgsCross.riscv64-embedded.buildPackages.gcc
    pkgs.pkgsCross.riscv64-embedded.buildPackages.binutils
  ];

  # FPGA board bring-up (Phase 8) — Sipeed Tang Mega 138K Pro / Gowin GW5AST-138.
  #
  # openFPGALoader only PROGRAMS the board; it does not build bitstreams. Bitstream
  # generation needs Gowin EDA, which runs in the microVM (nix/gowin-vm.nix) because
  # the license is node-locked to a MAC. Deliberately absent: nextpnr-gowin and
  # apicula — docs/fpga-platform-assessment.md §4 found Apicula has no usable
  # GW5AST-138 support, so they cannot produce a .fs for this part.
  #
  # nixpkgs 1.1.1 is new enough (board entry + GW5AST-138 IDCODE + the Arora-V
  # SRAM fix). nix/fpga.nix also builds our fork as `.#openfpgaloader-fork`.
  fpgaTools = [
    pkgs.openfpgaloader # program the FPGA over USB-JTAG
    pkgs.usbutils # lsusb — is the board even on the bus?
    pkgs.minicom # UART console on the debugger's second interface
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

  allPackages =
    docsTools ++ rtlTools ++ toolchainTools ++ riscvToolchain ++ fpgaTools ++ common;
in
{
  inherit
    pythonEnv
    docsTools
    rtlTools
    toolchainTools
    riscvToolchain
    fpgaTools
    common
    allPackages
    ;
}
