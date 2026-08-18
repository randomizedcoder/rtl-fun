# nix/cva6-parser-tandem.nix
#
# `nix run .#cva6-parser-tandem` — build the parser-patched CVA6 model WITH the
# RVFI-vs-Spike lock-step enabled (SPIKE_TANDEM=1) and run the base-ISA directed
# slice under per-instruction tandem verification against Spike (Phase 7, Stage 0).
#
# Like the other cva6-parser-* apps it reuses the SAME build body as cva6-baseline
# (scripts/cva6-baseline.sh) with the PATCHED source, but with two differences from
# the cosim app:
#   1. SPIKE_PREFIX points at the source-built TANDEM Spike (nix/spike-tandem.nix),
#      whose libriscv carries the tandem DPI (spike_step_struct) + commitlog; the
#      verilate LDFLAGS link -lriscv against it.
#   2. SPIKE_TANDEM=1 flips the Makefile gate so the dormant tandem SV (the uvma/
#      uvmc RVFI packages + corev_apu/tb/common/spike.sv) compiles in, and tells
#      cva6-baseline.sh to skip its fesvr_dpi.cc injection (the tandem libfesvr
#      already carries those shims — see R2 in the Stage-0 plan).
# A dedicated work dir (build/parser-tandem) keeps this distinct +define+SPIKE_TANDEM
# verilate output from build/parser-core.
#
{ pkgs, cva6-src, spike-tandem }:  # cva6-src here is the PATCHED tree (cva6-parser-src)

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  name = "cva6-parser-tandem";

  # SC2329: shared-lib helpers are invoked indirectly / cross-file, which
  # shellcheck reads as dead.
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
    pkgs.dtc            # spike builds a device-tree at runtime
    toolchain.gcc
    toolchain.binutils
    spike-tandem        # the tandem-patched Spike (replaces pkgs.spike)
  ];

  text = ''
    export CVA6_SRC="''${CVA6_SRC:-${cva6-src}}"
    export SPIKE_PREFIX="''${SPIKE_PREFIX:-${spike-tandem}}"
    export YAMLCPP="''${YAMLCPP:-${pkgs.yaml-cpp}}"
    export CVA6_WORK="''${CVA6_WORK:-$PWD/build/parser-tandem}"
    export REPO_ROOT="''${REPO_ROOT:-$PWD}"
    export SPIKE_TANDEM=1
  '' + builtins.readFile ../scripts/lib/common.sh
     + builtins.readFile ../scripts/cva6-baseline.sh
     + builtins.readFile ../scripts/cva6-parser-tandem.sh;
}
