# nix/fpga-10g-fit.nix
#
# Phase-C verify-before-buy: OOC synth (+ place/route) a 10G Ethernet MAC on the AX7325B
# die (xc7k325tffg900-2) to prove the 10G datapath BUILDS, FITS and meets Fmax with NO
# board and NO transceiver IP. The datapath-feasibility complement to fpga-soc-vivado
# (A2/B4): combined with the SoC utilization it shows CVA6 + a 10G MAC co-reside on the
# 325T fabric. See docs/phase-8-status.md §"C5".
#
#   nix run .#fpga-10g-fit             OOC synth + route -> util + Fmax verdict
#   nix run .#fpga-10g-fit -- synth    OOC synth-only -> utilization (fit only)
#   nix run .#fpga-10g-fit -- route    OOC synth + place + route -> util + timing
#   nix run .#fpga-10g-fit -- report   re-print utilization + fit/Fmax verdict
#
# DUT: Alex Forencich verilog-ethernet `eth_mac_10g` (64-bit XGMII), pinned as the flake
# input `verilog-ethernet-src` (flake.nix) — the same MAC family this repo already
# vendors at 1G (corev_apu/fpga/src/ariane-ethernet/eth_mac_1g*.sv). The store path is
# injected here as VERILOG_ETHERNET_SRC so the flist is reproducible and lock-pinned,
# not an untracked clone.
#
# Kept in its OWN module (a separate concern from the CVA6-SoC Vivado targets): it fits
# a vendored third-party MAC, not our CVA6 tree.
#
# HOST-TOOL DEPENDENCY (documented impurity, like the other Vivado targets): Vivado is
# NOT in nixpkgs — `vivado` on PATH (source settings64.sh) or $VIVADO; on NixOS use the
# FHS sandbox (nix run .#vivado-fhs). writeShellApplication keeps the inherited PATH;
# `nix run` passes the caller's runtime env through — no --impure.
{ pkgs, verilog-ethernet-src }:

let
  commonLib = builtins.readFile ../scripts/lib/common.sh;

  fpga-10g-fit = pkgs.writeShellApplication {
    name = "fpga-10g-fit";
    # No toolchain injected — Vivado is the host dependency, located at run time. Only
    # the shell utilities the script itself uses are pinned.
    runtimeInputs = [
      pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.gawk
    ];
    # SC2329: the prepended common.sh defines shared helpers this script does not call,
    # which shellcheck reads as dead functions (same convention as the other targets).
    excludeShellChecks = [ "SC2329" ];
    text = ''
      export VERILOG_ETHERNET_SRC="''${VERILOG_ETHERNET_SRC:-${verilog-ethernet-src}}"
    '' + commonLib + builtins.readFile ../scripts/fpga-10g-fit.sh;
  };
in
{
  inherit fpga-10g-fit;
}
