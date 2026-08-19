# nix/parser-gen.nix
#
# Phase 7 §7.6 codegen spine. `tools/parser-gen` reads isa/parser-opcodes.yaml
# (the single source of bits) and emits toolchain/generated/ (the binutils opcode
# fragment + the parser_intrinsics.h word-builders). This app re-runs the generator
# and proves the committed artifacts are byte-stable AND that the generated encoders
# still match the model's hand-written encoders + golden constants
# (verif/gen/parser_gen_check.c) — the yaml↔C drift guard.
#
#   nix run .#parser-gen-check     regenerate + verify (no in-tree writes)
#
{ pkgs }:

let
  # python with PyYAML for the generator; gcc for the drift-check harness.
  pyenv = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);

  parser-gen-check = pkgs.writeShellApplication {
    name = "parser-gen-check";
    runtimeInputs = [ pyenv pkgs.gcc pkgs.coreutils pkgs.diffutils ];
    text = ''
      export PARSER_GEN_PY="${pyenv}/bin/python3"
    '' + builtins.readFile ../scripts/parser-gen-check.sh;
  };
in
{
  inherit parser-gen-check;
}
