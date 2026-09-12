#
# fpga/tang-mega-138k-pro/m3-cone.tcl — M3a #16-followup: localize the GowinSynthesis
# LUT-mapper crash (embedded-ABC `If_CutAreaDerefed`, ifCut.c:1109) to a single subtree.
#
# The full-core fit (`nix run .#fpga-build -- m3-core`) synthesizes the coarse-minus-alumacc
# netlist cleanly through inference (4 SPX9 cache BSRAMs accepted — challenge #16 solved) but
# gw_sh ABORTS in technical mapping with an ABC area-flow assertion, ~6-7 h in. `-retiming 0`
# only delayed the identical crash. Hypothesis: the assertion is an area-flow divergence over a
# LARGE arithmetic cone — most likely CVA6's 64x64 integer multiplier or the FPU mantissa
# multipliers, which GowinSynthesis expands into LUT logic. This target feeds the SAME crashing
# netlist (build/fpga-m3-core-rtl/cva6_core.v) but sets -top_module to ONE arithmetic submodule,
# so the crash (or clean map) reproduces in MINUTES instead of hours — and yields the minimal
# testcase for Gowin support. Full write-up: docs/gowin-bsram-inference-debug.md.
#
#   # pick the subtree (escaped module name, exactly as in cva6_core.v), then:
#   printf '%s\n' '\$paramod$...\multiplier' > build/fpga-m3-cone/TOP.txt
#   nix run .#fpga-build -- m3-cone
#
# SYN is the gate: a crash => gw_sh dies (SIGABRT, exit 134) and the log shows the ifCut
# assertion (hypothesis confirmed for this subtree). A clean run prints the module's resource
# row (did the multiplier go to DSP or to a LUT cone?).

puts "=== Phase 8 M3a: localize the GowinSynthesis LUT-mapper crash to one subtree ==="

# Netlist path defaults to the canonical s2 output, but can be overridden by an optional NL.txt
# in the run's outdir (this cwd) so a fix VARIANT (e.g. cva6_core_su.v after setundef) can be
# cone-tested without touching the canonical netlist. Contents: one path (guest /work/... form).
set nl /work/build/fpga-m3-core-rtl/cva6_core.v
set nlfile [file join [pwd] NL.txt]
if {[file exists $nlfile]} {
  set fh [open $nlfile r]; set nl [string trim [read $fh]]; close $fh
}

# The top submodule to synthesize is read from TOP.txt in the run's outdir (this cwd), so the
# module name — an escaped Verilog identifier with literal '$' and '\' — never passes through a
# Tcl/shell substitution. Default to the integer multiplier if the file is absent.
set topfile [file join [pwd] TOP.txt]
if {[file exists $topfile]} {
  set fh [open $topfile r]; set top [string trim [read $fh]]; close $fh
} else {
  set top {\$paramod$add843443a8e65229064182efd829bc757894656\multiplier}
}

if {![file exists $nl]} {
  puts "BUILD RESULT: FAIL (missing $nl — run 'nix run .#fpga-m3-core-rtl -- s2' first)"
  exit 1
}
puts "  netlist : $nl"
puts "  top     : $top"

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
set_option -output_base_name m3_cone

# SYN is the whole test. If GowinSynthesis aborts (the ifCut assertion), gw_sh is killed by
# SIGABRT and never returns here — the wrapper reports FAIL and gowin.log carries the assertion.
if {[catch {run syn} err]} {
  puts "RUN SYN FAILED: $err"
  puts "BUILD RESULT: FAIL (synthesis error/crash for top '$top' — check gowin.log for If_CutAreaDerefed)"
  exit 2
}
puts "run syn: OK — this subtree does NOT trigger the crash."

# --- Clean run: report the module's resources (esp. DSP vs LUT for the arithmetic) -----------
set rpt ""
foreach g {impl/gwsynthesis/*_syn_resource.html impl/gwsynthesis/*_syn.rpt.html} {
  set hits [glob -nocomplain [file join [pwd] $g]]
  if {[llength $hits] > 0} { set rpt [lindex $hits 0]; break }
}
if {$rpt eq ""} {
  puts "BUILD RESULT: SYN-OK (no resource report located; inspect impl/ manually)"
  exit 0
}
puts "--- resource report: $rpt ---"
set fh [open $rpt r]; set html [read $fh]; close $fh
set headers {}
set vals {}
set mod ""
set inrow 0
foreach line [split $html "\n"] {
  if {[regexp {<th[^>]*>(.*?)</th>} $line -> h]} { lappend headers [string trim $h] ; continue }
  if {[regexp {<td class="label">([^<]*)</td>} $line -> m]} { set mod [string trim $m]; set inrow 1; set vals {}; continue }
  if {$inrow && [regexp {<td align[^>]*>([^<]*)</td>} $line -> v]} { lappend vals [string trim $v]; continue }
  if {$inrow && [regexp {</tr>} $line]} { set inrow 0 }
}
proc colval {headers vals name} {
  set i [lsearch -exact $headers $name]
  if {$i > 0 && [expr {$i - 1}] < [llength $vals]} { return [lindex $vals [expr {$i - 1}]] }
  return "?"
}
puts "  module = $mod"
puts "  REG=[colval $headers $vals {REG NUMBER}]  ALU=[colval $headers $vals {ALU NUMBER}]  LUT=[colval $headers $vals {LUT NUMBER}]  DSP=[colval $headers $vals {DSP NUMBER}]  BSRAM=[colval $headers $vals {BSRAM NUMBER}]"
puts "BUILD RESULT: SYN-OK (subtree mapped without the crash; see resources above)"
exit 0
