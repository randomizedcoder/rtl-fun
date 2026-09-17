# fpga/genesys2/m3-vivado-fit.tcl
#
# Vivado synth-only utilization run for the M3a "verify-before-buy" fit check on
# our ACTUAL CVA6 RTL. Driven by scripts/fpga-m3-vivado-fit.sh (nix run
# .#fpga-m3-vivado-fit). See docs/phase-8-status.md §"Verify-before-buy".
#
# Why this exists: the open-source openXC7 flow (nix run .#fpga-m3-xilinx-fit)
# maps stock CVA6 to ~628k LUTs — a ~12x abc9 mapping-quality artifact, not the
# design's real size. Vivado is the only tool that gives a trustworthy LUT count,
# and free WebPACK/ML Standard covers XC7A200T, whose 7-series LUT6 fabric is
# identical to the Genesys 2's XC7K325T — so an A200T synth certifies the fit with
# no board and no license cost. This reads the SAME cva6_core_sv2v.v input the
# openXC7 flow used, so the Vivado-vs-abc9 delta is apples-to-apples.
#
# This is a fit SIZING, not a timing sign-off: synth_design only (no place/route),
# out_of_context (no I/O buffer insertion, so no .xdc/pins are needed).
#
# tclargs (positional, injected by the shell wrapper):
#   0: sv2v_core   build/fpga-m3-core-rtl/cva6_core_sv2v.v (Xilinx-flavored, folded)
#   1: harness     fpga/genesys2/cva6_fit_top.v (register-ring, rvfi pruned)
#   2: part        e.g. xc7a200tsbg484-1 (free tier) or xc7k325tffg900-2
#   3: out_dir     build/fpga-m3-vivado

if {[llength $argv] != 4} {
    puts stderr "ERROR: expected 4 tclargs: sv2v_core harness part out_dir"
    exit 2
}
set sv2v_core [lindex $argv 0]
set harness   [lindex $argv 1]
set part      [lindex $argv 2]
set out_dir   [lindex $argv 3]

puts "=== m3-vivado-fit: part $part ==="
# Both files are Verilog-2005 (sv2v targets it; the harness is plain reg/wire), but
# -sv is a harmless superset — defensive against any residual SV-ism in the 508 MB core.
puts "=== reading core:    $sv2v_core ==="
read_verilog -sv $sv2v_core
puts "=== reading harness: $harness ==="
read_verilog -sv $harness

# out_of_context: no top-level I/O buffers, so the harness's 4 pins need no .xdc.
# Synthesis only — this is a utilization sizing, not an implemented design.
puts "=== synth_design -top cva6_fit_top -part $part -mode out_of_context ==="
synth_design -top cva6_fit_top -part $part -mode out_of_context

# The whole point: the utilization report. Flat + hierarchical, so we can see
# where the LUTs land (core vs the negligible harness ring).
report_utilization             -file [file join $out_dir util.rpt]
report_utilization -hierarchical -file [file join $out_dir util_hier.rpt]
puts "=== m3-vivado-fit: wrote [file join $out_dir util.rpt] ==="
