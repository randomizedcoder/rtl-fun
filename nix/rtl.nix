# nix/rtl.nix
#
# Parser-unit RTL apps (Phase 5). The SystemVerilog parser unit (./rtl) is built
# and simulated imperatively from the working tree (we iterate on it constantly),
# so these are writeShellApplications — PATH via runtimeInputs + shellcheck at
# build time — rather than fixed derivations. One script body (scripts/parser-sim.sh)
# selects the debug level via PARSER_MODE, so the four targets share exactly one
# build+run path and cannot drift:
#
#   nix run .#parser-sim         optimized (-O3), run the smoke test (fast default)
#   nix run .#parser-sim-trace   + FST waveform (pstate_t/micro_op_t via --trace-structs)
#   nix run .#parser-sim-debug   -O0 -ggdb + waveform, for stepping in gdb
#   nix run .#parser-lint        --lint-only -Wall, no build (fast strict lint)
#
# The smoke test asserts the RTL flow_keys equals the golden model's, byte for
# byte, over a canned Ethernet/IPv4/TCP frame (vectors generated from the model).
#
{ pkgs }:

let
  runtimeInputs = [
    pkgs.verilator
    pkgs.gcc          # host cc for gen_parser_rom + the verilated C++ model
    pkgs.gnumake      # verilator --binary drives make
    pkgs.coreutils
  ];

  mkSim = mode: pkgs.writeShellApplication {
    name = if mode == "run" then "parser-sim"
           else if mode == "lint" then "parser-lint"
           else "parser-sim-${mode}";
    inherit runtimeInputs;
    text = ''
      export PARSER_MODE="${mode}"
    '' + builtins.readFile ../scripts/parser-sim.sh;
  };
in
{
  parser-sim       = mkSim "run";
  parser-sim-trace = mkSim "trace";
  parser-sim-debug = mkSim "debug";
  parser-lint      = mkSim "lint";
}
