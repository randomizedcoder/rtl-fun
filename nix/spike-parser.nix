# nix/spike-parser.nix
#
# Source-build a RUNNABLE, standalone Spike that understands the parser ISA — the
# user-facing ISA simulator for Phase 7 Stage 2 (`nix run .#parser-spike`). Unlike
# its sibling nix/spike-tandem.nix (libraries-only, loaded via DPI by the CVA6
# Verilator tandem), this derivation installs the `spike`/`spike-dasm` EXECUTABLES
# so a bare parser ELF can be run directly and self-check via HTIF.
#
# SIBLING NOTE: this shares the parser MMIO device + reused C model with
# nix/spike-tandem.nix, but the injection target and a few patches DIFFER because we
# build a *runnable* exe, not just libs. The tandem loads libriscv via DPI (so its
# extension can live in a dlopened libcustomext); the standalone `spike` STATICALLY
# links libriscv.a, which forces four things the tandem doesn't need:
#   1. install-exes (build the spike binary), + LIBS_EXE links the SHARED yaml-cpp
#      (nixpkgs ships yaml-cpp shared-only; the vendored static libyaml-cpp.a needs an
#      ancient cmake).
#   2. The parser extension is compiled INTO libriscv (not libcustomext) — dlopening a
#      libcustomext that statically embeds riscv objects duplicates statics (e.g.
#      Processor::priv_ranges) and double-frees at exit. See the buildPhase comment.
#   3. A `parser_ext_keep()` reference from spike.cc force-links parser_ext.o out of the
#      static libriscv.a (nothing else references it, so it would be dropped).
#   4. Proc.cc activates the extension unconditionally (registered_extensions_v +
#      the `extensions` param default), since there's no UVM side to drive it.
# The `spike` main uses the openhw `Simulation` class, so the Simulation.cc device
# registration wires the 0x5000_0000 peripheral into the runnable binary.
#
# spike-tandem.nix is left byte-for-byte untouched so Phase-6 stays green.
#
{ pkgs, cva6-src, spikeExt, modelSrc }:

