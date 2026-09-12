#
# fpga/tang-mega-138k-pro/m3-ramtest.tcl — M3a challenge #16 Gowin-side confirmation.
#
# The counterpart to `nix run .#fpga-m3-core-rtl -- diag`. That step proved the yosys side:
# the CVA6 L1 RAM leaf (tc_sram_wrapper, 256x64, byte-we, registered read) becomes 64 per-bit
# write conditionals under the current flow (which GowinSynthesis demotes to flip-flops -> 0
# BSRAM -> RP0001), but 2 hard gw5a SPX9 BSRAM primitives under the fix (synth_gowin -family
# gw5a -run :map_ffs). This step feeds that SPX9 netlist to GowinSynthesis and reads back the
# resource report to CONFIRM Gowin accepts SPX9 as block RAM (BSRAM > 0) — closing the loop
# without a ~24 h full-CVA6 synth. Full write-up: docs/gowin-bsram-inference-debug.md.
#
#   nix run .#fpga-m3-core-rtl -- diag     # -> build/fpga-m3-core-rtl/diag/axisA_spx9.v
#   nix run .#fpga-build -- m3-ramtest     # this script -> build/fpga-m3-ramtest/impl/
#
# Modelled on m3-core.tcl (same set_device candidate loop). SYN is the gate here — a bare,
# pinless RAM does not route, so we read the SYNTHESIS resource report, not PnR.

puts "=== Phase 8 M3a: BSRAM-inference confirmation (SPX9 netlist -> GowinSynthesis) ==="

set nl  /work/build/fpga-m3-core-rtl/diag/axisA_spx9.v
set top tc_sram_wrapper

if {![file exists $nl]} {
  puts "BUILD RESULT: FAIL (missing $nl)"
  puts "  Run 'nix run .#fpga-m3-core-rtl -- diag' first."
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

add_file -type verilog $nl
set_option -top_module $top
set_option -synthesis_tool gowinsynthesis
set_option -output_base_name m3_ramtest

if {[catch {run syn} err]} {
  puts "RUN SYN FAILED: $err"
  puts "BUILD RESULT: FAIL (GowinSynthesis rejected the SPX9 netlist)"
  exit 2
}
puts "run syn: OK"

# --- Read back the resource report and extract the BSRAM count ---------------------------
# GowinSynthesis writes an HTML "Hierarchy Module Resource" table: a header row
#   MODULE NAME | REG NUMBER | ALU NUMBER | LUT NUMBER | DSP NUMBER | BSRAM NUMBER | ...
# then one data row per module. Strip tags to a flat cell list, drop the CSS cells, align
# the data row to the headers, and read the BSRAM column. BSRAM > 0 with REG = 0/'-' proves
# GowinSynthesis mapped the memory to block RAM instead of flip-flops.
set rpt ""
foreach g {impl/gwsynthesis/*_syn_resource.html impl/gwsynthesis/*_syn.rpt.html} {
  set hits [glob -nocomplain [file join [pwd] $g]]
  if {[llength $hits] > 0} { set rpt [lindex $hits 0]; break }
}
if {$rpt eq ""} {
  puts "WARN: no synthesis resource report found under [pwd]/impl/gwsynthesis/"
  puts "BUILD RESULT: SYN-OK (report not located; inspect impl/ manually)"
  exit 0
}
puts "--- resource report: $rpt ---"
set fh [open $rpt r]; set html [read $fh]; close $fh
# The "Hierarchy Module Resource" table: <th ...>COL NAME</th> headers, then per module a
# <td class="label">module (path)</td> followed by <td align = "center">VALUE</td> cells —
# one value per column after MODULE NAME. Parse line-oriented: headers in order, then the
# module's value cells, then index the BSRAM column.
set headers {}   ;# ordered column names, MODULE NAME first
set vals {}      ;# the module row's value cells (REG, ALU, LUT, DSP, BSRAM, SSRAM, ROM16)
set mod ""
set inrow 0
foreach line [split $html "\n"] {
  if {[regexp {<th[^>]*>(.*?)</th>} $line -> h]} { lappend headers [string trim $h] ; continue }
  if {[regexp {<td class="label">([^<]*)</td>} $line -> m]} { set mod [string trim $m]; set inrow 1; set vals {}; continue }
  if {$inrow && [regexp {<td align[^>]*>([^<]*)</td>} $line -> v]} { lappend vals [string trim $v]; continue }
  if {$inrow && [regexp {</tr>} $line]} { set inrow 0 }
}
set bcol [lsearch -exact $headers "BSRAM NUMBER"]
set rcol [lsearch -exact $headers "REG NUMBER"]
set lcol [lsearch -exact $headers "LUT NUMBER"]
if {$bcol < 0 || [llength $vals] == 0} {
  puts "WARN: could not parse the resource table (headers='$headers' vals='$vals')"
  puts "BUILD RESULT: SYN-OK (parse the report manually: $rpt)"
  exit 0
}
# value cells start at column 1 (MODULE NAME has no value cell), so column i -> vals(i-1).
set bsram [lindex $vals [expr {$bcol - 1}]]
set reg   [expr {$rcol > 0 ? [lindex $vals [expr {$rcol - 1}]] : "?"}]
set lut   [expr {$lcol > 0 ? [lindex $vals [expr {$lcol - 1}]] : "?"}]
puts "  module = $mod"
puts "  REG=$reg  LUT=$lut  BSRAM=$bsram"
# '-' means zero in the Gowin report; normalise for the gate.
set bnum [expr {$bsram eq "-" ? 0 : $bsram}]
if {[string is integer -strict $bnum] && $bnum > 0} {
  puts "BUILD RESULT: PASS — GowinSynthesis mapped the SPX9 netlist to $bnum BSRAM block(s) (REG=$reg)."
  puts "  => challenge #16 fix confirmed Gowin-side: the memory lands in block RAM, not flip-flops."
  exit 0
}
puts "BUILD RESULT: FAIL — BSRAM=$bsram (expected > 0); SPX9 not mapped to block RAM. See $rpt"
exit 3
