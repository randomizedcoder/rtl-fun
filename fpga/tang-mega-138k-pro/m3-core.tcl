#
# fpga/tang-mega-138k-pro/m3-core.tcl — Phase-8 M3a "CVA6 fits": synthesize STOCK CVA6
# and read whether GowinSynthesis inferred BSRAM (docs/phase-8-fpga.md M3a).
#
# Prerequisites:
#   nix run .#fpga-m3-core-rtl [-- s0|s1|s2]   # -> build/fpga-m3-core-rtl/cva6_core.v
#   nix run .#fpga-build -- m3-core            # this script -> build/fpga-m3-core/impl/
#
# What this proves. The prior full-flatten attempt (build/fpga-eval) inferred 0 BSRAM and
# put ~543 Kbit of cache/tag memory into flip-flops -> 558,387 DFF -> ERROR (RP0001)
# resource overflow (~4x over the 139,140 FF), because `flatten` dissolves CVA6's RAM
# leaves (fpga-platform-assessment.md §5a, phase-8-status.md #16). fpga-m3-core-rtl keeps
# module hierarchy so those inferrable RAM leaves survive; SYNTHESIS is the gate here — a
# clean `run syn` whose utilization report shows BSRAM > 0 and LUT/FF within the device
# means CVA6 fits. (This is a BARE core with no top-level pin binding, so PnR to a real
# bitstream is best-effort/informational — the routed bitstream is M3b's m3_top, which
# adds real I/O and wires the AXI to on-chip memory + peripherals rather than to pins.)
#
# Modelled on m1.tcl / the old nix/gowin/cva6-util.tcl (now superseded by this).

puts "=== Phase 8 M3a: stock-CVA6 synthesis fit check (GW5AST-138) ==="

set flat /work/build/fpga-m3-core-rtl/cva6_core.v
set top  cva6
if {[info exists ::env(CVA6_TOP)]} { set top $::env(CVA6_TOP) }

if {![file exists $flat]} {
  puts "BUILD RESULT: FAIL (missing $flat)"
  puts "  Run 'nix run .#fpga-m3-core-rtl' first."
  exit 1
}

set candidates {
  {-name GW5AST-138B GW5AST-LV138FPG676AC1/I0}
  {-name GW5AST-138B GW5AST-LV138FPG676AC2/I1}
  {-device_version B GW5AST-LV138FPG676AC1/I0}
  {GW5AST-LV138FPG676AC1/I0}
  {GW5AST-LV138FPG676AC2/I1}
  {-name GW5AST-138C GW5AST-LV138FPG676AC1/I0}
}
set chosen ""
foreach c $candidates {
  puts "trying: set_device $c"
  if {[catch {set_device {*}$c} err]} {
    puts "  rejected: $err"
  } else {
    puts "set_device OK: $c"
    set chosen $c
    break
  }
}
if {$chosen eq ""} {
  puts "BUILD RESULT: FAIL (no set_device form accepted for the 138 part)"
  exit 1
}

add_file -type verilog $flat
set_option -top_module $top
set_option -synthesis_tool gowinsynthesis
set_option -output_base_name cva6_core

# --- Work around the GowinSynthesis V1.9.12.03 LUT-mapper crash --------------------------
# On the first full run the coarse-minus-alumacc netlist synthesized cleanly (no EX3937, no
# SP00018) all the way through inference and into technical mapping — the 4 SPX9 cache BSRAMs
# were accepted (EX0346 WRITE_MODE notes on mem.0.x) — but gw_sh then ABORTED at
# "[75%] Tech-Mapping Phase 2" with an embedded-ABC assertion:
#   gw_sh: src/map/if/ifCut.c:1109: If_CutAreaDerefed:
#          Assertion `aResult > aResult2 - 3*p->fEpsilon' failed.   (SIGABRT, exit 134)
# That is a numerical-robustness bug in ABC's area-flow cut selection, not a fit/overflow.
# Retiming (default ON) re-invokes the mapping/area passes and is the classic trigger for
# GowinSynthesis mapper instability, so disable it here. Documented in
# docs/gowin-bsram-inference-debug.md and challenge #16 / #13.
set_option -retiming 0

catch {set_option -gen_text_timing_rpt 1}
catch {set_option -gen_posp 1}

# --- Synthesis is the fit gate ----------------------------------------------------------
if {[catch {run syn} err]} {
    puts "RUN SYN FAILED: $err"
    puts "BUILD RESULT: FAIL (synthesis — check for SP00018 or a resource-limit stop)"
    exit 2
}
puts "run syn: OK — read the utilization report under [pwd]/impl/ for BSRAM / LUT4 / FF."
puts "  M3a PASSES iff BSRAM blocks > 0 and LUT4/FF are within the device (RP0001 = overflow)."

# --- Place & route (best-effort: bare core has no pin binding) ---------------------------
if {[catch {run pnr} err]} {
    puts "RUN PNR incomplete (expected for a bare, pinless core): $err"
    puts "BUILD RESULT: SYN-OK (utilization from synthesis is the M3a verdict; Fmax N/A)"
    exit 0
}
puts "run pnr: OK — utilization + Fmax under [pwd]/impl/"
puts "BUILD RESULT: OK (device '$chosen')"
