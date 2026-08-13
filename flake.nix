#
# flake.nix for rtl-fun — parser instructions for RISC-V
#
# Provides a reproducible development environment so everyone working in this
# repo has the same tools. Modeled on the modular ./nix/ layout used by the
# nearby xdp2 project.
#
# Enter the dev shell:
#   nix develop
#
# If flakes are not enabled system-wide:
#   nix --extra-experimental-features 'nix-command flakes' develop .
#
# Once inside, run `rtl-help` for the tool list.
#
# Extending: add packages in nix/packages.nix; add build derivations or script
# runners as new nix/<name>.nix modules and wire them into outputs below (see
# docs/nix.md).
#
{
  description = "rtl-fun — RISC-V parser-instruction ISA extension (docs, model, RTL)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = nixpkgs.lib;

        # Tool groups (docs / rtl / sim / toolchain / common).
        packages = import ./nix/packages.nix { inherit pkgs; };

        # The default development shell.
        devshell = import ./nix/devshell.nix { inherit pkgs lib packages; };
      in
      {
        devShells.default = devshell;

        # `nix fmt` formats the .nix files.
        formatter = pkgs.nixpkgs-fmt;
      });
}
