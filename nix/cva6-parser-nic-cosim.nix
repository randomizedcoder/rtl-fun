# nix/cva6-parser-nic-cosim.nix
#
# `nix run .#cva6-parser-nic-cosim` — build a SINGLE self-checking ELF that parses
# the whole xdp2 packet corpus in ONE booted process by re-arming the parser FU
# between packets, and run it on BOTH functional sims (Spike primary, QEMU secondary)
# == the golden model (Phase 8 D6: multi-packet re-arm + NIC ring driver).
#
# The multi-packet twin of parser-spike / parser-qemu (one ELF per packet): it proves
# the software/logic is correct across a re-arming run, independent of silicon. Reuses
# the shared script libs (common.sh vector-gen + emit_prog_s from cosim.sh) so the
# corpus + goldens come from the SAME generator the per-packet suites use — here via
# the new `--corpus-blob` mode that packs the corpus into one C header (corpus_blob.h).
#
# Injects the same two built sims the per-leg targets use (spike-parser, qemu-parser)
# and the same pinned corpus (xdp2-src) as cva6-parser-tandem-campaign / model.nix, so
# the whole run is reproducible and lock-pinned.
#
{ pkgs, spike-parser, qemu-parser, xdp2-src }:

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
  corpus = "${xdp2-src}/samples/proto_audit/pcap_templates";
in
pkgs.writeShellApplication {
  name = "cva6-parser-nic-cosim";

  # SC2329: the shared lib helpers are invoked indirectly / cross-file, which
  # shellcheck reads as dead (same convention as the other cosim targets).
  excludeShellChecks = [ "SC2329" ];

  runtimeInputs = [
    spike-parser
    qemu-parser
    pkgs.dtc          # spike shells out to `dtc` at startup to build its device tree
    toolchain.gcc
    toolchain.binutils
    pkgs.gcc
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.gawk
    pkgs.findutils
  ];

  text = ''
    export SPIKE_PARSER="''${SPIKE_PARSER:-${spike-parser}}"
    export QEMU_PARSER="''${QEMU_PARSER:-${qemu-parser}}"
    export CORPUS_DIR="''${CORPUS_DIR:-${corpus}}"
    export REPO_ROOT="''${REPO_ROOT:-$PWD}"
  '' + builtins.readFile ../scripts/lib/common.sh
     + builtins.readFile ../scripts/lib/suite.sh
     + builtins.readFile ../scripts/lib/cosim.sh
     + builtins.readFile ../scripts/cva6-parser-nic-cosim.sh;
}
