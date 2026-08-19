# nix/cva6-parser-tandem-campaign.nix
#
# `nix run .#cva6-parser-tandem-campaign` — the Phase-7 Stage-2 random-packet
# tandem campaign: build the parser-patched CVA6 model WITH the RVFI-vs-Spike
# lock-step enabled (SPIKE_TANDEM=1) and drive hundreds of seeded-random + real
# xdp2-corpus packets through it, each lock-stepped per-instruction against the
# parser-taught Spike (nix/spike-tandem.nix).
#
# Identical build wiring to cva6-parser-tandem.nix (same SPIKE_PREFIX -> the
# source-built tandem Spike, same SPIKE_TANDEM=1 gate, same CVA6_WORK=build/parser-
# tandem so the ~15-min model build is SHARED/incremental, not duplicated). Two
# additions over the tandem app:
#   1. CORPUS_DIR is injected from the pinned xdp2 pcap_templates (nix/xdp2.nix),
#      exactly as model.nix does, so the corpus leg is reproducible.
#   2. It readFile-prepends the shared tandem.sh gate lib + the campaign body.
#
{ pkgs, cva6-src, spike-tandem, xdp2-src }:  # cva6-src = the PATCHED tree

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
  corpus = "${xdp2-src}/samples/proto_audit/pcap_templates";
in
pkgs.writeShellApplication {
  name = "cva6-parser-tandem-campaign";

  # SC2329: shared-lib helpers + the per-case callback are invoked indirectly /
  # cross-file, which shellcheck reads as dead.
  excludeShellChecks = [ "SC2329" ];

  runtimeInputs = [
    pkgs.verilator
    pkgs.gnumake
    pkgs.gcc
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.gawk
    pkgs.findutils
    pkgs.dtc            # spike builds a device-tree at runtime
    toolchain.gcc
    toolchain.binutils
    spike-tandem        # the tandem-patched Spike (replaces pkgs.spike)
  ];

  text = ''
    export CVA6_SRC="''${CVA6_SRC:-${cva6-src}}"
    export SPIKE_PREFIX="''${SPIKE_PREFIX:-${spike-tandem}}"
    export YAMLCPP="''${YAMLCPP:-${pkgs.yaml-cpp}}"
    export CVA6_WORK="''${CVA6_WORK:-$PWD/build/parser-tandem}"
    export REPO_ROOT="''${REPO_ROOT:-$PWD}"
    export CORPUS_DIR="''${CORPUS_DIR:-${corpus}}"
    export SPIKE_TANDEM=1
  '' + builtins.readFile ../scripts/lib/common.sh
     + builtins.readFile ../scripts/lib/suite.sh
     + builtins.readFile ../scripts/lib/cosim.sh
     + builtins.readFile ../scripts/lib/tandem.sh
     + builtins.readFile ../scripts/cva6-baseline.sh
     + builtins.readFile ../scripts/cva6-parser-tandem-campaign.sh;
}
