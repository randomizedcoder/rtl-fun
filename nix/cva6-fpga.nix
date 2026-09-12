# nix/cva6-fpga.nix
#
# The STOCK CVA6 source, cleaned so a SystemVerilog-via-sv2v flow can synthesize it on
# the Gowin GW5AST-138 for the Phase-8 M3 FPGA milestone — its own small, cached
# derivation (same shape as nix/cva6-patched.nix, which does the parser MODEL). This is
# the source fpga-m3-core-rtl feeds to sv2v.
#
# Why a cleaned tree at all. M3a is deliberately STOCK CVA6 (no parser): it isolates the
# question "does a RV64GC core fit on the GW5AST-138 with BSRAM inferred?" and side-steps
# challenge #13 (SP00018), which is parser-specific. So it must NOT use the parser patches
# in nix/cva6-parser/. What it needs is one orthogonal, systematic transform:
#
#   strip-translate-off.py — remove every `// pragma translate_off .. translate_on` region
#     from the tree. A real synthesis front-end (Vivado/Quartus/GowinSynthesis) honors
#     those pragmas and skips the simulation-only text inside; sv2v does not, and lowers it
#     verbatim. In CVA6 that text is exactly what breaks the build:
#       * SyncDpRam.sv wraps `define SIMULATION in translate_off, so sv2v emits the RAM's
#         SIMULATION branch (mixed blocking/non-blocking init) rather than the clean
#         `ifndef SIMULATION synthesis branch -> yosys can't infer $mem and demotes the
#         array to flip-flops (0 BSRAM; the challenge-#16 mechanism).
#       * cva6.sv's mock instruction tracer (string/$fopen/$fwrite/$fclose),
#         SyncSpRamBeNx64.sv's SIM_INIT loop, cvfpu's $fatal/$finish defensive defaults,
#         and common_cells' `default disable iff` SVA all live in translate_off too, and
#         each is rejected by sv2v, yosys, or Gowin.
#     Stripping these regions gives sv2v the same synthesis view the vendor tools see.
#     (docs/phase-8-status.md M3a.)
#
#   tc_sram_wrapper{,_cache_techno}.sv — the upstream common/local/util wrappers ship as
#     EMPTY stubs (ports/params, no body), which Thales documents as "to be replaced by the
#     wrapper of the technology used to avoid having black box at synthesis". Left empty,
#     sv2v prunes the real RAM (tc_sram) as unreferenced and emits bodyless wrappers ->
#     yosys blackboxes them -> GowinSynthesis EX3937 ("unknown module ...tc_sram_wrapper").
#     We drop in filled versions that pass through to pulp-platform's generic inferrable
#     tc_sram, so the icache RAM has a real, BSRAM-inferrable body. (docs/phase-8-status.md
#     M3a; the dcache uses hpdcache_sram*, which already have real bodies.)
#
#   m3a-wbuf-depth.patch — reduce WtDcacheWbufDepth 8 -> 2 for cv64a6_imafdc_sv39. The
#     write-through D-cache's fully-associative coalescing write buffer (wt_dcache_wbuffer)
#     trips a numerical-robustness bug in GowinSynthesis V1.9.12.03's embedded ABC LUT-mapper
#     (If_CutAreaDerefed, ifCut.c:1109) — localized via the m3-cone subtree reproducer as the
#     sole M3a blocker (BSRAM inference is solved). Its associative-match/coalescing cone scales
#     with the buffer depth, so a shallower buffer shrinks exactly the logic that diverges ABC.
#     Depth is a microarchitectural perf knob (CVA6's own cv32a6_embedded ships depth 2), NOT an
#     ISA change — the core stays stock RV64GC cv64a6_imafdc_sv39. (docs/phase-8-status.md M3a.)
#
{ pkgs, cva6-src }:

pkgs.runCommand "cva6-fpga-src"
{
  nativeBuildInputs = [ pkgs.python3 pkgs.git ];
}
''
  cp -r --no-preserve=mode,ownership ${cva6-src} "$out"
  python3 ${./cva6-fpga/strip-translate-off.py} "$out"

  # Provide the "technology" SRAM wrappers upstream leaves empty (see header).
  cp ${./cva6-fpga/tc_sram_wrapper.sv}              "$out/common/local/util/tc_sram_wrapper.sv"
  cp ${./cva6-fpga/tc_sram_wrapper_cache_techno.sv} "$out/common/local/util/tc_sram_wrapper_cache_techno.sv"

  # Shrink the WT D-cache coalescing write-buffer so GowinSynthesis's ABC LUT-mapper does not
  # diverge on it (see header). Plain unified diff, git apply -p1 from the tree root.
  cd "$out"
  git apply -p1 ${./cva6-parser/m3a-wbuf-depth.patch}
''
