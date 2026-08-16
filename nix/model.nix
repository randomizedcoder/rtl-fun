# nix/model.nix
#
# Golden-model apps (Phase 2): the parser reference model lives in ./model and is
# built imperatively from the working tree (we iterate on it constantly), so
# these are writeShellApplications — PATH via runtimeInputs + shellcheck at build
# time — rather than fixed derivations. Script bodies live in ./scripts/*.sh.
#
#   nix run .#model-test          run the unit + corpus smoke tests
#   nix run .#pm-trace [-- x.pcap] single-step a parse for debugging
#
# The packet corpus is the pinned xdp2 proto_audit pcap_templates (nix/xdp2.nix),
# injected as CORPUS_DIR so the corpus tests are reproducible.
#
{ pkgs, xdp2-src }:

let
  corpus = "${xdp2-src}/samples/proto_audit/pcap_templates";

  runtimeInputs = [
    pkgs.gcc
    pkgs.coreutils
  ];

  model-test = pkgs.writeShellApplication {
    name = "model-test";
    inherit runtimeInputs;
    text = ''
      export CORPUS_DIR="''${CORPUS_DIR:-${corpus}}"
    '' + builtins.readFile ../scripts/model-test.sh;
  };

  pm-trace = pkgs.writeShellApplication {
    name = "pm-trace";
    inherit runtimeInputs;
    text = builtins.readFile ../scripts/pm-trace.sh;
  };

  # Static analysis + sanitizers for the golden C model (cppcheck, gcc -fanalyzer,
  # clang-tidy, then an ASan/UBSan run of the test suite over the pinned corpus).
  model-analyze = pkgs.writeShellApplication {
    name = "model-analyze";
    runtimeInputs = [ pkgs.cppcheck pkgs.gcc pkgs.clang-tools pkgs.coreutils ];
    text = ''
      export CORPUS_DIR="''${CORPUS_DIR:-${corpus}}"
    '' + builtins.readFile ../scripts/model-analyze.sh;
  };

  # libFuzzer + ASan/UBSan fuzzing of the model on random packets.
  model-fuzz = pkgs.writeShellApplication {
    name = "model-fuzz";
    runtimeInputs = [ pkgs.clang pkgs.coreutils ];
    text = builtins.readFile ../scripts/model-fuzz.sh;
  };
in
{
  inherit model-test pm-trace model-analyze model-fuzz;
}
