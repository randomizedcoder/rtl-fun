# nix/cva6-parser-rearm.nix
#
# `nix run .#cva6-parser-rearm` — build the parser-patched CVA6 model and run the
# in-core MULTI-PACKET re-arm test on it (D6 Increment 2): boot ONCE and parse the
# first REARM_CORPUS_MAX xdp2 corpus packets by re-arming the parser FU between them,
# comparing each packet's flow_keys + exit code BYTE-FOR-BYTE to the golden model.
#
# Where cva6-parser-cosim boots one ELF per packet (each a fresh, one-shot parse on
# the RTL model), this proves the FU itself re-arms: cva6_parser_wrap's new
# parse_rearm_i (pulsed by a ParseLen MMIO store, threaded ariane->cva6->ex_stage in
# mmio.patch) re-inits the parse cursor + metadata frame between packets while the CAM
# persists. It is the RTL companion to cva6-parser-nic-cosim (which runs the SAME
# nic_ring driver on Spike+QEMU over the whole corpus).
#
# Like cva6-parser-cosim.nix it reuses the SAME build body as cva6-baseline
# (scripts/cva6-baseline.sh) with the PATCHED source + a dedicated work dir, so the
# model is built (or refreshed incrementally) exactly as `nix run .#cva6-parser`
# would; then it injects the pinned xdp2 corpus (xdp2-src, as cva6-parser-nic-cosim /
# model.nix do) and appends the test body (scripts/cva6-parser-rearm.sh). Kept small by
# default (REARM_CORPUS_MAX=8) because the cycle-accurate RTL model is slow.
#
{ pkgs, cva6-src, xdp2-src }:  # cva6-src here is the PATCHED tree (cva6-parser-src)

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
  corpus = "${xdp2-src}/samples/proto_audit/pcap_templates";
in
pkgs.writeShellApplication {
  name = "cva6-parser-rearm";

  # SC2329: the shared lib's helpers are invoked indirectly / cross-file, which
  # shellcheck reads as dead (same convention as the other cosim targets).
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
    export CORPUS_DIR="''${CORPUS_DIR:-${corpus}}"
    export REPO_ROOT="''${REPO_ROOT:-$PWD}"
  '' + builtins.readFile ../scripts/lib/common.sh
     + builtins.readFile ../scripts/lib/suite.sh
     + builtins.readFile ../scripts/lib/cosim.sh
     + builtins.readFile ../scripts/cva6-baseline.sh
     + builtins.readFile ../scripts/cva6-parser-rearm.sh;
}
