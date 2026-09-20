# fpga/genesys2/m3-vivado-fit-native.tcl
#
# Vivado synth-only utilization on the NATIVE CVA6 SystemVerilog — the trustworthy
# M3a "verify-before-buy" LUT number. Driven by scripts/fpga-m3-vivado-fit.sh
# (nix run .#fpga-m3-vivado-fit). See docs/phase-8-status.md §"Verify-before-buy".
#
# Why native (not sv2v): Vivado is SystemVerilog-native. Feeding it the sv2v-flattened
# core (fpga/genesys2/m3-vivado-fit.tcl, kept only for the documented contrast) inflates
# the LUT count ~5.8x — sv2v defeats Vivado's optimizer and DSP inference; FF/DSP/BRAM
# stay accurate but the LUT cloud balloons. On our actual RTL the real figures are
# 48,217 LUT6 (24% of the 325T) native vs 277,751 sv2v vs 628,762 openXC7/abc9. sv2v is
# ONLY for the open tools (yosys/GowinSynthesis); never hand it to Vivado.
#
# Top = `cva6` directly (no harness): out_of_context inserts no I/O buffers, so the
# ~8k-bit port count needs no harness/.xdc. rvfi_probes_o stays as top outputs (not
# DCE-pruned) — a small conservative overhead vs deployment. The default CVA6Cfg comes
# from the config_pkg in the flist (cv64a6_imafdc_sv39), so no parameter override.
#
# -flatten_hierarchy none is ESSENTIAL, not cosmetic: the raw core with rvfi outputs
# kept OOMs >61 GB when Vivado flattens the whole design for cross-boundary opt. Keeping
# module boundaries drops peak memory to ~2.3 GB (finishes in ~22 min). Utilization stays
# accurate — less cross-boundary optimization can only ADD LUTs, so a fit here is a real
# fit (doubly conservative, with the kept rvfi cone).
#
# This is a fit SIZING, not a timing sign-off: synth_design only, no place/route.
#
# tclargs (positional, injected by the shell wrapper):
#   0: flist        newline-separated native .sv files (build/fpga-m3-core-rtl/files.txt)
#   1: incdirs_file newline-separated include dirs     (build/fpga-m3-core-rtl/incdirs.txt)
#   2: part         e.g. xc7k325tffg900-2 (Genesys 2) — any 7-series (same LUT6 fabric)
#   3: out_dir      build/fpga-m3-vivado
#   4: max_threads  synth worker threads (Vivado clamps to the host core count)

if {[llength $argv] != 5} {
    puts stderr "ERROR: expected 5 tclargs: flist incdirs_file part out_dir max_threads"
    exit 2
}
set flist       [lindex $argv 0]
set incf        [lindex $argv 1]
set part        [lindex $argv 2]
set out_dir     [lindex $argv 3]
set max_threads [lindex $argv 4]

set_param general.maxThreads $max_threads
puts "=== general.maxThreads = [get_param general.maxThreads] ==="

# Read a newline-separated list file, trimming blanks.
proc read_lines {path} {
    set fh [open $path r]
    set out {}
    foreach line [split [read $fh] "\n"] {
        set t [string trim $line]
        if {$t ne ""} { lappend out $t }
    }
    close $fh
    return $out
}

set files [read_lines $flist]
set incs  [read_lines $incf]
puts "=== reading [llength $files] native SystemVerilog files (flist $flist) ==="
foreach f $files { read_verilog -sv $f }
puts "=== include dirs ([llength $incs]): $incs ==="

puts "=== synth_design -top cva6 -part $part -mode out_of_context -flatten_hierarchy none ==="
synth_design -top cva6 -part $part -mode out_of_context \
    -flatten_hierarchy none \
    -include_dirs $incs \
    -verilog_define {SYNTHESIS=1 FPGA_TARGET_XILINX=1}

report_utilization              -file [file join $out_dir util.rpt]
report_utilization -hierarchical -file [file join $out_dir util_hier.rpt]
puts "=== m3-vivado-fit-native: wrote [file join $out_dir util.rpt] ==="
