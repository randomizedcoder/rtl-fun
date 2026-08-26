#
# nix/gowin/device-check.tcl — Tier-1 Gowin license/device gate.
#
# Answers the Phase-8 pre-purchase question: does the Education/NODELOCK license permit
# synth + place-and-route for the Tang Mega 138K Pro part? A tiny blinky is the probe — if
# syn and pnr both complete, the license accepts the device (GO). A license/device error is
# the decisive NO-GO.
#
# The board's marketing name is "GW5AST-LV138FPG676A"; Gowin's device DB keys the part by
# its full grade-suffixed order code (e.g. GW5AST-LV138FPG676AC1/I0), device_version B or C
# (device_info.csv). We try the plausible set_device spellings and use the first accepted.
#
# Run from a writable dir (gw_sh writes impl/ under cwd):
#   mkdir -p /work/build/gowin && cd /work/build/gowin
#   gowin-check /work/nix/gowin/device-check.tcl

puts "=== Tier-1 gate: GW5AST-138 (Tang Mega 138K Pro) license/device check ==="

# Candidate set_device argument lists (first accepted wins). FCPBGA676A package = the
# Tang Mega part; both grades and device versions covered.
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
  puts "GATE RESULT: NO-GO (no set_device form accepted for the 138 part)"
  exit 1
}

# --- Sources / options ------------------------------------------------------------------
add_file -type verilog /work/nix/gowin/blinky.v
set_option -top_module blinky
set_option -synthesis_tool gowinsynthesis
set_option -output_base_name blinky_gate

# --- Synthesis (first place the license is exercised for the device) --------------------
if {[catch {run syn} err]} {
    puts "RUN SYN FAILED: $err"
    puts "GATE RESULT: NO-GO (synthesis rejected — likely license/device restriction)"
    exit 2
}
puts "run syn: OK"

# --- Place & route ----------------------------------------------------------------------
if {[catch {run pnr} err]} {
    puts "RUN PNR FAILED: $err"
    puts "GATE RESULT: NO-GO (place-and-route rejected — likely license/device restriction)"
    exit 3
}
puts "run pnr: OK"

puts "GATE RESULT: GO (Education/NODELOCK license permits GW5AST-LV138FPG676A via '$chosen')"
puts "Reports under: [pwd]/impl/"
