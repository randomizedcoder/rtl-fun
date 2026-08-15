# nix/cva6.nix
#
# Pinned source of the CVA6 base core (OpenHW Group), fetched via Nix so every
# contributor and CI gets the identical tree. We extend this core with the parser
# unit (ADR-001 / phase-0-scope-and-stack.md §0.2).
#
# We fetch the *source* reproducibly here and build the Verilator sim
# imperatively inside `nix develop` (CVA6's build is a large Makefile+Python flow
# that expects a writable tree and $RISCV toolchain; packaging it as a pure
# derivation is deferred). Copy $CVA6_SRC into a writable workdir to build:
#
#   cp -r --no-preserve=mode "$CVA6_SRC" cva6 && cd cva6
#   export RISCV=... CV_SW_PREFIX=riscv64-none-elf-
#   make verilate
#
# Pin: v5.3.0 (tag -> commit 2ef1c1b1fca419354920c5487293bc605294904e).
# fetchSubmodules: CVA6's Verilator target needs its git submodules.
{ pkgs }:

pkgs.fetchFromGitHub {
  owner = "openhwgroup";
  repo = "cva6";
  rev = "2ef1c1b1fca419354920c5487293bc605294904e"; # v5.3.0
  fetchSubmodules = true;
  # Discover with: nix build .#cva6-src (nix prints the correct sha256 on mismatch)
  hash = "sha256-Z39Q3CAbgT1VUv83RcnNwbO2EP/HkUcxhOrQbfiOzbs=";
}
