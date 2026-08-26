#
# nix/gowin/cva6-util.tcl — Tier-2 Gowin utilization + Fmax for cv64a6_imac.
#
# Runs only after the Tier-1 gate is GO. Feeds the sv2v-flattened cv64a6_imac netlist to
# GowinSynthesis targeting GW5AST-LV138FPG676A and reports resource utilization (LUT4 / FF /
# BSRAM / DSP) and, if synthesis succeeds, place-and-route Fmax. Best-effort: CVA6 is
# Xilinx-native, so full elaboration under GowinSynthesis is not guaranteed — even a partial
# synth resource estimate is useful for the sizing decision. Don't treat a non-clean PnR as
# a gate failure.
#
# Prepare the flattened netlist first (on host or in the guest):
#   sv2v ... cv64a6_imac ... > /work/build/fpga-eval/cva6_imac_flat.v
# Then, from a writable dir:
#   mkdir -p /work/build/gowin-cva6 && cd /work/build/gowin-cva6
#   gowin-check /work/nix/gowin/cva6-util.tcl
#
# Overridable via env: CVA6_NETLIST (path to flat .v), CVA6_TOP (top module name).

set netlist "/work/build/fpga-eval/cva6_imac_flat.v"
if {[info exists ::env(CVA6_NETLIST)]} { set netlist $::env(CVA6_NETLIST) }
set top "cva6"
if {[info exists ::env(CVA6_TOP)]} { set top $::env(CVA6_TOP) }

puts "=== Tier-2: CVA6 utilization on GW5AST-138 (Tang Mega 138K Pro) ==="
puts "netlist: $netlist"
puts "top    : $top"

if {![file exists $netlist]} {
    puts "NETLIST MISSING: $netlist"
    puts "Generate the sv2v-flattened cv64a6_imac netlist first (see header)."
    exit 1
}

# The board's marketing name "GW5AST-LV138FPG676A" is NOT accepted by set_device (Tier-1 proved
# this); Gowin keys the part by its full grade-suffixed order code. Reuse the same first-accepted
# candidate loop as device-check.tcl so both scripts stay in sync.
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
    puts "SET_DEVICE FAILED: no accepted form for the GW5AST-138 part"
    exit 2
}

add_file -type verilog $netlist
set_option -top_module $top
set_option -synthesis_tool gowinsynthesis
set_option -output_base_name cva6_imac

if {[catch {run syn} err]} {
    puts "RUN SYN FAILED (expected-possible for Xilinx-native CVA6): $err"
    puts "Check the synthesis report for the resource estimate reached before the stop."
    exit 3
}
puts "run syn: OK — see synthesis utilization report under [pwd]/impl/"

if {[catch {run pnr} err]} {
    puts "RUN PNR incomplete: $err"
    puts "Utilization from synthesis is still usable; Fmax unavailable."
    exit 0
}
puts "run pnr: OK — utilization + Fmax in [pwd]/impl/"
