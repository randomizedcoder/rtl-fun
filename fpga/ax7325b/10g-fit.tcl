# fpga/ax7325b/10g-fit.tcl
#
# Phase-C pre-buy: does a 10G Ethernet MAC BUILD, FIT and meet Fmax on the AX7325B
# die (xc7k325tffg900-2), with NO board and NO transceiver IP? Driven by
# scripts/fpga-10g-fit.sh (nix run .#fpga-10g-fit). See docs/phase-8-status.md §"C5".
#
# DUT: Alex Forencich verilog-ethernet `eth_mac_10g` (64-bit XGMII, AXI-Stream fabric
# side) — the same MAC family this repo already vendors at 1G
# (corev_apu/fpga/src/ariane-ethernet/eth_mac_1g*.sv). PTP/PFC/LFC left at their
# defaults (disabled), so the fit is the plain framing MAC that a real SFP+ datapath
# would carry. The XGMII side is the boundary to the (separate, board-in-hand) GTX/
# 10GBASE-R PCS-PMA transceiver — deliberately NOT built here: the transceiver wrapper
# is the fiddly refclk/SI part that genuinely needs silicon (see docs §"Out of scope").
#
# WHY NO FIT HARNESS (unlike fpga/genesys2/cva6_fit_top.v): that harness exists for the
# non-OOC open flow, where the ~8k-bit core port count exceeds the package pins. Here we
# synthesize `eth_mac_10g` DIRECTLY as an out_of_context top — exactly the idiom of
# m3-vivado-fit-native.tcl. In OOC mode every top port is a PRIMARY I/O (no IOBUFs, no
# pin budget) and OOC primary inputs are NOT constant-folded (they are driven from
# outside the OOC region), so utilization is faithful with no hand-wired ring. This is
# both simpler and more faithful than a ~80-port harness would be.
#
# Two clock domains: eth_mac_10g runs rx and tx independently. We create_clock on both
# at the target period and mark them asynchronous, so cross-domain paths (there are
# none by design) cannot pollute the WNS.
#
# 10G 64-bit XGMII runs at 156.25 MHz -> 6.400 ns. That is the Fmax target the WNS is
# measured against; a positive WNS means the MAC closes timing on the 325T fabric.
#
# This is a fit + Fmax feasibility check, NOT a bitstream: OOC synth (+ optional OOC
# place/route for the real WNS), no I/O, no board constraints.
#
# tclargs (positional, injected by the shell wrapper):
#   0: src_dir      verilog-ethernet rtl/ dir (the pinned flake input)
#   1: part         e.g. xc7k325tffg900-2 (AX7325B / Genesys 2 die)
#   2: out_dir      build/fpga-10g-fit
#   3: period_ns    target clock period (6.400 = 156.25 MHz for 64-bit XGMII 10G)
#   4: stage        synth | route  (synth = synth+reports; route = + place/route+timing)
#   5: max_threads  synth/impl worker threads (Vivado clamps to the host core count)

if {[llength $argv] != 6} {
    puts stderr "ERROR: expected 6 tclargs: src_dir part out_dir period_ns stage max_threads"
    exit 2
}
set src_dir     [lindex $argv 0]
set part        [lindex $argv 1]
set out_dir     [lindex $argv 2]
set period_ns   [lindex $argv 3]
set stage       [lindex $argv 4]
set max_threads [lindex $argv 5]

set_param general.maxThreads $max_threads
puts "=== general.maxThreads = [get_param general.maxThreads] ==="

# The 64-bit XGMII MAC and its two dependencies. axis_xgmii_{rx,tx}_64 both pull in
# lfsr (CRC-32 + scrambler). This is the complete, self-contained source set for
# eth_mac_10g with the default (PTP/PFC/LFC-off) configuration.
set files [list \
    [file join $src_dir eth_mac_10g.v] \
    [file join $src_dir axis_xgmii_rx_64.v] \
    [file join $src_dir axis_xgmii_tx_64.v] \
    [file join $src_dir lfsr.v] \
]
foreach f $files {
    if {![file exists $f]} { puts stderr "ERROR: missing source $f"; exit 2 }
    puts "=== read_verilog $f ==="
    read_verilog $f
}

puts "=== synth_design -top eth_mac_10g -part $part -mode out_of_context ==="
synth_design -top eth_mac_10g -part $part -mode out_of_context

# Constrain both MAC clock domains at the 10G 64-bit XGMII rate and isolate them.
create_clock -name rx_clk -period $period_ns [get_ports rx_clk]
create_clock -name tx_clk -period $period_ns [get_ports tx_clk]
catch { set_clock_groups -asynchronous \
    -group [get_clocks rx_clk] -group [get_clocks tx_clk] }

report_utilization               -file [file join $out_dir util.rpt]
report_utilization -hierarchical -file [file join $out_dir util_hier.rpt]
puts "=== 10g-fit: wrote [file join $out_dir util.rpt] (post-synth) ==="

if {$stage eq "route"} {
    puts "=== opt_design / place_design / route_design (OOC, for real WNS) ==="
    opt_design
    place_design
    route_design
    report_utilization               -file [file join $out_dir util.rpt]
    report_utilization -hierarchical -file [file join $out_dir util_hier.rpt]
    report_timing_summary -delay_type min_max -max_paths 10 \
        -file [file join $out_dir timing.rpt]
    puts "=== 10g-fit: wrote [file join $out_dir timing.rpt] (post-route) ==="
}

puts "10G_FIT_TCL_OK"
