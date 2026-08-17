# nix/parser-config-wb.nix
#
# `nix run .#cva6-parser-config-wb` — the 2nd-config integration proof (gap G10, N6).
#
# Builds the parser-patched CVA6 model under a SECOND existing hardware config,
# cv64a6_imafdc_sv39_wb (the RV64GC write-back-cache variant — a different cache
# architecture / writeback-port arrangement than the default write-through
# cv64a6_imafdc_sv39), into its own work dir (build/parser-core-wb), then runs the
# in-core directed parser test on it. A green run (SUCCESS + the META/REDIRECT/CAM
# markers) proves the fu_t::PARSER integration — the extra writeback port, the
# NrWbPorts bookkeeping, the issue/commit wiring — holds under a different config,
# not just the one config it was developed against.
#
# Pure composition: the SAME three bodies as cva6-parser-test (common.sh +
# cva6-baseline.sh build + cva6-parser-test.sh), only with CVA6_TARGET and CVA6_WORK
# pointed at the wb config + a dedicated work dir. No second copy of any logic.
#
# (Superscalar / NrIssuePorts=2 is a separate deferred config — it needs a new cv64
# superscalar config pkg + validating the no-parser-on-issue-port-1 interlock; see
# verification-design §3.1. This closes the achievable single-issue 2nd-config axis.)
#
{ pkgs, cva6-src }:  # cva6-src here is the PATCHED tree (cva6-parser-src)

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  name = "cva6-parser-config-wb";

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
    pkgs.findutils
    toolchain.gcc
    toolchain.binutils
    pkgs.spike
  ];

  text = ''
    export CVA6_SRC="''${CVA6_SRC:-${cva6-src}}"
    export SPIKE_PREFIX="''${SPIKE_PREFIX:-${pkgs.spike}}"
    export YAMLCPP="''${YAMLCPP:-${pkgs.yaml-cpp}}"
    # The 2nd config: RV64GC write-back cache, in its own work dir so it never
    # collides with the default-config model under build/parser-core.
    export CVA6_TARGET="''${CVA6_TARGET:-cv64a6_imafdc_sv39_wb}"
    export CVA6_WORK="''${CVA6_WORK:-$PWD/build/parser-core-wb}"
    export REPO_ROOT="''${REPO_ROOT:-$PWD}"
    echo "== 2nd-config FU integration: building the patched model under $CVA6_TARGET =="
  '' + builtins.readFile ../scripts/lib/common.sh
     + builtins.readFile ../scripts/cva6-baseline.sh
     + builtins.readFile ../scripts/cva6-parser-test.sh;
}
