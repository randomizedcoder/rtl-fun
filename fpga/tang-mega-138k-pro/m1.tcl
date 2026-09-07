#
# fpga/tang-mega-138k-pro/m1.tcl — build Phase-8 milestone M1 for the Tang Mega.
#
# Prerequisites (run in this order):
#   nix run .#fpga-m1-roms     # roms/m1/*.hex from the golden model ($readmemh input)
#   nix run .#fpga-m1-rtl      # build/fpga-m1-rtl/parser_m1.v (sv2v-flattened RTL)
#   nix run .#fpga-build -- m1 # this script -> build/fpga-m1/impl/pnr/m1_top.fs
#
# M1 is the parser datapath alone: parser_top (a hardware pm_run) fed one packet baked
# into on-chip ROM, streaming the resulting flow_keys over the UART (P15). It is our
# first design running our own parser RTL on real silicon.
#
# Why flattened Verilog rather than the .sv directly: GowinSynthesis parses our
# SystemVerilog but aborts inside synthesis with ERROR (SP00018) "error bus name set"
# on the packed-struct signals/ports, even after every false-latch was cleared
# (docs/phase-8-status.md #13). sv2v (`nix run .#fpga-m1-rtl`) flattens the structs to
# plain vectors; for a parser-only design the §5a BRAM-inference concern does not apply.
# uart_tx.v is plain Verilog-2001, added separately.
#
# Modelled on hello.tcl; reuses its set_device candidate loop.

puts "=== Phase 8 M1: parser-on-ROM for Tang Mega 138K Pro (GW5AST-138) ==="

set src   /work/fpga/tang-mega-138k-pro/src
set flat  /work/build/fpga-m1-rtl/parser_m1.v
set top   m1_top

if {![file exists $flat]} {
  puts "BUILD RESULT: FAIL (missing $flat)"
  puts "  Run 'nix run .#fpga-m1-rtl' first to flatten the RTL, and"
  puts "      'nix run .#fpga-m1-roms' to generate the on-chip ROM images."
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
# One self-contained, yosys-flattened Verilog file carries the whole M1 design
# (m1_top + parser_top + the parser datapath + uart_tx, all inlined). Verilog mode.
add_file -type verilog $flat
add_file -type cst     "$src/m1_top.cst"
add_file -type sdc     "$src/m1_top.sdc"

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
