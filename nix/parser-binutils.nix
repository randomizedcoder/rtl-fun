# nix/parser-binutils.nix
#
# Phase 7 L2 (§7.3): a riscv64-none-elf binutils patched with the parser-unit
# mnemonics + objdump disassembly, so assembly reads `prs.load.h 1, 12` /
# `prs.mv.p.x pnext, a0` instead of `.insn 4, <word>` blobs.
#
# The opcode-table rows are GENERATED (tools/parser-gen ->
# toolchain/generated/parser-opc-gas.inc) and pasted into the patch; the only
# hand-written operand class is the parser p-register `Xpr` (Cpreg[28:24], names
# from isa/parser-opcodes.yaml). Immediates ride binutils' stock `XtuN@S`
# bitfield operand, so the patch stays small (~120 lines, no new opcode letters).
#
# We patch the *unwrapped* cross binutils: its bin/ already ships the prefixed
# riscv64-none-elf-{as,ld,objdump,...} that scripts/parser-asm-test.sh drives, so
# no bintools-wrapper rebuild is needed. Kept off the default toolchain (only the
# parser-asm-test app puts it on PATH), so the rest of the matrix is untouched.
#
{ pkgs }:

let
  cross = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
cross.binutils-unwrapped.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./parser-binutils/parser-binutils.patch ];
})
