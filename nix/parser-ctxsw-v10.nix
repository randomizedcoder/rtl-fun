# nix/parser-ctxsw-v10.nix
#
# `nix run .#cva6-parser-ctxsw-v10` — build the parser-patched CVA6 model and run the
# V10 in-core between-parse context-switch test (tests/cva6-parser/parser_ctxsw_v10.S):
# spill/clobber/reload of the five writable parser registers {p11,p13,p14,p15,p16} via
# the custom-3 move ABI (CPPRSRD / CPPRSWR), asserting the parser context round-trips
# bit-for-bit through memory (Table C V10, gap G7 / §3.1 item 4; ratifies D7).
#
# Same composition as parser-trap-v6.nix: reuse the cva6-baseline build body with the
# PATCHED source + the build/parser-core work dir, then append the V10 test body. One
# build path, no second copy of the Makefile-patching logic.
#
{ pkgs, cva6-src }:  # cva6-src here is the PATCHED tree (cva6-parser-src)

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  name = "cva6-parser-ctxsw-v10";

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
     + builtins.readFile ../scripts/parser-ctxsw-v10.sh;
}
