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

        # Parser-patched CVA6 source, as its own cacheable derivation (only
        # rebuilds when the source or the patch changes).
        cva6-parser-src = import ./nix/cva6-patched.nix {
          inherit pkgs cva6-src;
          parserRtl = ./rtl;
        };

        # Two Verilator builds from ONE builder, for easy unpatched-vs-patched
        # compare: cva6-baseline (stock) and cva6-parser (patched). Distinct work
        # dirs so they don't collide under build/.
        cva6-baseline = import ./nix/cva6-baseline.nix { inherit pkgs cva6-src; };
        cva6-parser = import ./nix/cva6-baseline.nix {
          inherit pkgs;
          cva6-src = cva6-parser-src;
          name = "cva6-parser";
          cva6Work = "$PWD/build/parser-core";
        };

        # Build the patched model + run the in-core directed test (custom-0 PARSER
        # ops issue/execute/retire; fesvr tohost PASS).
        cva6-parser-test = import ./nix/cva6-parser-test.nix {
          inherit pkgs;
          cva6-src = cva6-parser-src;
        };

        # Build the patched model + run the table-driven in-core co-simulation
        # (I5): packet -> flow_keys equivalence vs the golden model, over real MMIO.
        cva6-parser-cosim = import ./nix/cva6-parser-cosim.nix {
          inherit pkgs;
          cva6-src = cva6-parser-src;
        };

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
          # The parser-patched CVA6 source: `nix build .#cva6-parser-src`.
          cva6-parser-src = cva6-parser-src;
          # The two Verilator builders as packages too.
          cva6-baseline = cva6-baseline;
          cva6-parser = cva6-parser;
          cva6-parser-test = cva6-parser-test;
          cva6-parser-cosim = cva6-parser-cosim;
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
          parser-sim-decode = rtl.parser-sim-decode;
          parser-sim-trace = rtl.parser-sim-trace;
          parser-sim-debug = rtl.parser-sim-debug;
          parser-lint = rtl.parser-lint;
          parser-analyze = rtl.parser-analyze;
          parser-formal = rtl.parser-formal;
          parser-wrap-test = rtl.parser-wrap-test;
        };

        # Build the stock CVA6 Verilator model: `nix run .#cva6-baseline`.
        apps.cva6-baseline = {
          type = "app";
          program = "${cva6-baseline}/bin/cva6-baseline";
        };

        # Build the parser-patched CVA6 Verilator model: `nix run .#cva6-parser`.
        # Same builder as the baseline, different source — run both to compare.
        apps.cva6-parser = {
          type = "app";
          program = "${cva6-parser}/bin/cva6-parser";
        };

        # Build the patched model and run the in-core directed test:
        # `nix run .#cva6-parser-test`.
        apps.cva6-parser-test = {
          type = "app";
          program = "${cva6-parser-test}/bin/cva6-parser-test";
        };

        # Build the patched model and run the table-driven in-core co-simulation:
        # `nix run .#cva6-parser-cosim`.
        apps.cva6-parser-cosim = {
          type = "app";
          program = "${cva6-parser-cosim}/bin/cva6-parser-cosim";
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
        # Directed suite via the CVA6 decode path (32-bit words -> parser_decode).
        apps.parser-sim-decode = {
          type = "app";
          program = "${rtl.parser-sim-decode}/bin/parser-sim-decode";
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
        # I1 commit-visible parser-state testbench: `nix run .#parser-wrap-test`.
        apps.parser-wrap-test = {
          type = "app";
          program = "${rtl.parser-wrap-test}/bin/parser-wrap-test";
        };

        # `nix fmt` formats the .nix files.
        formatter = pkgs.nixpkgs-fmt;
      });
}
