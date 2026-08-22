# nix/parser-qemu.nix
#
# `nix run .#parser-qemu` — run parser ELFs on the patched qemu-system-riscv64
# (nix/qemu-parser.nix) and check they self-report SUCCESS. The QEMU twin of
# nix/parser-spike.nix: the same self-checking ELFs, fed by the same shared script
# libs, run on QEMU instead of Spike — the QEMU leg of the Phase 7 exit criterion.
#
# Reuses the shared script libs (common.sh vector-gen + rv_assemble, suite.sh, the
# cosim.sh prog.S/case.S emitters) so the 22-case corpus is fed exactly as the
# in-core cva6-parser-cosim / the Spike leg feed it — only the run target
# (qemu-system-riscv64 -M spike, not the Spike model) differs.
#
{ pkgs, qemu-parser }:

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  name = "parser-qemu";

  # SC2329: the shared lib helpers + the per-case callback are invoked indirectly
  # (run_suite dispatch / cross-file), which shellcheck reads as dead.
  excludeShellChecks = [ "SC2329" ];

  # No dtc here: unlike Spike (which shells out to `dtc` at startup), QEMU builds its
  # own FDT in-process, so the toolpath is gcc/binutils + qemu only.
  runtimeInputs = [
    qemu-parser
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
    export QEMU_PARSER="''${QEMU_PARSER:-${qemu-parser}}"
    export REPO_ROOT="''${REPO_ROOT:-$PWD}"
  '' + builtins.readFile ../scripts/lib/common.sh
     + builtins.readFile ../scripts/lib/suite.sh
     + builtins.readFile ../scripts/lib/cosim.sh
     + builtins.readFile ../scripts/parser-qemu.sh;
}
