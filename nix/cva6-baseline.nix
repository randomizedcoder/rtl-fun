# nix/cva6-baseline.nix
#
# The `cva6-baseline` app: build the stock CVA6 Verilator model (Phase 0 task 4).
#
# Packaged with writeShellApplication so that (1) all tools are on PATH via
# runtimeInputs and (2) shellcheck runs at build time — a broken script fails the
# build instead of at runtime. The script *body* lives in scripts/cva6-baseline.sh
# (readable / editable); this wrapper injects the pinned store paths as env.
#
# Run:  nix run .#cva6-baseline
#
{ pkgs, cva6-src }:

let
  # Bare-metal RISC-V toolchain (riscv64-none-elf-*, newlib).
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  name = "cva6-baseline";

  runtimeInputs = [
    pkgs.verilator
    pkgs.gnumake
    pkgs.gcc # host g++ for the verilated C++ model
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.findutils
    toolchain.gcc
    toolchain.binutils
    pkgs.spike
  ];

  # Inject the pinned store paths (overridable for dev use); then run the body.
  text = ''
    export CVA6_SRC="''${CVA6_SRC:-${cva6-src}}"
    export SPIKE_PREFIX="''${SPIKE_PREFIX:-${pkgs.spike}}"
    export YAMLCPP="''${YAMLCPP:-${pkgs.yaml-cpp}}"
  '' + builtins.readFile ../scripts/cva6-baseline.sh;
}