pkgs.stdenv.mkDerivation {
  pname = "spike-parser";
  version = "cva6-v5.3.0-parser";

  dontUnpack = true;
  dontUseCmakeConfigure = true;
  nativeBuildInputs = [ pkgs.dtc pkgs.python3 ];
  buildInputs = [ pkgs.yaml-cpp ];

  # fesvr_dpi.cc / SimDTM.cc (compiled into libfesvr by the vendored tree) #include
  # the simulator DPI/VPI headers (svdpi.h, vpi_user.h) that ship with Verilator.
  CPLUS_INCLUDE_PATH = "${pkgs.verilator}/share/verilator/include/vltstd";
  enableParallelBuilding = true;

  buildPhase = ''
    runHook preBuild
    cp -r --no-preserve=ownership,timestamps \
      ${cva6-src}/verif/core-v-verif/vendor/riscv/riscv-isa-sim spike-src
    chmod -R u+w spike-src

    # --- inject the parser extension DIRECTLY into libriscv (NOT libcustomext) --
    # WHY not customext: customext.mk.in's subproject_deps make libcustomext.so
    # statically EMBED copies of the riscv objects (Proc.o, extensions.o, ...). The
    # standalone `spike` links libriscv AND find_extension() would dlopen libcustomext,
    # so those statics (e.g. Processor::priv_ranges) exist TWICE -> double-destruct /
    # double-free at exit. Compiling parser_ext.cc + the reused C model straight into
    # libriscv gives ONE copy of everything, shares g_parser_shared with the
    # Simulation.cc MMIO device below, and REGISTER_EXTENSION registers "parser" at
    # libriscv load so find_extension() resolves it with no dlopen.
    # riscv/ has its OWN encoding.h (CAUSE_*, DECLARE_INSN); the model also ships an
    # encoding.h — so copy the model's in under a distinct name (parsermodel_encoding.*)
    # and redirect the model files' `#include "encoding.h"` to it, or we shadow riscv's
    # header and break every riscv TU. parser.c/parser.h have no riscv name clash.
    cp ${spikeExt}/parser_ext.cc spike-src/riscv/parser_ext.cc
    cp ${modelSrc}/parser.c ${modelSrc}/parser.h spike-src/riscv/
    cp ${modelSrc}/encoding.c spike-src/riscv/parsermodel_encoding.c
    cp ${modelSrc}/encoding.h spike-src/riscv/parsermodel_encoding.h
    chmod -R u+w spike-src/riscv
    substituteInPlace spike-src/riscv/parser_ext.cc spike-src/riscv/parsermodel_encoding.c \
      --replace '#include "encoding.h"' '#include "parsermodel_encoding.h"'
    # The `spike` exe statically links libriscv.a, so parser_ext.o (referenced by
    # nothing — its REGISTER_EXTENSION registrar is a file-static) would be dropped and
    # "parser" never registered. Export a keeper symbol here and reference it from
    # spike.cc (below) so the linker pulls parser_ext.o in and its static init runs.
    substituteInPlace spike-src/riscv/parser_ext.cc \
      --replace 'REGISTER_EXTENSION(parser, []() { return new parser_t; })' \
                'REGISTER_EXTENSION(parser, []() { return new parser_t; })
extern "C" void parser_ext_keep(void) {}   // Phase 7 Stage 2: force-link anchor'
    {
      echo ""
      echo "# Phase 7 Stage 2: parser ISA extension + the reused reference model,"
      echo "# compiled into libriscv (see nix/spike-parser.nix for the rationale)."
      echo "riscv_srcs += parser_ext.cc"
      echo "riscv_c_srcs += parser.c parsermodel_encoding.c"
    } >> spike-src/riscv/riscv.mk.in
    # The openhw processor (Proc.cc) activates extensions from the `extensions` param
    # gated by registered_extensions_v — NOT spike.cc's `--extension` flag. Set parser
    # TRUE so the standalone `spike` always activates it (the tandem uses false because
    # the UVM side drives the param). This registers the extension exactly once; passing
    # `--extension=parser` on top would register it twice (double free at teardown).
    substituteInPlace spike-src/riscv/Proc.cc \
      --replace 'registered_extensions_v["cvxif"] = false;' \
                'registered_extensions_v["cvxif"] = false;
  registered_extensions_v["parser"] = true;   // Phase 7 Stage 2: always-on standalone'
    # Default the `extensions` param to "parser" so the openhw activation loop also
    # picks it up (prints "[SPIKE] Activating extension: parser") — belt-and-suspenders
    # with the registered_extensions_v flag above.
    substituteInPlace spike-src/riscv/Proc.cc \
      --replace 'params.set_string(base, "extensions", "", "", "Possible extensions: cv32a60x, cvxif");' \
                'params.set_string(base, "extensions", "parser", "", "Possible extensions: cv32a60x, cvxif, parser");'

    # --- inject the parser MMIO packet device (0x5000_0000) --------------------
    # #included once in Simulation.cc (which owns the bus and DEFINES g_parser_shared)
    # and registered on the bus after the mem_t regions — exactly as the tandem does.
    # The standalone `spike` main uses this same openhw::Simulation, so this single
    # patch wires the peripheral into the runnable binary.
    cp ${spikeExt}/parser_shared.h ${spikeExt}/parser_mmio.h spike-src/riscv/
    chmod -R u+w spike-src/riscv
    substituteInPlace spike-src/riscv/Simulation.cc \
      --replace '#include "Simulation.h"' \
                '#include "Simulation.h"
#include "parser_mmio.h"          // Phase 7 Stage 2: parser packet MMIO device'
    # Carve the 4 KiB window out of any DRAM region that would otherwise span it
    # (openhw default DRAM is a 0x40000000 catch-all covering 0x50000000).
    substituteInPlace spike-src/riscv/Simulation.cc \
      --replace '  if (dram) {
    this->mems.push_back(std::make_pair(dram_base, new mem_t(dram_size)));
  }' \
                '  if (dram) {
    const uint64_t PW = 0x50000000UL, PWS = 0x1000UL;  // parser MMIO window
    if (dram_base <= PW && PW + PWS <= dram_base + dram_size) {
      this->mems.push_back(std::make_pair(dram_base, new mem_t(PW - dram_base)));
      this->mems.push_back(std::make_pair(PW + PWS, new mem_t(dram_base + dram_size - (PW + PWS))));
    } else {
      this->mems.push_back(std::make_pair(dram_base, new mem_t(dram_size)));
    }
  }'
    substituteInPlace spike-src/riscv/Simulation.cc \
      --replace 'for (auto &x : this->mems)
    bus.add_device(x.first, x.second);' \
                'for (auto &x : this->mems)
    bus.add_device(x.first, x.second);

  bus.add_device(0x50000000UL, new parser_mmio_dev());  // Phase 7 Stage 2'

    # Reference the parser_ext keeper from spike.cc (an explicit .o in the exe link) so
    # the linker pulls parser_ext.o out of the static libriscv.a — otherwise its
    # REGISTER_EXTENSION registrar is dropped and find_extension("parser") fails.
    substituteInPlace spike-src/spike_main/spike.cc \
      --replace '#include "YamlParamSetter.h"' \
                '#include "YamlParamSetter.h"
