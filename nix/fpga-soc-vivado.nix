# nix/fpga-soc-vivado.nix
#
# Phase-A verify-before-buy: drive CVA6's TURNKEY full Vivado flow (synth -> impl
# -> routed bitstream -> timing) for the whole SoC + DDR3 + peripherals on the
# exact AX7325B / Genesys 2 die (xc7k325tffg900-2), with NO board. Where
# fpga-m3-vivado-fit measured only out-of-context *core* LUTs, this proves the
# full design ROUTES and CLOSES TIMING on the die, and that our FHS-boxed Vivado
# drives the entire make (MIG IP gen, read_ip, place, route, write_bitstream).
#
#   nix run .#fpga-soc-vivado                turnkey genesys2 build -> bit + timing
#   nix run .#fpga-soc-vivado -- clean       remove this target's build tree
#
# We build the STOCK pinned CVA6 tree (cva6-src), BOARD=genesys2 — the known-good
# turnkey path — to isolate "die/flow/license works" from "AX7325B port correct"
# (that port lands in a later phase). The bootrom is compiled by `make fpga`, so a
# bare-metal RISC-V toolchain (merged gcc+binutils prefix), dtc and python3 are
# injected alongside the shell utilities; Vivado stays the host dependency.
#
# HOST-TOOL DEPENDENCY (documented impurity, like the other Vivado targets): Vivado
# is NOT in nixpkgs — `vivado` on PATH (source settings64.sh) or $VIVADO; on NixOS
# use the FHS sandbox (nix run .#vivado-fhs). writeShellApplication keeps the
# inherited PATH; `nix run` passes the caller's runtime env through — no --impure.
{ pkgs, cva6-src }:

let
  commonLib = builtins.readFile ../scripts/lib/common.sh;

  # Bare-metal RISC-V toolchain (riscv64-none-elf-*, newlib), merged into ONE prefix
  # so the bootrom Makefile's $(RISCV)/bin/riscv64-none-elf-{gcc,objcopy,...} resolve.
  toolchain = pkgs.pkgsCross.riscv64-embedded.buildPackages;
  riscvPrefix = pkgs.symlinkJoin {
    name = "riscv64-none-elf-prefix";
    paths = [ toolchain.gcc toolchain.binutils ];
  };

  fpga-soc-vivado = pkgs.writeShellApplication {
    name = "fpga-soc-vivado";
    runtimeInputs = [
      pkgs.coreutils pkgs.gnused pkgs.gnugrep pkgs.findutils
      pkgs.gnumake pkgs.python3 pkgs.dtc
      toolchain.gcc toolchain.binutils
    ];
    # SC2329: the prepended common.sh defines shared helpers this script does not call,
    # which shellcheck reads as dead functions (same convention as nix/fpga-m1.nix et al.).
    excludeShellChecks = [ "SC2329" ];
    text = ''
      export CVA6_SRC="''${CVA6_SRC:-${cva6-src}}"
      export RISCV_TOOLCHAIN="''${RISCV_TOOLCHAIN:-${riscvPrefix}}"
    '' + commonLib + builtins.readFile ../scripts/fpga-soc-vivado.sh;
  };
in
{
  inherit fpga-soc-vivado;
}
