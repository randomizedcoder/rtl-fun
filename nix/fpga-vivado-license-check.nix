# nix/fpga-vivado-license-check.nix
#
# Phase-A verify-before-buy: probe what the installed Vivado license actually PERMITS on a
# target part (default the AX7325B / Genesys 2 die xc7k325tffg900-2). The 2026.1 tiered
# model gates *implementation* per device, so "synth works" does not imply "impl+bitstream
# works" — this pushes a trivial design through synth -> place -> route -> write_bitstream
# and reports which license features Vivado granted, with NO board and NO CVA6.
#
#   nix run .#fpga-vivado-license-check          probe xc7k325tffg900-2, print a VERDICT
#   XILINX_PART=<part> nix run .#fpga-vivado-license-check   probe another part
#
# RESULT (hp5, 2026-09-20, free "Basic" tier): Vivado_Synthesis AND Vivado_Implementation
# both granted on xc7k325t; write_bitstream completed -> the full routed-bitstream flow is
# free-tier on the 325T (no edu license needed).
#
# HOST-TOOL DEPENDENCY (documented impurity, like the other Vivado targets): Vivado is NOT
# in nixpkgs — `vivado` on PATH (source settings64.sh) or $VIVADO; on NixOS use the FHS
# sandbox (nix run .#vivado-fhs). writeShellApplication keeps the inherited PATH; `nix run`
# passes the caller's runtime env through, so this needs no --impure.
{ pkgs }:

let
  commonLib = builtins.readFile ../scripts/lib/common.sh;

  # No toolchain injected — Vivado is the host dependency, located at run time.
  fpga-vivado-license-check = pkgs.writeShellApplication {
    name = "fpga-vivado-license-check";
    runtimeInputs = [
      pkgs.coreutils pkgs.gnugrep pkgs.gnused
    ];
    # SC2329: the prepended common.sh defines shared helpers this script does not call,
    # which shellcheck reads as dead functions (same convention as nix/fpga-m1.nix et al.).
    excludeShellChecks = [ "SC2329" ];
    text = commonLib + builtins.readFile ../scripts/fpga-vivado-license-check.sh;
  };
in
{
  inherit fpga-vivado-license-check;
}
