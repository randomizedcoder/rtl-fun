#
# fpga/tang-mega-138k-pro/sv-probe.tcl — can GowinSynthesis read our SystemVerilog
# directly, without sv2v?
#
# Why this matters more than it looks. Every Gowin flow in this repo so far used
# `add_file -type verilog`, and docs/gowin-microvm.md concluded from that "Gowin
# parses Verilog, not SystemVerilog". Two findings say that conclusion was too
# strong:
#   1. add_file's own help says it "automatically judge the file's type by it
#      extension name. This option can override it." So `-type verilog` on a .sv
#      file was FORCING Verilog mode, not revealing a limitation.
#   2. `set_option -verilog_std` exists and accepts `sysv2017` (the earlier probe
#      failed only because it guessed `sysv_2017` with an underscore).
#
# If our real parser RTL elaborates this way, the sv2v step goes away — and with it
# the monolithic flatten that defeated BSRAM inference and made cv64a6_imafdc look
# like it overflowed the device (fpga-platform-assessment.md 5a).

puts "=== SV probe: GowinSynthesis on rtl/*.sv, SystemVerilog mode ==="

set candidates {
  {-name GW5AST-138B GW5AST-LV138FPG676AC1/I0}
  {GW5AST-LV138FPG676AC1/I0}
}
set chosen ""
foreach c $candidates { if {![catch {set_device {*}$c}]} { set chosen $c; break } }
if {$chosen eq ""} { puts "PROBE RESULT: FAIL (no device)"; exit 1 }
puts "device: $chosen"

set ok 0
foreach v {sysv2017 sysv-2017 sysv} {
  if {[catch {set_option -verilog_std $v} err]} {
    puts "  rejected: -verilog_std $v"
  } else {
    puts "  ACCEPTED: set_option -verilog_std $v"
    set ok 1
    break
  }
}
if {!$ok} { puts "PROBE RESULT: FAIL (no SystemVerilog std accepted)"; exit 2 }

# NOTE: no -type. Let add_file detect .sv by extension rather than forcing Verilog.
add_file /work/rtl/parser_pkg.sv
add_file /work/rtl/parser_execute.sv

set_option -top_module parser_execute
set_option -synthesis_tool gowinsynthesis
set_option -output_base_name sv_probe

if {[catch {run syn} err]} {
    puts "RUN SYN FAILED: $err"
    puts "PROBE RESULT: NO-GO (sv2v still required for our RTL)"
    exit 3
}
puts "run syn: OK"
puts "PROBE RESULT: GO — GowinSynthesis reads our SystemVerilog directly."
