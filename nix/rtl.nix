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
    # SC2329: the shared lib's helpers + the per-case callback are invoked
    # indirectly (run_suite dispatch / cross-file), which shellcheck reads as dead.
    excludeShellChecks = [ "SC2329" ];
    # Prepend the shared lib (common.sh + suite.sh) ahead of the body — same
    # concatenation model as cva6-baseline.sh, so no runtime path lookup.
    text = ''
      export PARSER_MODE="${mode}"
    '' + builtins.readFile ../scripts/lib/common.sh
       + builtins.readFile ../scripts/lib/suite.sh
       + builtins.readFile ../scripts/parser-sim.sh;
  };

  # Formal proof of parser_execute (SymbiYosys + yosys + z3). Combinational DUT,
  # so a 1-step BMC is an exhaustive proof over all inputs.
  parser-formal = pkgs.writeShellApplication {
    name = "parser-formal";
    # sv2v flattens our SystemVerilog to Verilog-2005 (yosys' builtin frontend
    # can't parse packed structs / typedef enums / automatic functions).
    runtimeInputs = [ pkgs.haskellPackages.sv2v pkgs.sby pkgs.yosys pkgs.z3 pkgs.coreutils ];
    text = builtins.readFile ../scripts/parser-formal.sh;
  };

  # Directed testbench for cva6_parser_wrap's commit-visible parser state (I1/G2):
  # rollback-on-flush + commit-advance + backpressure, with assertions on.
  parser-wrap-test = pkgs.writeShellApplication {
    name = "parser-wrap-test";
    inherit runtimeInputs;   # verilator + gcc + make + coreutils
    excludeShellChecks = [ "SC2329" ];  # shared-lib helpers invoked cross-file
    text = builtins.readFile ../scripts/lib/common.sh
         + builtins.readFile ../scripts/parser-wrap-test.sh;
  };

  # Static analysis: two more SV linters beyond Verilator -Wall (parser-lint).
  parser-analyze = pkgs.writeShellApplication {
    name = "parser-analyze";
    runtimeInputs = [ pkgs.verible pkgs.svlint pkgs.coreutils ];
    text = builtins.readFile ../scripts/parser-analyze.sh;
  };
in
{
  parser-sim        = mkSim "run";
  parser-sim-suite  = mkSim "suite";
  parser-sim-decode = mkSim "decode";
  parser-sim-trace  = mkSim "trace";
  parser-sim-debug  = mkSim "debug";
  parser-lint       = mkSim "lint";
  inherit parser-formal parser-analyze parser-wrap-test;
}
