# nix/parser-clang-slice.nix
#
# `nix run .#parser-clang-slice` — the Phase-7 C2 milestone: the Phase-0 slice
# (tests/cva6-parser/parser_slice.c) compiled through the parser-patched Clang using
# the mnemonic-form __builtin_riscv_prs_* builtins (-DPRS_USE_BUILTINS, via
# tests/cva6-parser/parser_builtins.h), then run on the standalone parser Spike over
# the 22-case packet corpus == the golden model. This is "the parser unit reachable
# from Clang WITHOUT inline asm" (§7.4).
#
# It reuses scripts/parser-spike.sh with SLICE=1 and the compiler hook pointed at
# Clang (SLICE_CC / SLICE_CC_EXTRA) — the SAME runner as parser-spike-slice (the
# intrinsics path), so the two authoring paths share one body and cannot drift. The
# 53-word byte-parity guard (parse_prog vs the model enc.hex) is the convergence
# oracle: builtins and intrinsics MUST encode identically, and both == the model ROM.
#
{ pkgs, spike-parser, parser-clang }:

let
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  name = "parser-clang-slice";

  # SC2329: the shared lib helpers + the per-case callback are invoked indirectly
  # (run_suite dispatch / cross-file), which shellcheck reads as dead.
  excludeShellChecks = [ "SC2329" ];

  runtimeInputs = [
    spike-parser
    pkgs.dtc           # spike shells out to `dtc` at startup to build its device tree
    parser-clang       # the parser-aware clang: compiles the slice via the prs.* builtins
    toolchain.gcc      # riscv64 cross gcc/ld: links cosim_main.S + slice.o + prog.S + case.S
    toolchain.binutils # riscv64 objdump: the byte-parity guard
    pkgs.gcc           # host cc: the golden-model vector generator
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.gawk
    pkgs.diffutils     # the byte-parity diff
    pkgs.findutils
  ];

  text = ''
    export SPIKE_PARSER="''${SPIKE_PARSER:-${spike-parser}}"
    export REPO_ROOT="''${REPO_ROOT:-$PWD}"
    export SLICE=1
    # Point the slice compiler hook at the parser-patched Clang + the builtins path.
    export SLICE_CC=clang
    export SLICE_CC_EXTRA="--target=riscv64-unknown-elf -DPRS_USE_BUILTINS"
    export SLICE_STAGE="Phase 7 C2 (Clang __builtin_riscv_prs_* slice)"
    export SLICE_SUITE_DESC="parser-clang-slice: Clang builtins slice -> flow_keys on the standalone parser Spike"
    export SLICE_SUITE_TAG="parser-clang-slice"
    export SLICE_PASS_MSG="== PASS: the Clang-builtins slice runs on the standalone Spike == the golden model (Phase 7 C2) =="
  '' + builtins.readFile ../scripts/lib/common.sh
     + builtins.readFile ../scripts/lib/suite.sh
     + builtins.readFile ../scripts/lib/cosim.sh
     + builtins.readFile ../scripts/parser-spike.sh;
}
