# nix/qemu-parser.nix
#
# Source-build a QEMU whose `qemu-system-riscv64` understands the parser ISA —
# the QEMU leg of the Phase 7 exit criterion (`nix run .#parser-qemu[-slice]`).
# Mirrors the Spike leg (nix/spike-parser.nix): teach an upstream ISA simulator
# the custom-0/custom-3 parser ops + the 0x5000_0000 packet MMIO device by reusing
# the pure-C golden model (model/libparsermodel) unchanged, then run the SAME
# self-checking bare-metal ELFs on it.
#
# Built from nixpkgs `qemu` (11.0.3) via override + overrideAttrs, restricted to
# the riscv64-softmmu target (huge build-time cut). The injection style mirrors
# nix/parser-binutils.nix (overrideAttrs + patches) and nix/spike-parser.nix
# (cp the model + our C into the tree, substituteInPlace the upstream files):
#
#   * target/riscv/parser_helper.c   — the two TCG helpers (port of parser_ext.cc)
#   * target/riscv/parser_mmio.c/.h  — the packet MMIO device (port of parser_mmio.h)
#   * target/riscv/parser_shared.h   — the shared mailbox
#   * target/riscv/trans_parser.c.inc— decode -> helper glue
#   * model/libparsermodel/{parser,program,encoding}.c -> target/riscv/, encoding
#     renamed parsermodel_encoding.* (QEMU has no encoding.h clash, but keep the
#     Spike convention; the model is built as a -w static lib so QEMU's stricter
#     -Werror set can't fail on plain-C11 the model's own -Wall/-Wextra passes).
#
# Why -M spike at run time (see scripts/parser-qemu.sh): that machine wires HTIF
# (tohost=1 -> exit 0) and puts DRAM at 0x80000000, so the existing ELFs run
# unmodified and the runner gates purely on the process exit code, exactly like
# the Spike leg. 0x5000_0000 is unmapped on that machine (no carve needed).
#
{ pkgs, qemuExt, modelSrc }:

(pkgs.qemu.override { hostCpuTargets = [ "riscv64-softmmu" ]; }).overrideAttrs (old: {
  pname = "qemu-parser";

  # Restricting to riscv64-softmmu leaves nixpkgs' `bin/qemu-kvm` symlink pointing at
  # the (unbuilt) host qemu-system-x86_64. Drop the useless symlink and skip the
  # dangling-symlink check — we only ship qemu-system-riscv64.
  dontCheckForBrokenSymlinks = true;
  postInstall = (old.postInstall or "") + ''
    rm -f "$out/bin/qemu-kvm"
  '';

  postPatch = (old.postPatch or "") + ''
    # --- inject the reused pure-C model + our QEMU-native TUs into target/riscv/ ---
    cp ${modelSrc}/parser.c ${modelSrc}/program.c ${modelSrc}/parser.h target/riscv/
    cp ${modelSrc}/encoding.c target/riscv/parsermodel_encoding.c
    cp ${modelSrc}/encoding.h target/riscv/parsermodel_encoding.h
    cp ${qemuExt}/parser_helper.c ${qemuExt}/parser_mmio.c \
       ${qemuExt}/parser_mmio.h ${qemuExt}/parser_shared.h \
       ${qemuExt}/trans_parser.c.inc target/riscv/
    chmod -R u+w target/riscv
    # The model ships its own encoding.h; keep the Spike rename so it can never
    # shadow a QEMU header (and match parser_helper.c's include).
    substituteInPlace target/riscv/parsermodel_encoding.c \
      --replace '#include "encoding.h"' '#include "parsermodel_encoding.h"'

    # --- free the custom-3 (0x7b) opcode for the parser ---------------------------
    # QEMU maps opcode 0x7b (1111011) to the RV128 doubleword R-type ops
    # (addd/subd/muld/...). The parser ISA (CVA6) reuses 0x7b for its custom-3
    # coprocessor moves and aliases those exact encodings, so a parser_c3 pattern on
    # 0x7b overlaps them. Our target is rv64gc and the test ELFs never use RV128, so
    # remap those 10 R-type ops to the otherwise-unused custom-1 opcode (0x2b =
    # 0101011): this vacates 0x7b for parser_c3 while keeping every trans_* function
    # referenced by decodetree (so no -Werror=unused-function). RV128 is non-goal here.
    substituteInPlace target/riscv/insn32.decode \
      --replace '1111011 @r' '0101011 @r'

    # --- decodetree: two catch-all patterns for custom-0 (0x0b) / custom-3 (0x7b) --
    # 25 wildcard bits + 7 opcode bits; the trans functions read the full word from
    # ctx->opcode (custom-0 has a non-standard field layout). Neither opcode exists
    # in stock insn32.decode, so on unpatched QEMU they trap illegal (the negative
    # control). Appended at EOF (no overlap with existing patterns).
    {
      echo ""
      echo "# Phase 7 (QEMU leg): parser custom ops. Whole word read via ctx->opcode."
      echo "# 25 don't-care bits (dashes, like fence_i) + the 7-bit opcode."
      echo "parser_c0   ----- ----- ----- ----- ----- 0001011"
      echo "parser_c3   ----- ----- ----- ----- ----- 1111011"
    } >> target/riscv/insn32.decode

    # --- helper prototypes ---
    {
      echo ""
      echo "/* Phase 7 (QEMU leg): parser custom instructions. */"
      echo "DEF_HELPER_3(parser_c0, tl, env, i32, tl)"
      echo "DEF_HELPER_2(parser_c3, void, env, i32)"
    } >> target/riscv/helper.h

    # --- translate.c: pull in the trans glue after the last trans include ---
    substituteInPlace target/riscv/translate.c \
      --replace '#include "insn_trans/trans_rvbf16.c.inc"' \
                '#include "insn_trans/trans_rvbf16.c.inc"
#include "trans_parser.c.inc"          /* Phase 7 (QEMU leg): parser custom ops */'

    # --- meson: model as its own -w static lib; our native TUs in the target set --
    substituteInPlace target/riscv/meson.build \
      --replace "subdir('tcg')" \
                "riscv_ss.add(files('parser_helper.c', 'parser_mmio.c'))
libparsermodel = static_library('parsermodel',
  files('parser.c', 'program.c', 'parsermodel_encoding.c'),
  c_args: ['-w'])                # model is -Wall/-Wextra clean; QEMU adds -Werror extras
riscv_ss.add(declare_dependency(link_with: libparsermodel))
subdir('tcg')"

    # --- machine: map the parser MMIO device at 0x5000_0000 on -M spike ---
    substituteInPlace hw/riscv/spike.c \
      --replace '#include "target/riscv/cpu.h"' \
                '#include "target/riscv/cpu.h"
#include "target/riscv/parser_mmio.h"   /* Phase 7 (QEMU leg): packet device */'
    substituteInPlace hw/riscv/spike.c \
      --replace 'MemoryRegion *system_memory = get_system_memory();' \
                'MemoryRegion *system_memory = get_system_memory();
    parser_mmio_map(system_memory, 0x50000000ULL);  /* Phase 7 (QEMU leg) */'
  '';

  meta = (old.meta or { }) // {
    description = "QEMU with the RISC-V parser ISA extension + packet MMIO (riscv64-softmmu)";
  };
})
