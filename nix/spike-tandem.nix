# nix/spike-tandem.nix
#
# Source-build the TANDEM-patched Spike that ships vendored inside the pinned CVA6
# tree, as its OWN cacheable derivation (a /nix/store path, not a runnable app —
# mirrors nix-small-cacheable-derivations). This is the piece that makes the
# dormant RVFI-vs-Spike lock-step (Phase 7) real.
#
# WHY source-build instead of nixpkgs' `pkgs.spike`: the tandem entry points
# (spike_create / spike_step_struct / the openhw Simulation/Params model) and the
# `st_rvfi` exchange struct are compiled INTO libriscv only by this patched tree
# (verif/core-v-verif/vendor/riscv/riscv-isa-sim). The prebuilt nixpkgs libriscv
# exports none of them and ships no tandem headers. The patched riscv.mk.in also
# compiles riscv_dpi.cc unconditionally and the tree builds with commitlog on, so
# `st_rvfi.rd1_wdata` is filled from the register-write log — exactly what
# rvfi_compare() checks against the core's RVFI. So "enable tandem" reduces to
# "make -lriscv resolve to THIS libriscv."
#
# Build recipe mirrors core-v-verif's own (mk/Common.mk:699-702): an out-of-tree
# `../configure --prefix=$out && make install` from a build/ subdir. No boost/DTC
# flags — the vendored tree bundles softfloat/fdt/yaml-cpp and core-v-verif builds
# it with a bare configure. We let it build its OWN patched libfesvr (the tandem
# patch adds fesvr_dpi.cc/SimDTM.cc to fesvr.mk.in); do NOT point --with-fesvr at
# another fesvr, to keep a single fesvr on any downstream link line.
#
{ pkgs, cva6-src }:

pkgs.stdenv.mkDerivation {
  pname = "spike-tandem";
  version = "cva6-v5.3.0-tandem";

  # dtc: spike compiles the generated device-tree at build/runtime; python3: a few
  # of spike's codegen scripts. The source comes from cva6-src (copied writable in
  # buildPhase — the store tree is read-only and configure/make write in place).
  dontUnpack = true;
  # cmake is only a tool the spike Makefile invokes for yaml-cpp; suppress the
  # nixpkgs cmake setup-hook that would otherwise hijack configurePhase.
  dontUseCmakeConfigure = true;
  # dtc/python3: spike's device-tree + codegen. yaml-cpp: the Params/Yaml config
  # path — we use nixpkgs' library instead of the tree's vendored copy (which only
  # builds under old cmake), so its headers/libs are on the compiler search path.
  nativeBuildInputs = [ pkgs.dtc pkgs.python3 ];
  buildInputs = [ pkgs.yaml-cpp ];

  # The tandem patch adds fesvr_dpi.cc / SimDTM.cc to libfesvr; they #include the
  # simulator DPI/VPI headers (svdpi.h, vpi_user.h), which ship with Verilator.
  # Put that dir on the C++ include search path (gcc honors CPLUS_INCLUDE_PATH).
  CPLUS_INCLUDE_PATH = "${pkgs.verilator}/share/verilator/include/vltstd";
  enableParallelBuilding = true;

  buildPhase = ''
    runHook preBuild
    # Preserve mode (configure + its helper scripts must stay executable), then
    # make the copy writable — the store tree is read-only.
    cp -r --no-preserve=ownership,timestamps \
      ${cva6-src}/verif/core-v-verif/vendor/riscv/riscv-isa-sim spike-src
    chmod -R u+w spike-src
    mkdir -p spike-src/build
    cd spike-src/build
    ../configure --prefix=$out

    # Pre-satisfy the Makefile's yaml-cpp target with the nixpkgs library. That
    # target (Makefile.in:127) has NO prerequisites, so make treats it as
    # up-to-date once the outputs exist and never invokes the vendored cmake
    # build (which only supports old cmake). -d keeps the .so version symlinks.
    mkdir -p $out/lib $out/include
    cp -d ${pkgs.yaml-cpp}/lib/libyaml-cpp.so* $out/lib/
    # --no-preserve=mode so these stay writable and postInstall can drop them
    # (store-copied files are read-only, and their dir would block the rm).
    cp -r --no-preserve=mode,ownership ${pkgs.yaml-cpp}/include/yaml-cpp $out/include/
    runHook postBuild
  '';

  # Install only the shared libraries (libriscv with the tandem DPI, libdisasm,
  # libfesvr, libcustomext) + headers + pkg-configs — NOT the spike/spike-dasm
  # executables (install-exes). We don't run the `spike` binary; the Verilator sim
  # loads libriscv via DPI. Skipping the executables also avoids the static
  # libyaml-cpp.a they alone would need (nixpkgs ships yaml-cpp shared-only).
  installPhase = ''
    runHook preInstall
    make -j"$NIX_BUILD_CORES" install-hdrs install-config-hdrs install-libs install-pc
    # Drop the yaml-cpp HEADERS we staged only to satisfy the spike build's make
    # dependency ($out/include/yaml-cpp). Keeping them would collide with the
    # separate yaml-cpp header tree that cva6-baseline.sh assembles into the CVA6
    # build prefix (cp -rs can't overwrite the read-only symlinks). libyaml-cpp.so
    # stays in $out/lib for the downstream -lyaml-cpp link.
    chmod -R u+w $out/include/yaml-cpp
    rm -rf $out/include/yaml-cpp
    runHook postInstall
  '';

  meta = {
    description = "Tandem-patched Spike (libriscv with RVFI DPI) from the pinned CVA6 tree";
  };
}
