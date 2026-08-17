# nix/parser-negative-control.nix
#
# `nix run .#parser-negative-control` — negative control (gap G11): build the STOCK
# (unpatched) CVA6 model and run a custom-0 PARSER word on it, asserting the base
# core REJECTS it (illegal-instruction trap). This is the flip side of
# cva6-parser-test: it proves the parser ops are a genuine ISA extension, not
# something the stock RV64GC decoder already accepts.
#
# Same composition as cva6-parser-test.nix but with the STOCK source (cva6-src) and
# no CVA6_WORK override, so it builds/reuses the stock model at build/cva6 (exactly
# where `nix run .#cva6-baseline` puts it). Prepends the shared bash lib + the
# cva6-baseline build body + the negative-control test body — one build path, no
# second copy of the Makefile-patching logic.
#
{ pkgs, cva6-src }:  # cva6-src here is the STOCK pinned tree

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  name = "parser-negative-control";

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
    export REPO_ROOT="''${REPO_ROOT:-$PWD}"
  '' + builtins.readFile ../scripts/lib/common.sh
     + builtins.readFile ../scripts/cva6-baseline.sh
     + builtins.readFile ../scripts/parser-negative-control.sh;
}
