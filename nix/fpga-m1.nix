# nix/fpga-m1.nix
#
# Phase-8 milestone M1 targets: the parser datapath alone on the Tang Mega, fed one
# ROM-baked packet, streaming flow_keys over UART (docs/phase-8-fpga.md §8.4).
#
#   nix run .#fpga-m1-roms             generate roms/m1/*.hex from the golden model
#   nix run .#fpga-m1-roms -- --check  drift-guard the committed ROM images
#   nix run .#fpga-m1-rtl              sv2v-flatten the RTL -> build/fpga-m1-rtl/parser_m1.v
#   nix run .#fpga-build -- m1         synthesize the design (existing microVM bridge)
#   nix run .#fpga-m1-check            read the board's UART, diff vs libparsermodel
#
# Kept OUT of nix/fpga.nix on purpose: fpga.nix is the durable board bring-up loop
# (detect/load/flash/build/uart), which every design reuses. M1 is design-specific
# (its ROM generator + its result oracle), so it lives in its own module — same split
# the repo already makes between nix/rtl.nix and the per-milestone helpers.
#
# Same construction as the other runners: writeShellApplication (PATH via
# runtimeInputs + shellcheck at build time) with the body in scripts/, and a shared
# lib concatenated ahead of it so paths/board-constants live in exactly one place:
#   fpga-m1-roms  <- scripts/lib/common.sh (REPO_ROOT/MODEL/VERIF + gen_vectors)
#   fpga-m1-check <- scripts/lib/fpga.sh   (FPGA_UART + fpga_perm_hint)
{ pkgs }:

let
  commonLib = builtins.readFile ../scripts/lib/common.sh;
  fpgaLib   = builtins.readFile ../scripts/lib/fpga.sh;

  # Regenerate the M1 ROM images from libparsermodel (the single source of truth),
  # or --check that the committed roms/m1 has not drifted — the same guarantee
  # nix/parser-gen.nix (parser-gen-check) gives the Phase-7 codegen.
  fpga-m1-roms = pkgs.writeShellApplication {
    name = "fpga-m1-roms";
    runtimeInputs = [ pkgs.gcc pkgs.coreutils pkgs.diffutils pkgs.gnused pkgs.findutils ];
    text = commonLib + builtins.readFile ../scripts/fpga-m1-roms.sh;
  };

  # Flatten the M1 SystemVerilog to plain Verilog with sv2v so GowinSynthesis can
  # synthesize it (its SV front end aborts on our packed structs with SP00018).
  # Same tool the formal flow uses; output is a build artifact, not committed.
  fpga-m1-rtl = pkgs.writeShellApplication {
    name = "fpga-m1-rtl";
    runtimeInputs = [ pkgs.haskellPackages.sv2v pkgs.yosys pkgs.gnused pkgs.coreutils pkgs.gnugrep ];
    text = commonLib + builtins.readFile ../scripts/fpga-m1-rtl.sh;
  };

  # The M1 host oracle: read the board's UART and diff the streamed flow_keys against
  # the golden vectors byte-for-byte. python3 does the frame parse + comparison; stty
  # does the port setup (no pyserial), mirroring nix/fpga.nix's fpga-uart.
  fpga-m1-check = pkgs.writeShellApplication {
    name = "fpga-m1-check";
    runtimeInputs = [ pkgs.python3 pkgs.coreutils pkgs.gnused ];
    # fpgaLib defines ofl/fpga_preflight/fpga_resolve_fs for the other runners; this
    # one only uses FPGA_UART + fpga_perm_hint, so the rest read as "never invoked".
    excludeShellChecks = [ "SC2329" ];
    text = fpgaLib + builtins.readFile ../scripts/fpga-m1-check.sh;
  };
in
{
  inherit fpga-m1-roms fpga-m1-rtl fpga-m1-check;
}
