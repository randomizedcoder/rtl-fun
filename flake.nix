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

        # Pinned CVA6 base-core source (fetched via Nix; built imperatively).
        cva6-src = import ./nix/cva6.nix { inherit pkgs; };

        # The `cva6-baseline` app (writeShellApplication: PATH + shellcheck).
        cva6-baseline = import ./nix/cva6-baseline.nix { inherit pkgs cva6-src; };

        # Pinned xdp2 source (for the proto_audit packet corpus, Phase 2).
        xdp2-src = import ./nix/xdp2.nix { inherit pkgs; };

        # Golden-model apps: `model-test` (unit + corpus tests) and `pm-trace`.
        model = import ./nix/model.nix { inherit pkgs xdp2-src; };

        # The default development shell (exports CVA6_SRC -> the pinned source,
        # and puts the cva6-baseline app on PATH).
        devshell = import ./nix/devshell.nix {
          inherit pkgs lib packages cva6-src cva6-baseline;
        };
      in
      {
        devShells.default = devshell;

        packages = {
          # The pinned CVA6 source: `nix build .#cva6-src`.
          cva6-src = cva6-src;
          # The baseline builder as a package too: `nix build .#cva6-baseline`.
          cva6-baseline = cva6-baseline;
          # The pinned xdp2 source (packet corpus): `nix build .#xdp2-src`.
          xdp2-src = xdp2-src;
          # Golden-model runners as packages too.
          model-test = model.model-test;
          pm-trace = model.pm-trace;
        };

        # Build the stock CVA6 Verilator model: `nix run .#cva6-baseline`.
        apps.cva6-baseline = {
          type = "app";
          program = "${cva6-baseline}/bin/cva6-baseline";
        };

        # Run the golden-model tests: `nix run .#model-test`.
        apps.model-test = {
          type = "app";
          program = "${model.model-test}/bin/model-test";
        };

        # Single-step a parse for debugging: `nix run .#pm-trace [-- x.pcap]`.
        apps.pm-trace = {
          type = "app";
          program = "${model.pm-trace}/bin/pm-trace";
        };

        # `nix fmt` formats the .nix files.
        formatter = pkgs.nixpkgs-fmt;
      });
}
