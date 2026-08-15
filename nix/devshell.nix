# nix/devshell.nix
#
# The default development shell: all project tools + a short banner and the
# `rtl-help` function.
#
# Usage in flake.nix:
#   devshell = import ./nix/devshell.nix { inherit pkgs lib packages cva6-src; };
#   devShells.default = devshell;
#
{ pkgs, lib, packages, cva6-src, cva6-baseline }:

let
  helpFn = import ./shell-functions/help.nix { };
in
pkgs.mkShell {
  packages = packages.allPackages ++ [ cva6-baseline ];

  # Pinned CVA6 source (read-only nix store path). Copy to a writable workdir
  # before building: cp -r --no-preserve=mode "$CVA6_SRC" cva6
  CVA6_SRC = cva6-src;

  # Bare-metal RISC-V toolchain prefix, for CVA6's sim build (CV_SW_PREFIX) and
  # our own .insn tests.
  CV_SW_PREFIX = "riscv64-none-elf-";

  shellHook = ''
    ${helpFn}

    echo "rtl-fun dev shell ready — $(verilator --version 2>/dev/null | head -1 || echo 'verilator present')"
    echo "type 'rtl-help' for the tool list."
  '';
}
