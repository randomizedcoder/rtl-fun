#
# fpga/tang-mega-138k-pro/hello.tcl — build the UART hello-world for the Tang Mega.
#
# Runs inside the Gowin microVM (nix/gowin-vm.nix), driven by `nix run .#fpga-build`
# via a RUN_TCL marker. The repo is 9p-mounted at /work, so every path here is a
# guest path.
#
# Modelled on nix/gowin/device-check.tcl and reusing its set_device candidate loop:
# the board's marketing name "GW5AST-LV138FPG676A" is NOT what set_device accepts —
# Gowin's device DB keys the part by its full grade-suffixed order code. First
# accepted spelling wins.
#
# Two source files here rather than one (hello_top.v + uart_tx.v): order does not
# matter, GowinSynthesis resolves the instantiation itself. -top_module picks the
# top explicitly so it cannot guess the UART as the root.

puts "=== Phase 8: hello_top for Tang Mega 138K Pro (GW5AST-138) ==="

set src     /work/fpga/tang-mega-138k-pro/src
set top     hello_top

# Same candidate set as the Tier-1 gate. FCPBGA676A package = the Tang Mega part;
# both speed grades and device versions covered.
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
# -type verilog is Verilog mode, NOT SystemVerilog: `logic` / `always_ff` are
# rejected here. hello_top.v is Verilog-2001 for exactly this reason.
add_file -type verilog "$src/hello_top.v"
add_file -type verilog "$src/uart_tx.v"
add_file -type cst     "$src/hello_top.cst"
add_file -type sdc     "$src/hello_top.sdc"

set_option -top_module $top
set_option -synthesis_tool gowinsynthesis
set_option -output_base_name $top

# Emit the reports that make this build worth reading: timing (Phase-6 gap G14)
# and pin-out, alongside the default utilization report.
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
