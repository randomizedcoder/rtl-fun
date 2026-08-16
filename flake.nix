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

        # Parser-unit RTL apps (Phase 5): parser-sim{,-trace,-debug} + parser-lint.
        rtl = import ./nix/rtl.nix { inherit pkgs; };

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
          model-analyze = model.model-analyze;
          model-fuzz = model.model-fuzz;
          pm-trace = model.pm-trace;
          # Parser-unit RTL sim/lint runners as packages too.
          parser-sim = rtl.parser-sim;
          parser-sim-suite = rtl.parser-sim-suite;
          parser-sim-trace = rtl.parser-sim-trace;
          parser-sim-debug = rtl.parser-sim-debug;
          parser-lint = rtl.parser-lint;
          parser-analyze = rtl.parser-analyze;
          parser-formal = rtl.parser-formal;
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

        # Static analysis + sanitizers for the C model: `nix run .#model-analyze`.
        apps.model-analyze = {
          type = "app";
          program = "${model.model-analyze}/bin/model-analyze";
        };

        # Fuzz the C model (libFuzzer + ASan/UBSan): `nix run .#model-fuzz`.
        apps.model-fuzz = {
          type = "app";
          program = "${model.model-fuzz}/bin/model-fuzz";
        };

        # Single-step a parse for debugging: `nix run .#pm-trace [-- x.pcap]`.
        apps.pm-trace = {
          type = "app";
          program = "${model.pm-trace}/bin/pm-trace";
        };

        # Parser-unit RTL smoke test (Phase 5), at four debug levels:
        #   nix run .#parser-sim         optimized, run the smoke test
        #   nix run .#parser-sim-trace   + FST waveform (--trace-structs)
        #   nix run .#parser-sim-debug   -O0 -ggdb + waveform (gdb)
        #   nix run .#parser-lint        --lint-only -Wall, no build
        apps.parser-sim = {
          type = "app";
          program = "${rtl.parser-sim}/bin/parser-sim";
        };
        apps.parser-sim-suite = {
          type = "app";
          program = "${rtl.parser-sim-suite}/bin/parser-sim-suite";
        };
        apps.parser-sim-trace = {
          type = "app";
          program = "${rtl.parser-sim-trace}/bin/parser-sim-trace";
        };
        apps.parser-sim-debug = {
          type = "app";
          program = "${rtl.parser-sim-debug}/bin/parser-sim-debug";
        };
        apps.parser-lint = {
          type = "app";
          program = "${rtl.parser-lint}/bin/parser-lint";
        };
        # Extra SV static analysis (verible + svlint): `nix run .#parser-analyze`.
        apps.parser-analyze = {
          type = "app";
          program = "${rtl.parser-analyze}/bin/parser-analyze";
        };
        # Formal proof of parser_execute safety: `nix run .#parser-formal`.
        apps.parser-formal = {
          type = "app";
          program = "${rtl.parser-formal}/bin/parser-formal";
        };

        # `nix fmt` formats the .nix files.
        formatter = pkgs.nixpkgs-fmt;
      });
}
