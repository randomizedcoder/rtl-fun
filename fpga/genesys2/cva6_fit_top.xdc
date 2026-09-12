# fpga/genesys2/cva6_fit_top.xdc
#
# Pin constraints for the cva6_fit_top route-proof on the Digilent Genesys 2
# (Kintex-7 xc7k325tffg900-2), consumed by nextpnr-xilinx. See
# nix/fpga-m3-xilinx.nix.
#
# These are real Genesys 2 package pins, but the exact function is irrelevant to
# a fit/route proof — only that they are valid, legally-placeable device pins in
# the ffg900 package. clk_i uses R28 (SRCC, clock-capable, bank 14, LVCMOS33).

set_property LOC R28 [get_ports clk_i]
set_property IOSTANDARD LVCMOS33 [get_ports clk_i]

set_property LOC R29 [get_ports rst_ni]
set_property IOSTANDARD LVCMOS33 [get_ports rst_ni]

set_property LOC R30 [get_ports din]
set_property IOSTANDARD LVCMOS33 [get_ports din]

set_property LOC T28 [get_ports dout]
set_property IOSTANDARD LVCMOS33 [get_ports dout]

# 50 MHz target for the route-proof; nextpnr reports the achieved Fmax separately.
create_clock -period 20.000 -name clk_i [get_ports clk_i]
