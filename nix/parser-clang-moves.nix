# nix/parser-clang-moves.nix
#
# `nix run .#parser-clang-moves` — the Phase-7 C3 check: the custom-3 register-move
# builtins (__builtin_riscv_prs_mv_x_p / mv_p_x / cam_read / array_read) both ENCODE
# correctly (table-driven masked-word structural check off parser-clang-moves.tsv) and
# EXECUTE correctly (a builtins-only p-register write->read round-trip on the standalone
# parser Spike). This finishes the Clang leg: the parser p-registers reachable from Clang.
#
{ pkgs, spike-parser, parser-clang, parser-llvm }:

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  name = "parser-clang-moves";

  # SC2329: the shared lib helpers are invoked indirectly (cross-file), read as dead.
  excludeShellChecks = [ "SC2329" ];

  runtimeInputs = [
    parser-clang       # the parser-aware clang: __builtin_riscv_prs_* incl. the C3 moves
    parser-llvm        # llvm-objdump: parser-aware disassembly for the structural check
    spike-parser       # the standalone parser Spike: runs the functional round-trip
    pkgs.dtc           # spike shells out to `dtc` at startup to build its device tree
    toolchain.gcc      # riscv64 cross gcc/ld: links parser_moves.o + htif.S into the ELF
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.gawk
    pkgs.diffutils
    pkgs.findutils
  ];

  text = ''
    export SPIKE_PARSER="''${SPIKE_PARSER:-${spike-parser}}"
    export REPO_ROOT="''${REPO_ROOT:-$PWD}"
  '' + builtins.readFile ../scripts/lib/common.sh
     + builtins.readFile ../scripts/parser-clang-moves.sh;
}
