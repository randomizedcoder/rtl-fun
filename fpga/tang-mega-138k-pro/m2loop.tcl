#
# fpga/tang-mega-138k-pro/m2loop.tcl — build the M2 UART loopback (RX-pin confirm).
#
# Runs inside the Gowin microVM (nix/gowin-vm.nix), driven by `nix run .#fpga-build --
# m2loop` via a RUN_TCL marker. The repo is 9p-mounted at /work, so every path here
# is a guest path. Modelled on hello.tcl and reusing its set_device candidate loop
# (the board's part is keyed by its full grade-suffixed order code, not the marketing
# name; first accepted spelling wins).
#
# Single source file, plain Verilog (m2loop_top.v is a pure loopback — no
# SystemVerilog, so -type verilog is correct and SP00018 never enters the picture).

puts "=== Phase 8 M2: m2loop_top (UART RX-pin confirm) for Tang Mega 138K Pro ==="

set src /work/fpga/tang-mega-138k-pro/src
set top m2loop_top

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

# --- Sources / constraints / options ----------------------------------------------------
add_file -type verilog "$src/m2loop_top.v"
add_file -type cst     "$src/m2loop_top.cst"
add_file -type sdc     "$src/m2loop_top.sdc"

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
