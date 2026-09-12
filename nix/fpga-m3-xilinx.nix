# nix/fpga-m3-xilinx.nix
#
# M3a verify-before-buy: prove stock CVA6 (cv64a6_imafdc_sv39) fits and ROUTES on
# Xilinx 7-series (xc7k325t / Digilent Genesys 2) with the fully open-source openXC7
# flow — no Vivado, no license, no board (docs/phase-8-status.md §"M3a — fit verdict").
#
#   nix run .#fpga-m3-xilinx-fit               chipdb -> synth -> pnr -> verdict
#   nix run .#fpga-m3-xilinx-fit -- chipdb     just build the nextpnr chip database
#   nix run .#fpga-m3-xilinx-fit -- synth      just synth_xilinx (LUT6/FF/DSP/BRAM + JSON)
#   nix run .#fpga-m3-xilinx-fit -- pnr        just nextpnr-xilinx place & route
#
# Kept in its OWN module (not nix/fpga-m3.nix) because it is a separate concern: a
# different toolchain (yosys+nextpnr-xilinx, all from nixpkgs), a different device
# family (Xilinx 7-series, not Gowin), and no microVM / no license — it is the
# open-source pivot check, whereas nix/fpga-m3.nix is the Gowin GW5AST-138 path.
#
# Same construction as the other runners: writeShellApplication (PATH via
# runtimeInputs + shellcheck at build time), body in scripts/, common.sh concatenated
# ahead so REPO_ROOT lives in one place. The nextpnr-xilinx store path is injected as
# NEXTPNR_XILINX so the script finds the bundled bbaexport.py + prjxray-db
# deterministically (same idiom as nix/fpga-m3.nix injecting CVA6_SRC).
#
# The elaborated CVA6 checkpoint (build/fpga-m3-core-rtl/elab.il) is produced by
# `nix run .#fpga-m3-core-rtl -- s2`; the fit script checks for it and says so if absent.
{ pkgs }:

let
  commonLib = builtins.readFile ../scripts/lib/common.sh;

  # openXC7 flow: yosys synth_xilinx, nextpnr-xilinx (+ bbasm) place & route, and pypy3
  # to run the bundled bbaexport.py (chip-database generator). nextpnr-xilinx also carries
  # the prjxray-db for our exact part under share/nextpnr/external.
  fpga-m3-xilinx-fit = pkgs.writeShellApplication {
    name = "fpga-m3-xilinx-fit";
    runtimeInputs = [
      pkgs.yosys pkgs.nextpnr-xilinx pkgs.pypy3
      pkgs.coreutils pkgs.gnugrep pkgs.gnused
    ];
    text = ''
      export NEXTPNR_XILINX="''${NEXTPNR_XILINX:-${pkgs.nextpnr-xilinx}}"
    '' + commonLib + builtins.readFile ../scripts/fpga-m3-xilinx-fit.sh;
  };
in
{
  inherit fpga-m3-xilinx-fit;
}
