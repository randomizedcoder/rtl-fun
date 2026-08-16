# nix/cva6-baseline.nix
#
# Build a CVA6 Verilator model (Phase 0 task 4). Parameterised over the SOURCE so
# the SAME builder serves both:
#   cva6-baseline  — the stock pinned source   (nix run .#cva6-baseline)
#   cva6-parser    — the parser-patched source (nix run .#cva6-parser)
# giving an easy unpatched-vs-patched compare/validate. Each variant builds into
# its own work dir (cva6Work) so the two never collide under build/.
#
# Packaged with writeShellApplication so that (1) all tools are on PATH via
# runtimeInputs and (2) shellcheck runs at build time — a broken script fails the
# build instead of at runtime. The script *body* lives in scripts/cva6-baseline.sh
# (readable / editable); this wrapper injects the pinned store paths as env.
#
{ pkgs
, cva6-src
, name ? "cva6-baseline"
, cva6Work ? null    # CVA6_WORK override (defaults to $PWD/build inside the script)
}:

let
  # Bare-metal RISC-V toolchain (riscv64-none-elf-*, newlib).
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
in
pkgs.writeShellApplication {
  inherit name;

  runtimeInputs = [
    pkgs.verilator
    pkgs.gnumake
    pkgs.gcc # host g++ for the verilated C++ model
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.findutils
    toolchain.gcc
    toolchain.binutils
    pkgs.spike
  ];

  # Inject the pinned store paths (overridable for dev use); then run the body.
  text = ''
    export CVA6_SRC="''${CVA6_SRC:-${cva6-src}}"
    export SPIKE_PREFIX="''${SPIKE_PREFIX:-${pkgs.spike}}"
    export YAMLCPP="''${YAMLCPP:-${pkgs.yaml-cpp}}"
  '' + pkgs.lib.optionalString (cva6Work != null) ''
    export CVA6_WORK="''${CVA6_WORK:-${cva6Work}}"
  '' + builtins.readFile ../scripts/cva6-baseline.sh;
}
