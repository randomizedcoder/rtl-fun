# nix/cva6-parser-cosim.nix
#
# `nix run .#cva6-parser-cosim` — build the parser-patched CVA6 model and run the
# table-driven in-core CO-SIMULATION (I5): for every packet in the directed suite,
# feed it to the parser FU over real MMIO, run the slice program in-core, read the
# committed flow_keys back, and compare BYTE-FOR-BYTE to the golden model.
#
# Like cva6-parser-test.nix it reuses the SAME build body as cva6-baseline
# (scripts/cva6-baseline.sh) with the PATCHED source + a dedicated work dir, so the
# model is built (or refreshed incrementally) exactly as `nix run .#cva6-parser`
# would, then appends the cosim body (scripts/cva6-parser-cosim.sh). One build path,
# no second copy of the Makefile-patching logic.
#
{ pkgs, cva6-src }:  # cva6-src here is the PATCHED tree (cva6-parser-src)

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  name = "cva6-parser-cosim";

  runtimeInputs = [
    pkgs.verilator
    pkgs.gnumake
    pkgs.gcc
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.gawk
    pkgs.findutils
    toolchain.gcc
    toolchain.binutils
    pkgs.spike
  ];

  text = ''
    export CVA6_SRC="''${CVA6_SRC:-${cva6-src}}"
    export SPIKE_PREFIX="''${SPIKE_PREFIX:-${pkgs.spike}}"
    export YAMLCPP="''${YAMLCPP:-${pkgs.yaml-cpp}}"
    export CVA6_WORK="''${CVA6_WORK:-$PWD/build/parser-core}"
    export REPO_ROOT="''${REPO_ROOT:-$PWD}"
  '' + builtins.readFile ../scripts/cva6-baseline.sh
     + builtins.readFile ../scripts/cva6-parser-cosim.sh;
}
