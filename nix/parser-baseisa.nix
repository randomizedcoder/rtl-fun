# nix/parser-baseisa.nix
#
# `nix run .#cva6-parser-baseisa` — build the parser-patched CVA6 model and run the
# base-ISA regression (tests/cva6-parser/base_isa.S): a directed representative slice
# of RV64GC (integer incl. *w, M, A, F/D, CSR, branches, JAL/JALR), each result
# value-checked, must still retire correctly on the PATCHED core. Proves the parser
# extension is behaviorally transparent to the base ISA (gap G11, N6) — the companion
# to the negative control (N1), which proves the stock core rejects the parser ops.
#
# Same composition as parser-trap-v7.nix: reuse the cva6-baseline build body with the
# PATCHED source + the build/parser-core work dir, then append the base-ISA test body.
# One build path, no second copy of the Makefile-patching logic.
#
{ pkgs, cva6-src }:  # cva6-src here is the PATCHED tree (cva6-parser-src)

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  name = "cva6-parser-baseisa";

  # SC2329: the shared lib's helpers are invoked from the test body (cross-file),
  # which shellcheck reads as dead.
  excludeShellChecks = [ "SC2329" ];

  runtimeInputs = [
    pkgs.verilator
    pkgs.gnumake
    pkgs.gcc
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
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
  '' + builtins.readFile ../scripts/lib/common.sh
     + builtins.readFile ../scripts/cva6-baseline.sh
     + builtins.readFile ../scripts/parser-baseisa.sh;
}
