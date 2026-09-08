#
# fpga/tang-mega-138k-pro/m2.tcl — build Phase-8 milestone M2 (host packet injection).
#
# Prerequisites (run in this order):
#   nix run .#fpga-m1-roms     # program.hex + cam.hex (shared parse graph, $readmemh)
#   nix run .#fpga-m2-rtl      # build/fpga-m2-rtl/parser_m2.v (sv2v-flattened RTL)
#   nix run .#fpga-build -- m2 # this script -> build/fpga-m2/impl/pnr/m2_top.fs
#
# M2 = parser datapath + a UART receiver that loads an injected packet into the packet
# buffer, plus the M1 result emitter. See m2_top.sv. Same flatten rationale as M1
# (GowinSynthesis SP00018 on our SV, docs/phase-8-status.md #13). Modelled on m1.tcl.

puts "=== Phase 8 M2: parser + UART packet injection for Tang Mega 138K Pro ==="

set src   /work/fpga/tang-mega-138k-pro/src
set flat  /work/build/fpga-m2-rtl/parser_m2.v
set top   m2_top

if {![file exists $flat]} {
  puts "BUILD RESULT: FAIL (missing $flat)"
  puts "  Run 'nix run .#fpga-m2-rtl' first to flatten the RTL, and"
  puts "      'nix run .#fpga-m1-roms' to generate the shared program/cam ROM."
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

# --- Sources ----------------------------------------------------------------------------
add_file -type verilog $flat
add_file -type cst     "$src/m2_top.cst"
add_file -type sdc     "$src/m2_top.sdc"

set_option -top_module $top
set_option -synthesis_tool gowinsynthesis
set_option -output_base_name $top

catch {set_option -gen_text_timing_rpt 1}
catch {set_option -gen_posp 1}
catch {set_option -gen_io_cst 1}

# --- Synthesis --------------------------------------------------------------------------
if {[catch {run syn} err]} {
    puts "RUN SYN FAILED: $err"
    puts "BUILD RESULT: FAIL (synthesis)"
    exit 2
}
puts "run syn: OK"

# --- Place & route ----------------------------------------------------------------------
if {[catch {run pnr} err]} {
    puts "RUN PNR FAILED: $err"
    puts "BUILD RESULT: FAIL (place-and-route — often an illegal pin in the .cst)"
    exit 3
}
puts "run pnr: OK"

puts "BUILD RESULT: OK (device '$chosen')"
puts "Bitstream + reports under: [pwd]/impl/"
