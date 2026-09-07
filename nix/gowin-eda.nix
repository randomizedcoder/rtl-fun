# nix/gowin-eda.nix
#
# The proprietary Gowin EDA installers, as store paths (Phase 8).
#
# Why this exists: the Gowin install used to be a hand-extracted directory that
# existed on exactly one machine (`l`:/home/das/gowin-eda) and was described by no
# expression, so moving to hp5 meant re-deriving it from memory. Now the toolchain
# is a derivation like everything else — `gowinInstall` in nix/gowin/local.nix
# points at a store path and any host can reproduce it.
#
# The tarballs cannot be fetched (proprietary, login-walled, and gitignored — see
# /downloads/ in .gitignore), so `requireFile` is the right nixpkgs pattern: it
# refuses to guess and instead prints the exact `nix-store --add-fixed` command.
# Run that ONCE per machine, then these build offline forever.
#
#   nix-store --add-fixed sha256 downloads/Gowin_V1.9.11.03_Education_Linux.tar.gz
#   nix-store --add-fixed sha256 downloads/Gowin_V1.9.12.03_linux.tar.gz
#
# Both tarballs unpack to a top-level `IDE/`, which is exactly the layout
# nix/gowin-vm.nix expects at its /opt/gowin 9p mount — so `$out` is drop-in.
#
# WHICH ONE: use `gowin-eda` (COMMERCIAL). Settled 2026-09-07 by reading the device
# databases, and Sipeed's "138K Pro needs the commercial IDE 1.9.9+" turns out to be
# right:
#
#   Education 1.9.11.03  data/device/device_info.csv lists exactly two GW5AST rows,
#                        both GW5AST-LV138PG484AC1/I0 (the 484-pin NON-Pro package).
#                        It does ship the Pro's pin data
#                        (data/device/GW5AST-138B/FCPBGA676A.json), but with no
#                        FPG676 *order code* in the index, `set_device
#                        GW5AST-LV138FPG676AC1/I0` has nothing to resolve.
#   Commercial 1.9.12.03 has 10 FPG676 rows including gw5ast138b-007
#                        = GW5AST-LV138FPG676AC1/I0, the Tang Mega Pro part.
#
# So docs/gowin-microvm.md's "Education/NODELOCK license" conflates two things: the
# LICENSE is NODELOCK/STD (that part is right), but the IDE that produced the
# Tier-1 GO must have been the commercial tree. Education is kept packaged as
# evidence for this finding and for the smaller GW1N/GW2A parts it does cover.
#
# NOTE: these are NOT patchelf'd. The binaries are run inside the Gowin microVM via
# programs.nix-ld (see nix/gowin-vm.nix), which is why the vendor tree is used
# as-is; do not expect $out/IDE/bin/gw_sh to run directly on the host.
#
# UNFREE: Gowin EDA is proprietary, so these carry `license = unfree`. Rather than
# make every user export NIXPKGS_ALLOW_UNFREE — which would also break a plain
# `nix flake check` — we instantiate a private nixpkgs whose allowUnfreePredicate
# permits exactly these two packages and nothing else, so the blast radius is this
# file. (nix/gowin-vm.nix does the equivalent for the VM with allowUnfree.)
{ nixpkgs, system }:

let
  pkgs = import nixpkgs {
    inherit system;
    # Matches both the packages below and the requireFile `src` derivations, which
    # are named after the tarballs (Gowin_V1.9.12.03_linux.tar.gz). Case-insensitive
    # "gowin" prefix is narrow enough: nothing else in this closure is unfree.
    config.allowUnfreePredicate =
      pkg:
      let name = nixpkgs.lib.toLower (nixpkgs.lib.getName pkg);
      in nixpkgs.lib.hasPrefix "gowin" name;
  };

  mkGowin =
    { name, version, tarball, sha256, blurb }:
    pkgs.stdenv.mkDerivation {
      pname = name;
      inherit version;

      src = pkgs.requireFile {
        name = tarball;
        inherit sha256;
        message = ''
          ${blurb}

          This file is proprietary and cannot be fetched automatically. It is
          already present in this repo at:

              downloads/${tarball}

          Add it to the Nix store once with:

              nix-store --add-fixed sha256 downloads/${tarball}

          then re-run the build. (The tarball itself stays gitignored.)
        '';
      };

      # A ~1 GB vendor tree of prebuilt ELFs: no configure/build/patchelf, just
      # unpack and hand over. dontFixup keeps Nix from rewriting rpaths that the
      # vendor binaries resolve themselves via $ORIGIN/../lib.
      dontConfigure = true;
      dontBuild = true;
      dontFixup = true;
      dontPatchELF = true;
      dontStrip = true;

      sourceRoot = ".";

      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        cp -a IDE "$out/"
        test -x "$out/IDE/bin/gw_sh" || {
          echo "ERROR: $out/IDE/bin/gw_sh missing after unpack — tarball layout changed?" >&2
          exit 1
        }
        runHook postInstall
      '';

      meta = {
        description = "Gowin EDA (${blurb})";
        homepage = "https://www.gowinsemi.com/en/support/home/";
        license = pkgs.lib.licenses.unfree;
        platforms = [ "x86_64-linux" ];
      };
    };
in
{
  # Education edition. CANNOT target the Tang Mega 138K Pro — its device_info.csv
  # has no FPG676 order code (see the header). Kept for the record and for the
  # GW1N/GW2A parts it does cover.
  gowin-eda-edu = mkGowin {
    name = "gowin-eda-edu";
    version = "1.9.11.03";
    tarball = "Gowin_V1.9.11.03_Education_Linux.tar.gz";
    sha256 = "1xzr8va3044n2zjx1n1mp8k1hnaw31xdrszqnr3xh91v8zvr5lvg";
    blurb = "V1.9.11.03 Education";
  };

  # Commercial edition — THE ONE TO USE for this board. Point `gowinInstall` in
  # nix/gowin/local.nix at this store path.
  gowin-eda = mkGowin {
    name = "gowin-eda";
    version = "1.9.12.03";
    tarball = "Gowin_V1.9.12.03_linux.tar.gz";
    sha256 = "0lfb5qhhal14vk4ia307lrbk9jp0n5lir48s34ixldq3zn7hmxjc";
    blurb = "V1.9.12.03 commercial";
  };
}
