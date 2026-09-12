# nix/fpga-m3.nix
#
# Phase-8 milestone M3 targets: a RISC-V host core (stock CVA6) on the Tang Mega
# (docs/phase-8-fpga.md §8.4). Split into two increments:
#   M3a "CVA6 fits"      — synthesize stock CVA6 with BSRAM inferred, within the device.
#   M3b "CVA6 boots"     — a minimal Gowin SoC prints hello over UART (added later).
#
# M3a targets (this cut):
#   nix run .#fpga-m3-core-rtl [-- s0|s1|s2]  prepare the CVA6 synth input (strategy ladder)
#   nix run .#fpga-build -- m3-core           synthesize + fit-check (existing microVM bridge)
#
# Kept OUT of nix/fpga.nix and nix/fpga-m1/m2 on purpose: fpga.nix is the durable board
# loop; fpga-m{1,2} are the parser milestones. M3 is the CVA6 milestone — its own concern,
# its own module. Same construction as the others: writeShellApplication (PATH via
# runtimeInputs + shellcheck at build time), body in scripts/, shared libs concatenated
# ahead so paths live in one place. The pinned CVA6 source is injected like
# nix/cva6-baseline.nix does, so the flist resolves against the exact tree cva6.nix pins.
{ pkgs, cva6-src }:

let
  commonLib = builtins.readFile ../scripts/lib/common.sh;

  # Stock CVA6, cleaned for GowinSynthesis (drops the sim-only instr tracer that
  # sv2v would otherwise pass through to Gowin). See nix/cva6-fpga.nix for why.
  cva6-fpga-src = import ./cva6-fpga.nix { inherit pkgs cva6-src; };

  # Prepare the stock-CVA6 synth input for GowinSynthesis. Unlike fpga-m{1,2}-rtl (sv2v ->
  # yosys FLATTEN, fine for the small parser), this keeps module hierarchy so Gowin can
  # infer BSRAM from CVA6's RAM leaves — the flatten is exactly what put 543 Kbit of cache
  # into flip-flops before (fpga-platform-assessment.md §5a). Output is a build artifact.
  fpga-m3-core-rtl = pkgs.writeShellApplication {
    name = "fpga-m3-core-rtl";
    runtimeInputs = [
      pkgs.haskellPackages.sv2v pkgs.yosys pkgs.python3
      pkgs.coreutils pkgs.gnused pkgs.gnugrep pkgs.findutils
    ];
    text = ''
      export CVA6_SRC="''${CVA6_SRC:-${cva6-fpga-src}}"
    '' + commonLib + builtins.readFile ../scripts/fpga-m3-core-rtl.sh;
  };
in
{
  inherit fpga-m3-core-rtl;
}
