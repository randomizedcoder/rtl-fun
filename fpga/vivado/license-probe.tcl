# fpga/vivado/license-probe.tcl
#
# License-boundary probe: determine what the installed Vivado license actually permits
# on a given part, by pushing a trivial self-contained design all the way through
# synth -> opt -> place -> route -> write_bitstream and letting Vivado's own
# "Got license for feature ..." / failure messages report the boundary.
#
# The 2026.1 tiered model (Basic/Standard/...) gates *implementation* per device, so
# "does synth work" (proven for xc7k325t) does NOT imply "does impl+bitstream work".
# This probe answers that definitively for the target part, with no board and no CVA6.
#
# args: <part> <out_dir>
#   part     e.g. xc7k325tffg900-2
#   out_dir  where probe.v / probe.bit / timing_summary.rpt are written
#
# The runner (scripts/fpga-vivado-license-check.sh) greps this run's log for the
# PROBE_* markers and the "Got license for feature" lines to print a VERDICT.

set part    [lindex $argv 0]
set out_dir [lindex $argv 1]
file mkdir $out_dir

puts "PROBE: part=$part"

# --- generate a trivial, self-contained design (1 clk in, 1 reg out) -------------------
set vpath [file join $out_dir probe.v]
set fp [open $vpath w]
puts $fp "module probe (input wire clk, output reg q);"
puts $fp "  reg \[23:0\] c = 24'd0;"
puts $fp "  always @(posedge clk) begin c <= c + 24'd1; q <= c\[23\]; end"
puts $fp "endmodule"
close $fp

read_verilog $vpath

puts "PROBE: synth_design ..."
synth_design -top probe -part $part
puts "PROBE_SYNTH_OK"

# Constrain to known-legal pins for a generic 7-series package. These are the Genesys 2
# (xc7k325t-ffg900) user pins R19 / T28; override via out-of-band xdc for other packages.
create_clock -name clk -period 10.000 [get_ports clk]
catch { set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} [get_ports clk] }
catch { set_property -dict {PACKAGE_PIN T28 IOSTANDARD LVCMOS33} [get_ports q] }
# R19 is not clock-capable; demote the IO->BUFG dedicated-route rule (probe tests licensing,
# not timing quality).
catch { set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -hierarchical -filter {NAME =~ *clk*}] }

puts "PROBE: opt_design ..."
opt_design
puts "PROBE: place_design ..."
place_design
puts "PROBE_PLACE_OK"
puts "PROBE: route_design ..."
route_design
puts "PROBE_ROUTE_OK"
report_timing_summary -file [file join $out_dir timing_summary.rpt]
puts "PROBE: write_bitstream ..."
write_bitstream -force [file join $out_dir probe.bit]
puts "PROBE_BITSTREAM_OK"
