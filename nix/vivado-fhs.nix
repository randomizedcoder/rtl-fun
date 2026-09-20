# nix/vivado-fhs.nix
#
# Run AMD/Xilinx Vivado (installer + tools) on NixOS. Vivado ships as pre-built FHS
# binaries — its bundled JRE and the tools link against libX11/libstdc++/… at standard
# /usr/lib paths that NixOS does not have, so the raw installer dies with
# `libX11.so.6: cannot open shared object file`. This wraps everything in a
# `buildFHSEnv` sandbox that provides those libraries at the expected paths.
#
# This is the NixOS analogue of the Gowin microVM (nix/gowin-vm.nix): a documented,
# reproducible impurity boundary for a proprietary host tool that cannot be pinned in
# nixpkgs. Unlike Gowin, Vivado's free ML Standard tier is not MAC-locked, so a plain
# FHS sandbox (no VM, no license server) is enough.
#
# Usage:
#   INSTALL (interactive GUI wizard — needs a running X/Wayland display):
#     nix run .#vivado-fhs
#     # then inside the FHS shell:
#     cd downloads
#     ./FPGAs_AdaptiveSoCs_Unified_*_Lin64.bin        # web installer (needs internet)
#     # pick: Vivado -> Vivado ML Standard (free) -> 7-Series only
#
#   RUN a command inside the sandbox (args after `--` are exec'd in the FHS env; if
#   $VIVADO_SETTINGS points at Vivado's settings64.sh it is sourced first, putting
#   `vivado` on PATH):
#     VIVADO_SETTINGS=/tools/Xilinx/2026.1/Vivado/settings64.sh \
#       nix run .#vivado-fhs -- vivado -version
#
# The M3a fit target consumes this via the `vivado` wrapper below (see
# nix/fpga-m3-vivado.nix / scripts/fpga-m3-vivado-fit.sh): set VIVADO to
# `${vivado-fhs-vivado}/bin/vivado` and VIVADO_SETTINGS to your settings64.sh.
{ pkgs }:

let
  # Libraries Vivado's installer JRE and the 7-series toolchain need at FHS paths.
  # Kept deliberately generous — a missing .so surfaces as a cryptic dlopen failure
  # deep in the GUI, so it is cheaper to over-provide than to iterate.
  targetPkgs = p: (with p; [
    # base runtime
    coreutils bash zsh gnugrep gnused gawk findutils which procps util-linux
    glibc (lib.getLib stdenv.cc.cc) zlib libuuid libxcrypt-legacy expat
    # ncurses: Vivado 2026.1's libxv_commontasks needs libncurses.so.5 (abi5 compat)
    # AND libxv_tcltasks needs libtinfo.so.6 (ncurses 6) — provide both, or `vivado
    # -mode batch` dies loading feature 'core'.
    ncurses5 ncurses
    # X11 (installer + Vivado GUI)
    libx11 libxext libxrender libxtst libxi
    libxft libxfixes libxrandr libxinerama libxcursor
    libxdamage libxcomposite libxscrnsaver
    libxcb libsm libice libxshmfence xkeyboard-config
    # GTK / font / rendering stack
    freetype fontconfig glib gtk2 gtk3 gdk-pixbuf pango cairo atk dbus
    libGL libGLU mesa nss nspr
    # Vivado's libnlview (netlist render, pulled in by feature 'core') needs these.
    pixman libpng
    # things Vivado shells out to
    graphviz unzip lsb-release nettools e2fsprogs
  ]);

  # Enter the FHS sandbox. With no args -> interactive bash (for the install wizard).
  # With args -> source $VIVADO_SETTINGS (if set) then exec them (for `vivado ...`).
  runScript = pkgs.writeShellScript "vivado-fhs-run" ''
    # The "LD trick": the FHS exposes the abi-compat ncurses libs as filename symlinks in
    # /usr/lib (libncurses.so.5, libtinfo.so.6), but ldconfig indexes them by SONAME
    # (libncursesw.*), so a DT_NEEDED for the exact filename misses the cache. Putting
    # /usr/lib on the search path lets Vivado's Tcl `load` of libxv_commontasks /
    # libxv_tcltasks resolve them by filename (feature 'core' fails otherwise).
    export LD_LIBRARY_PATH="/usr/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    if [ -n "''${VIVADO_SETTINGS:-}" ] && [ -f "''${VIVADO_SETTINGS:-}" ]; then
      # shellcheck disable=SC1090
      . "''${VIVADO_SETTINGS}"
    fi
    if [ "$#" -eq 0 ]; then
      exec bash
    else
      exec "$@"
    fi
  '';

  vivado-fhs = pkgs.buildFHSEnv {
    name = "vivado-fhs";
    inherit targetPkgs runScript;
  };

  # A single-word executable named `vivado` that runs the host-installed Vivado inside
  # the sandbox — so it drops straight into $VIVADO for scripts/fpga-m3-vivado-fit.sh
  # (which calls `command -v "$VIVADO"` then `"$VIVADO" -mode batch ...`). Requires
  # VIVADO_SETTINGS to point at the installed settings64.sh.
  vivado-fhs-vivado = pkgs.writeShellScriptBin "vivado" ''
    exec ${vivado-fhs}/bin/vivado-fhs vivado "$@"
  '';
in
{
  inherit vivado-fhs vivado-fhs-vivado;
}
