# nix/parser-asm-test.nix
#
# Phase 7 L2 (§7.3): assemble every parser mnemonic with the parser-patched
# riscv64-none-elf binutils (nix/parser-binutils.nix) and check the words match the
# generated/model goldens + that objdump disassembles them readably.
#
#   nix run .#parser-asm-test
#
# The patched binutils is scoped to THIS app's PATH only (via runtimeInputs), so the
# rest of the matrix keeps using the stock toolchain and stays green.
#
{ pkgs }:

let
  parser-binutils = import ./parser-binutils.nix { inherit pkgs; };

  parser-asm-test = pkgs.writeShellApplication {
    name = "parser-asm-test";
    runtimeInputs = [
      parser-binutils            # riscv64-none-elf-{as,objdump} with prs.* support
      pkgs.gcc                   # host cc for the vector generator
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gawk
      pkgs.diffutils
    ];
    text = builtins.readFile ../scripts/parser-asm-test.sh;
  };
in
{
  inherit parser-binutils parser-asm-test;
}
