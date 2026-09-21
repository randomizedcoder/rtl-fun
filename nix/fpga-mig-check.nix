# nix/fpga-mig-check.nix
#
# Phase-B verify-before-buy: generate + OOC-synth a DDR3 MIG controller from an
# explicit .prj to validate a memory pinout with NO board and NO full SoC. Retires
# the AX7325B DDR3 risk (2 GiB / 64-bit, 8 byte lanes) by proving the byte-lane/bank
# grouping in fpga/ax7325b/mig_ax7325b.prj is legal on xc7k325tffg900-2 pre-buy.
#
#   nix run .#fpga-mig-check                validate fpga/ax7325b/mig_ax7325b.prj (default)
#   nix run .#fpga-mig-check -- genesys2    validate the stock 32-bit .prj (control)
#
# HOST-TOOL DEPENDENCY (documented impurity, like the other Vivado targets): Vivado is
# NOT in nixpkgs — `vivado` on PATH or $VIVADO; on NixOS use the FHS sandbox
# (nix run .#vivado-fhs). writeShellApplication keeps the inherited PATH; `nix run`
# passes the caller's runtime env through, so this needs no --impure. The MIG path
# uses only Vivado — no RISC-V toolchain, unlike fpga-soc-vivado.
{ pkgs }:

let
  commonLib = builtins.readFile ../scripts/lib/common.sh;

  fpga-mig-check = pkgs.writeShellApplication {
    name = "fpga-mig-check";
    runtimeInputs = [
      pkgs.coreutils pkgs.gnugrep pkgs.gnused
    ];
    # SC2329: the prepended common.sh defines shared helpers this script does not call,
    # which shellcheck reads as dead functions (same convention as nix/fpga-m1.nix et al.).
    excludeShellChecks = [ "SC2329" ];
    text = commonLib + builtins.readFile ../scripts/fpga-mig-check.sh;
  };
in
{
  inherit fpga-mig-check;
}
