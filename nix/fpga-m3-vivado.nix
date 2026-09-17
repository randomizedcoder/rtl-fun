# nix/fpga-m3-vivado.nix
#
# M3a verify-before-buy, definitive LUT number: run Vivado synth-only on our ACTUAL
# CVA6 RTL and report a TRUSTWORTHY utilization (docs/phase-8-status.md
# §"Verify-before-buy"). This closes the one open thread the openXC7 flow left:
# `nix run .#fpga-m3-xilinx-fit` mapped stock CVA6 to ~628k LUTs — a ~12x abc9
# mapper-quality artifact, not the design's real size. Vivado is the only tool that
# gives a reliable LUT count for this arithmetic-heavy core; free WebPACK/ML Standard
# covers XC7A200T, whose 7-series LUT6 fabric is identical to the Genesys 2's XC7K325T,
# so an A200T synth certifies the fit with no board and no license cost.
#
#   nix run .#fpga-m3-vivado-fit             synth -> report -> verdict
#   nix run .#fpga-m3-vivado-fit -- synth    just Vivado synth_design -> util.rpt
#   nix run .#fpga-m3-vivado-fit -- report   re-print utilization + verdict
#
# Kept in its OWN module (a separate concern from nix/fpga-m3-xilinx.nix's open flow):
# it depends on the PROPRIETARY Vivado toolchain rather than the nixpkgs open flow.
#
# HOST-TOOL DEPENDENCY (documented impurity, like the Gowin path). Vivado is NOT in
# nixpkgs and cannot be pinned, so — exactly the VIVADO ?= vivado convention CVA6's own
# corev_apu/fpga/Makefile uses — this target locates Vivado on the host: `vivado` on
# PATH (source settings64.sh) or $VIVADO. Because free WebPACK/ML Standard is
# license-free for XC7A200T, there is no MAC-locked microVM (unlike Gowin) — a plain
# host-PATH `vivado -mode batch` wrapper suffices. writeShellApplication keeps the
# inherited PATH, so a host `vivado` stays findable; `nix run` passes the caller's
# runtime env through, so this needs no --impure.
#
# The sv2v'd CVA6 core (build/fpga-m3-core-rtl/cva6_core_sv2v.v) is produced by
# `nix run .#fpga-m3-core-rtl -- s0` — the SAME input the openXC7 flow used, giving a
# clean apples-to-apples Vivado-vs-abc9 comparison. The fit script checks for it and
# says so if absent.
{ pkgs }:

let
  commonLib = builtins.readFile ../scripts/lib/common.sh;

  # No toolchain injected via runtimeInputs — Vivado is the host dependency, located at
  # run time. Only the shell utilities the script itself uses are pinned.
  fpga-m3-vivado-fit = pkgs.writeShellApplication {
    name = "fpga-m3-vivado-fit";
    runtimeInputs = [
      pkgs.coreutils pkgs.gnugrep pkgs.gnused
    ];
    text = commonLib + builtins.readFile ../scripts/fpga-m3-vivado-fit.sh;
  };
in
{
  inherit fpga-m3-vivado-fit;
}
