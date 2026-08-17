# nix/parser-trap-v7.nix
#
# `nix run .#cva6-parser-trap-v7` — build the parser-patched CVA6 model and run the
# V7 in-core faulting-instruction-squash test (tests/cva6-parser/parser_trap_v7.S):
# an `ecall` flushes an in-flight CPPRSWR parser write, which then re-executes and
# must commit the SAME value as a fault-free run (Table C V7, gap G7).
#
# Same composition as cva6-parser-test.nix: reuse the cva6-baseline build body with
# the PATCHED source + the build/parser-core work dir, then append the V7 test body.
# One build path, no second copy of the Makefile-patching logic.
#
{ pkgs, cva6-src }:  # cva6-src here is the PATCHED tree (cva6-parser-src)

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  name = "cva6-parser-trap-v7";

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
     + builtins.readFile ../scripts/parser-trap-v7.sh;
}
