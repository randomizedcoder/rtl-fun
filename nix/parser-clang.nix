# nix/parser-clang.nix — Clang built against the parser-patched LLVM (Phase 7, C0).
#
# The Clang leg of the toolchain ladder (§7.4: "the parser unit reachable from Clang").
# We override the nixpkgs `clang-unwrapped` derivation's `libllvm` argument with our
# parser-patched llvm (nix/parser-llvm.nix, the MC layer). Clang links that libLLVM, and
# Clang's integrated assembler IS the LLVM MC layer — so `clang -c` parses/encodes the
# custom-0 / custom-3 `prs.*` mnemonics (and inline-asm containing them) with zero extra
# flags, inheriting the RISCVAsmParser/Disassembler/InstPrinter patch for free.
#   C0 stood up the build only (no clang source touched).
#   C1 adds `extraPatches` = parser-clang.patch: the __builtin_riscv_prs_* declarations +
#   Sema range checks + CodeGen InlineAsm lowering (generated from isa/parser-opcodes.yaml).
#   C3 extends the same patch with the custom-3 register-move builtins (a second CodeGen arm:
#   =r/r constraints + a p-register baked into the mnemonic; the C0 immediate arm is untouched).
#
# The patched llvm is RISCV-only (LLVM_TARGETS_TO_BUILD=RISCV), so the Clang built here is
# a RISC-V-only cross compiler — all this leg needs, and it keeps the from-source build as
# small and cacheable as possible. clang-tools-extra (clangd/clang-tidy) is disabled for
# the same reason. Scoped to the parser-clang-check app's PATH only; the dev shell and the
# rest of the matrix keep the stock toolchain and stay green.
#
{ pkgs }:

let
  parser-llvm = import ./parser-llvm.nix { inherit pkgs; };

  # clang-unwrapped rebuilt against the patched libLLVM. `.override` re-threads the
  # `libllvm` argument through the derivation (its cmake LLVM_DIR points at libllvm.dev),
  # so this Clang links the parser-aware MC libraries.
  parser-clang = pkgs.llvmPackages.clang-unwrapped.override {
    libllvm = parser-llvm;
    enableClangToolsExtra = false;
    # C1: the __builtin_riscv_prs_* leg. `extraPatches` is appended to the clang
    # derivation's `patches` (sourceRoot = <src>/clang), so paths are clang/-rooted.
    extraPatches = [ ./parser-clang/parser-clang.patch ];
  };

  parser-clang-check = pkgs.writeShellApplication {
    name = "parser-clang-check";

    # SC2329: shared-lib helpers are invoked indirectly (cross-file), read as dead.
    excludeShellChecks = [ "SC2329" ];

    runtimeInputs = [
      parser-clang               # the parser-aware clang (integrated-as == the MC layer)
      parser-llvm                # llvm-objdump (parser-aware disassembly, cross-check)
      pkgs.pkgsCross.riscv64-embedded.buildPackages.binutils  # riscv64-none-elf-objdump
      pkgs.gcc                   # host cc for the golden-model vector generator
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gawk
      pkgs.diffutils
    ];

    text = ''
      export REPO_ROOT="''${REPO_ROOT:-$PWD}"
    '' + builtins.readFile ../scripts/lib/common.sh
       + builtins.readFile ../scripts/parser-clang-check.sh;
  };

  parser-clang-builtins-test = pkgs.writeShellApplication {
    name = "parser-clang-builtins-test";
    runtimeInputs = [
      parser-clang               # clang with __builtin_riscv_prs_*
      parser-llvm                # parser-aware llvm-objdump (decodes prs.*)
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gawk
      pkgs.diffutils
    ];
    text = ''
      export REPO_ROOT="''${REPO_ROOT:-$PWD}"
    '' + builtins.readFile ../scripts/parser-clang-builtins-test.sh;
  };
in
{
  inherit parser-clang parser-clang-check parser-clang-builtins-test;
}
