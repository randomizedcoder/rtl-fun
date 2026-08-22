# nix/parser-qemu-slice.nix
#
# `nix run .#parser-qemu-slice` — run the Phase-0 slice parser AUTHORED IN C with
# the generated intrinsics (tests/cva6-parser/parser_slice.c) on the patched
# qemu-system-riscv64 (nix/qemu-parser.nix), over the 22-case packet corpus == the
# golden model. Together with `parser-spike-slice`, this closes the Phase-7 exit
# criterion: the C slice assembles and runs on Spike AND QEMU == the golden model.
#
# It is the same runner as nix/parser-qemu.nix with SLICE=1: the parse block comes
# from the compiled parser_slice.o (byte-parity-checked against the model ROM)
# instead of the model-generated prog.S .word stream. Sharing one script body
# (scripts/parser-qemu.sh) keeps the two paths from drifting.
#
{ pkgs, qemu-parser }:

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  name = "parser-qemu-slice";

  # SC2329: the shared lib helpers + the per-case callback are invoked indirectly
  # (run_suite dispatch / cross-file), which shellcheck reads as dead.
  excludeShellChecks = [ "SC2329" ];

  runtimeInputs = [
    qemu-parser
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
    export QEMU_PARSER="''${QEMU_PARSER:-${qemu-parser}}"
    export REPO_ROOT="''${REPO_ROOT:-$PWD}"
    export SLICE=1
  '' + builtins.readFile ../scripts/lib/common.sh
     + builtins.readFile ../scripts/lib/suite.sh
     + builtins.readFile ../scripts/lib/cosim.sh
     + builtins.readFile ../scripts/parser-qemu.sh;
}
