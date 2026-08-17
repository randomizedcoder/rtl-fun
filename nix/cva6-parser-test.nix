# nix/cva6-parser-test.nix
#
# `nix run .#cva6-parser-test` — build the parser-patched CVA6 model and run the
# in-core directed test (tests/cva6-parser/parser_insn.S) on it, asserting the
# custom-0 PARSER ops execute and retire (fesvr tohost PASS).
#
# It reuses the SAME build body as cva6-baseline (scripts/cva6-baseline.sh) with
# the PATCHED source + a dedicated work dir, so the model is built (or refreshed
# incrementally) exactly as `nix run .#cva6-parser` would, and then appends the
# test body (scripts/cva6-parser-test.sh). This keeps one build path and adds no
# second copy of the Makefile-patching logic.
#
{ pkgs, cva6-src }:  # cva6-src here is the PATCHED tree (cva6-parser-src)

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  name = "cva6-parser-test";

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
     + builtins.readFile ../scripts/cva6-parser-test.sh;
}
