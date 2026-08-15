# nix/devshell.nix
#
# The default development shell: all project tools + a short banner and the
# `rtl-help` function.
#
# Usage in flake.nix:
#   devshell = import ./nix/devshell.nix { inherit pkgs lib packages; };
#   devShells.default = devshell;
#
{ pkgs, lib, packages }:

let
  helpFn = import ./shell-functions/help.nix { };
in
pkgs.mkShell {
  packages = packages.allPackages;

  shellHook = ''
    ${helpFn}

    echo "rtl-fun dev shell ready — $(verilator --version 2>/dev/null | head -1 || echo 'verilator present')"
    echo "type 'rtl-help' for the tool list."
  '';
}
