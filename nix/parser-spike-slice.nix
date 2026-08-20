# nix/parser-spike-slice.nix
#
# `nix run .#parser-spike-slice` — run the Phase-0 slice parser AUTHORED IN C with
# the generated intrinsics (tests/cva6-parser/parser_slice.c) on the standalone
# parser Spike (nix/spike-parser.nix), over the 22-case packet corpus == the golden
# model. This is the Spike leg of the Phase-7 exit criterion (Stage 3).
#
# It is the same runner as nix/parser-spike.nix (Stage 2) with SLICE=1: the parse
# block comes from the compiled parser_slice.o (byte-parity-checked against the
# model ROM) instead of the model-generated prog.S .word stream. Sharing one script
# body (scripts/parser-spike.sh) keeps the two paths from drifting.
#
{ pkgs, spike-parser }:

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  name = "parser-spike-slice";

  # SC2329: the shared lib helpers + the per-case callback are invoked indirectly
  # (run_suite dispatch / cross-file), which shellcheck reads as dead.
  excludeShellChecks = [ "SC2329" ];

  runtimeInputs = [
    spike-parser
    pkgs.dtc          # spike shells out to `dtc` at startup to build its device tree
    toolchain.gcc     # riscv64 cross gcc: compiles parser_slice.c + links the ELFs
    toolchain.binutils # riscv64 objdump: the byte-parity guard
    pkgs.gcc          # host cc: the golden-model vector generator
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.gawk
    pkgs.diffutils    # the byte-parity diff
    pkgs.findutils
  ];

  text = ''
    export SPIKE_PARSER="''${SPIKE_PARSER:-${spike-parser}}"
    export REPO_ROOT="''${REPO_ROOT:-$PWD}"
    export SLICE=1
  '' + builtins.readFile ../scripts/lib/common.sh
     + builtins.readFile ../scripts/lib/suite.sh
     + builtins.readFile ../scripts/lib/cosim.sh
     + builtins.readFile ../scripts/parser-spike.sh;
}
