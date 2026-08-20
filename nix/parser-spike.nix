# nix/parser-spike.nix
#
# `nix run .#parser-spike` — run parser ELFs on the STANDALONE parser Spike
# (nix/spike-parser.nix) and check they self-report SUCCESS. The user-facing ISA
# simulator for Phase 7 Stage 2: an independent, runnable reference for the parser
# ISA, separate from the CVA6-tandem `spike-tandem` (libraries-only).
#
# Reuses the shared script libs (common.sh vector-gen + rv_assemble, suite.sh, the
# cosim.sh prog.S/case.S emitters) so the 22-case corpus is fed exactly as the
# in-core cva6-parser-cosim feeds it — only the run target (spike, not the CVA6
# model) differs.
#
{ pkgs, spike-parser }:

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  name = "parser-spike";

  # SC2329: the shared lib helpers + the per-case callback are invoked indirectly
  # (run_suite dispatch / cross-file), which shellcheck reads as dead.
  excludeShellChecks = [ "SC2329" ];

  runtimeInputs = [
    spike-parser
    pkgs.dtc          # spike shells out to `dtc` at startup to build its device tree
    toolchain.gcc
    toolchain.binutils
    pkgs.gcc
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.gawk
    pkgs.findutils
  ];

  text = ''
    export SPIKE_PARSER="''${SPIKE_PARSER:-${spike-parser}}"
    export REPO_ROOT="''${REPO_ROOT:-$PWD}"
  '' + builtins.readFile ../scripts/lib/common.sh
     + builtins.readFile ../scripts/lib/suite.sh
     + builtins.readFile ../scripts/lib/cosim.sh
     + builtins.readFile ../scripts/parser-spike.sh;
}
