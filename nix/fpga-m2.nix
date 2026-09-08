# nix/fpga-m2.nix
#
# Phase-8 milestone M2 targets: host <-> FPGA over the (now full-duplex) debug UART.
# The RX pin (host -> FPGA) is N16, found in the board schematic and confirmed on
# silicon by the loopback below (docs/phase-8-fpga.md §8.4, status challenge #15).
#
#   nix run .#fpga-build -- m2loop            build the loopback bitstream (microVM)
#   nix run .#fpga-load  -- build/fpga-m2loop/impl/pnr   program it (SRAM)
#   nix run .#fpga-m2-loopback-check          write a byte pattern, verify the echo
#   nix run .#fpga-m2-rtl                     sv2v-flatten m2_top -> build/fpga-m2-rtl/parser_m2.v
#   nix run .#fpga-build -- m2                synthesize the injection design (microVM)
#   FPGA_UART=/dev/ttyUSB2 nix run .#fpga-m2-inject [-- --suite]   inject + diff vs model
#
# Kept OUT of nix/fpga.nix for the same reason as nix/fpga-m1.nix: fpga.nix is the
# durable board bring-up loop (detect/load/flash/build/uart) that every design reuses;
# the per-milestone host oracles live in their own modules. Synthesis itself reuses the
# existing fpga-build bridge (design selection is "is there an <name>.tcl"), so there is
# no new build target here.
#
# Same construction as the other runners: writeShellApplication (PATH via runtimeInputs
# + shellcheck at build time) with the body in scripts/, and scripts/lib/fpga.sh
# concatenated ahead of it so the board constants (FPGA_UART, fpga_perm_hint) live in
# exactly one place.
{ pkgs }:

let
  commonLib = builtins.readFile ../scripts/lib/common.sh;
  fpgaLib   = builtins.readFile ../scripts/lib/fpga.sh;

  # Rung 0 of M2: prove N16 is the host->FPGA UART pin. The m2loop bitstream echoes
  # N16 back out P15; this writes a 256-byte pattern down /dev/ttyUSB1 and checks the
  # whole thing returns. python3 does the full-duplex read/write; stty sets the port up.
  fpga-m2-loopback-check = pkgs.writeShellApplication {
    name = "fpga-m2-loopback-check";
    runtimeInputs = [ pkgs.python3 pkgs.coreutils ];
    # fpgaLib defines ofl/fpga_preflight/fpga_resolve_fs for the other runners; this one
    # only uses FPGA_UART + fpga_perm_hint, so the rest read as "never invoked".
    excludeShellChecks = [ "SC2329" ];
    text = fpgaLib + builtins.readFile ../scripts/fpga-m2-loopback-check.sh;
  };

  # Flatten m2_top (SystemVerilog parser + UART injection) to plain Verilog for
  # GowinSynthesis — same sv2v -> yosys route as fpga-m1-rtl (the SP00018 workaround).
  # Output is a build artifact, not committed.
  fpga-m2-rtl = pkgs.writeShellApplication {
    name = "fpga-m2-rtl";
    runtimeInputs = [ pkgs.haskellPackages.sv2v pkgs.yosys pkgs.gnused pkgs.coreutils pkgs.gnugrep ];
    text = commonLib + builtins.readFile ../scripts/fpga-m2-rtl.sh;
  };

  # The M2 host oracle: frame each packet, send it to the FPGA, read the flow_keys
  # reply and diff it byte-for-byte against the model (baseline case, or --suite for all
  # 22). Needs common.sh (gen_vectors, which builds/runs the model -> gcc) AND fpga.sh
  # (FPGA_UART + fpga_perm_hint); python3 drives the serial read/write, no pyserial.
  fpga-m2-inject = pkgs.writeShellApplication {
    name = "fpga-m2-inject";
    runtimeInputs = [ pkgs.python3 pkgs.gcc pkgs.coreutils pkgs.gnused pkgs.findutils pkgs.diffutils ];
    excludeShellChecks = [ "SC2329" ];
    text = commonLib + fpgaLib + builtins.readFile ../scripts/fpga-m2-inject.sh;
  };
in
{
  inherit fpga-m2-loopback-check fpga-m2-rtl fpga-m2-inject;
}
