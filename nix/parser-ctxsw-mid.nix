# nix/parser-ctxsw-mid.nix
#
# `nix run .#cva6-parser-ctxsw-mid` — build the parser-patched CVA6 model and run the
# M1 in-core MID-parse context-switch test (tests/cva6-parser/parser_ctxsw_mid.S): an
# async interrupt preempts an in-flight parse, the ISR saves/clobbers/restores the
# resumable position+data registers {p1,p2,p6,p7,p8 writable; p9 done read-only;
# p11,p13,p14,p15,p16} via the custom-3 move ABI, and the parse resumes to the golden
# model's byte-exact flow_keys (Table C;
# §3.1 item 4, register half; ratifies D7's mid-parse follow-on).
#
# Same composition as parser-ctxsw-v10.nix, but the test reuses the cosim vector
# generator, so it also prepends the shared common.sh (gen_vectors + rv_assemble +
# run_model). Reuse the cva6-baseline build body with the PATCHED source + the
# build/parser-core work dir, then append the M1 test body. One build path.
#
{ pkgs, cva6-src }:  # cva6-src here is the PATCHED tree (cva6-parser-src)

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  name = "cva6-parser-ctxsw-mid";

  # SC2329: the shared lib's helpers are invoked from the test body (cross-file),
  # which shellcheck reads as dead.
  excludeShellChecks = [ "SC2329" ];

  runtimeInputs = [
    pkgs.verilator
    pkgs.gnumake
    pkgs.gcc
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.gawk
    pkgs.findutils
    toolchain.gcc
    toolchain.binutils
    pkgs.spike
  ];

  text = ''
    export CVA6_SRC="''${CVA6_SRC:-${cva6-src}}"
    export SPIKE_PREFIX="''${SPIKE_PREFIX:-${pkgs.spike}}"
    export YAMLCPP="''${YAMLCPP:-${pkgs.yaml-cpp}}"
    export CVA6_WORK="''${CVA6_WORK:-$PWD/build/parser-core}"
    export REPO_ROOT="''${REPO_ROOT:-$PWD}"
  '' + builtins.readFile ../scripts/lib/common.sh
     + builtins.readFile ../scripts/cva6-baseline.sh
     + builtins.readFile ../scripts/parser-ctxsw-mid.sh;
}
