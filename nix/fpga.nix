# nix/fpga.nix
#
# Board bring-up apps for the Sipeed Tang Mega 138K Pro (Gowin GW5AST-138), Phase 8.
#
#   nix run .#fpga-detect              scan the JTAG chain (first hardware contact)
#   nix run .#fpga-load  -- <fs>       program SRAM  (volatile, the inner loop)
#   nix run .#fpga-flash -- <fs>       program SPI flash (persistent)
#   nix run .#fpga-build               synthesize our design via Gowin in the microVM
#
# Same shape as nix/rtl.nix: writeShellApplication (PATH via runtimeInputs +
# shellcheck at build time) with the bodies in scripts/, and scripts/lib/fpga.sh
# concatenated ahead of each so the board constants live in exactly one place.
#
# Bitstream GENERATION is not here — it needs Gowin EDA, which runs in the microVM
# (nix/gowin-vm.nix, toolchain from nix/gowin-eda.nix). `fpga-build` is the bridge.
# The open-source Gowin flow (yosys/nextpnr/apicula) is deliberately absent:
# docs/fpga-platform-assessment.md §4 established that Apicula does not usably
# support GW5AST-138, so Gowin EDA is the only path to a .fs for this part.
{ pkgs, openfpgaloader-fork ? null }:

let
  lib = pkgs.lib;

  # Board constants + the ofl() wrapper + preflight checks, shared by all runners.
  fpgaLib = builtins.readFile ../scripts/lib/fpga.sh;

  # nixpkgs 1.1.1 (released 2026-03-11) is new enough for this board: it has the
  # tangmega138k board entry (2023-10), the GW5AST-138 IDCODE, and the Arora-V
  # SRAM erase/load fix ab8d8fc (2025-03-06). This is the default everywhere.
  openfpgaloader = pkgs.openfpgaloader;

  # The fork (randomizedcoder/openFPGALoader), built from the pinned flake input so
  # the reference tree is recorded in flake.lock rather than living only as an
  # untracked clone. It is NOT in the devShell and NOT used by the runners — swap it
  # in for one run when chasing a suspected openFPGALoader bug:
  #
  #   OPENFPGALOADER=$(nix build --no-link --print-out-paths .#openfpgaloader-fork)/bin/openFPGALoader \
  #     nix run .#fpga-detect
  #
  # Same build inputs as nixpkgs' package (pkgs/by-name/op/openfpgaloader).
  openfpgaloader-fork-pkg =
    if openfpgaloader-fork == null then null
    else openfpgaloader.overrideAttrs (old: {
      version = "fork-${openfpgaloader-fork.shortRev or "dirty"}";
      src = openfpgaloader-fork;
    });

  mkRunner = { name, script, extraInputs ? [ ] }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        openfpgaloader
        pkgs.usbutils # lsusb, for the preflight "is the board even there" check
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
      ] ++ extraInputs;
      text = fpgaLib + builtins.readFile script;
    };

  fpga-detect = mkRunner {
    name = "fpga-detect";
    script = ../scripts/fpga-detect.sh;
  };

  fpga-load = mkRunner {
    name = "fpga-load";
    script = ../scripts/fpga-load.sh;
  };

  fpga-flash = mkRunner {
    name = "fpga-flash";
    script = ../scripts/fpga-flash.sh;
  };

  # Read the board's UART — the second FT2232 interface. Auto-detects the baud,
  # because Sipeed document a firmware bug that rescales it by 4x. python3 only
  # scores printable-ASCII ratio; no pyserial, stty does the port setup.
  fpga-uart = mkRunner {
    name = "fpga-uart";
    script = ../scripts/fpga-uart.sh;
    extraInputs = [ pkgs.python3 pkgs.coreutils ];
  };

  # Drives the Gowin microVM. Needs `nix` on PATH because the VM runner is
  # evaluated with --impure (it reads GOWIN_VM_LOCAL); see scripts/fpga-build.sh.
  # Does not use fpgaLib — it never touches the board.
  fpga-build = pkgs.writeShellApplication {
    name = "fpga-build";
    runtimeInputs = [ pkgs.nix pkgs.coreutils pkgs.findutils ];
    text = builtins.readFile ../scripts/fpga-build.sh;
  };

  # A known-good VENDOR bitstream, hash-pinned. Loading a bitstream we did not
  # build separates "our programming path works" from "our RTL works" — the whole
  # point of Step 4 in the bring-up ladder.
  #
  # The upstream repo ships led/led.fs.7z prebuilt, so no Gowin run is needed.
  tang-mega-examples = pkgs.fetchFromGitHub {
    owner = "sipeed";
    repo = "TangMega-138KPro-example";
    # Pinned, not "main" — a moving ref would silently change what we program.
    rev = "d3cebf1703f1bcd06dca8a53bf2b660c86a5ec16";
    hash = "sha256-QXTK1jlUnO8RCS4WS7Ut159rqaMOP+r+R6LriepYaNw=";
  };

  tang-mega-led-bitstream = pkgs.stdenv.mkDerivation {
    pname = "tang-mega-led-bitstream";
    version = "vendor";
    src = tang-mega-examples;
    nativeBuildInputs = [ pkgs.p7zip ];
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      7z x led/led.fs.7z -o.
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      # The archive's internal name is not guaranteed; normalize to led.fs.
      found=$(find . -maxdepth 2 -name '*.fs' -type f | head -1)
      test -n "$found" || { echo "no .fs inside led.fs.7z" >&2; exit 1; }
      cp "$found" "$out/led.fs"
      runHook postInstall
    '';
    meta = {
      description = "Sipeed's prebuilt 6-LED demo bitstream for the Tang Mega 138K Pro";
      homepage = "https://github.com/sipeed/TangMega-138KPro-example";
      license = lib.licenses.asl20;
    };
  };
in
{
  inherit fpga-detect fpga-load fpga-flash fpga-build fpga-uart;
  inherit tang-mega-examples tang-mega-led-bitstream;
  inherit openfpgaloader;
}
// lib.optionalAttrs (openfpgaloader-fork-pkg != null) {
  openfpgaloader-fork = openfpgaloader-fork-pkg;
}