extern "C" void parser_ext_keep(void);   // Phase 7 Stage 2: parser extension anchor'
    substituteInPlace spike-src/spike_main/spike.cc \
      --replace 'std::vector<std::pair<reg_t, abstract_device_t*>> plugin_devices;' \
                'std::vector<std::pair<reg_t, abstract_device_t*>> plugin_devices;
  parser_ext_keep();   // Phase 7 Stage 2: force-link the parser extension'

    # --- link the standalone executables against the SHARED yaml-cpp -----------
    # install-exes appends $(install_libs_dir)/libyaml-cpp.a to LIBS_EXE; that static
    # archive only builds via the vendored (ancient-cmake) path. nixpkgs ships yaml-cpp
    # shared-only, so link the shared library instead (a buildInput -> NIX_LDFLAGS).
    # (The parser extension is compiled into libriscv above, so no dlopen/customext
    # linking is involved here.)
    substituteInPlace spike-src/Makefile.in \
      --replace '$(install_libs_dir)/libyaml-cpp.a' '-lyaml-cpp'

    mkdir -p spike-src/build
    cd spike-src/build
    ../configure --prefix=$out

    # Pre-satisfy the Makefile's prerequisite-less yaml-cpp target with the nixpkgs
    # library so make never invokes the vendored cmake build.
    mkdir -p $out/lib $out/include
    cp -d ${pkgs.yaml-cpp}/lib/libyaml-cpp.so* $out/lib/
    cp -r --no-preserve=mode,ownership ${pkgs.yaml-cpp}/include/yaml-cpp $out/include/
    runHook postBuild
  '';

  # Install the libs first, then the executables (install-exes) — the extra target the
  # tandem omits. Two make calls keeps the ordering explicit.
  installPhase = ''
    runHook preInstall
    make -j"$NIX_BUILD_CORES" install-hdrs install-config-hdrs install-libs install-pc
    make -j"$NIX_BUILD_CORES" install-exes
    # Drop the yaml-cpp headers we staged only to satisfy the make dependency.
    chmod -R u+w $out/include/yaml-cpp
    rm -rf $out/include/yaml-cpp
    runHook postInstall
  '';

  meta = {
    description = "Standalone parser-ISA Spike (runnable spike binary) from the pinned CVA6 tree";
  };
}
