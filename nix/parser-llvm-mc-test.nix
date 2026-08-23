# nix/parser-llvm-mc-test.nix
#
# Phase 7 L3 (§7.4): assemble + disassemble the parser mnemonics with the parser-patched
# LLVM MC layer (nix/parser-llvm.nix) and check the words match the generated/model
# goldens — the LLVM twin of parser-asm-test (binutils, L2).
#
#   nix run .#parser-llvm-mc-test
#
# The patched llvm is scoped to THIS app's PATH only (via runtimeInputs), so the rest of
# the matrix keeps using the stock toolchain and stays green.
#
{ pkgs }:

let
  parser-llvm = import ./parser-llvm.nix { inherit pkgs; };

  parser-llvm-mc-test = pkgs.writeShellApplication {
    name = "parser-llvm-mc-test";
    runtimeInputs = [
      parser-llvm                # llvm-mc / llvm-objdump with prs.* support
      pkgs.gcc                   # host cc for the vector generator
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gawk
      pkgs.diffutils
    ];
    text = builtins.readFile ../scripts/parser-llvm-mc-test.sh;
  };
in
{
  inherit parser-llvm parser-llvm-mc-test;
}
