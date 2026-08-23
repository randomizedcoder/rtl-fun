# nix/parser-llvm.nix — LLVM with the rtl-fun parser-unit MC extension (Phase 7 L3).
#
# Twin of nix/parser-binutils.nix, for the LLVM machine-code layer: it patches the
# in-tree RISC-V target (llvm/lib/Target/RISCV) with a generated TableGen fragment
# (RISCVInstrInfoXparser.td, included from RISCVInstrInfo.td) describing the custom-0
# / custom-3 parser ops. The ops live in the default RISCV decoder namespace and carry
# NO predicate, so `llvm-mc` assembles/disassembles them unconditionally — mirroring the
# binutils INSN_CLASS_I rows (custom-0 0x0b and custom-3 0x7b are unused by the base ISA,
# so there is no matcher/decoder conflict and no -mattr gate).
#
# Scoped to LLVM_TARGETS_TO_BUILD=RISCV: the leg only needs the target-agnostic tools
# (llvm-mc / llvm-objdump) plus the RISC-V backend, so we skip the other ~15 backends to
# keep the from-source rebuild as small and cacheable as possible. Only parser-llvm-mc-test
# puts these tools on PATH; the default dev shell is unaffected.
{ pkgs }:

pkgs.llvm.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./parser-llvm/parser-llvm.patch ];
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DLLVM_TARGETS_TO_BUILD=RISCV" ];
  doCheck = false;
})
