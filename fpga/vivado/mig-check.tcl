# fpga/vivado/mig-check.tcl
#
# Board-file-free DDR3 MIG (7-series) generation + out-of-context synth from an
# EXPLICIT .prj, to validate a memory pinout — byte-lane/bank legality, address
# width, part fit — BEFORE any board exists. This mirrors CVA6's own
# corev_apu/fpga/xilinx/xlnx_mig_7_ddr3/tcl/run.tcl, minus the `set_property
# board_part` line: pins come from the .prj (CONFIG.XML_INPUT_FILE), so no vendor
# board files are needed (the ALINX AX7325B is not in Vivado's board store).
#
# tclargs: <part> <prj_file_abspath>
#   <part>            e.g. xc7k325tffg900-2 (AX7325B / Genesys 2 die)
#   <prj_file>        absolute path to the MIG .prj (e.g. fpga/ax7325b/mig_ax7325b.prj)
#
# Run from an empty working directory (the caller cds into it): the project and all
# IP outputs are created under `.`, matching the reference flow's relative paths.
#
# Markers for the runner to grep: MIG_GENERATE_OK, MIG_SYNTH_STATUS, MIG_SYNTH_OK/FAIL.

if {$argc < 2} {
  puts "ERROR: usage: mig-check.tcl <part> <prj_file_abspath>"
  exit 2
}
set part    [lindex $argv 0]
set prjFile [lindex $argv 1]
set ipName  xlnx_mig_7_ddr3

if {![file exists $prjFile]} {
  puts "ERROR: MIG .prj not found: $prjFile"
  exit 2
}

puts "=== mig-check: part=$part prj=$prjFile ==="

create_project $ipName . -force -part $part
# NB: no `set_property board_part` — deliberately board-file-free (part-only), the
# same model the AX7325B port uses since ALINX boards ship no Vivado board_part.

create_ip -name mig_7series -vendor xilinx.com -library ip -module_name $ipName

set ipDir ./$ipName.srcs/sources_1/ip/$ipName
set xci   $ipDir/$ipName.xci
file copy -force $prjFile $ipDir/mig_a.prj

set_property -dict [list \
  CONFIG.XML_INPUT_FILE {mig_a.prj} \
  CONFIG.RESET_BOARD_INTERFACE {Custom} \
  CONFIG.MIG_DONT_TOUCH_PARAM {Custom} \
  CONFIG.BOARD_MIG_PARAM {Custom}] [get_ips $ipName]

# generate_target all elaborates the controller from the .prj: this is where an
# illegal byte-lane/bank grouping or an out-of-range address surfaces.
generate_target {instantiation_template} [get_files $xci]
generate_target all [get_files $xci]
puts "MIG_GENERATE_OK"

# OOC synth of the generated controller — confirms it maps onto the part's IOBs/banks.
create_ip_run [get_files -of_objects [get_fileset sources_1] $xci]
launch_run -jobs 8 ${ipName}_synth_1
wait_on_run ${ipName}_synth_1

set st [get_property STATUS   [get_runs ${ipName}_synth_1]]
set pr [get_property PROGRESS [get_runs ${ipName}_synth_1]]
puts "MIG_SYNTH_STATUS: $st ($pr)"
if {$pr eq "100%"} {
  puts "MIG_SYNTH_OK"
} else {
  puts "MIG_SYNTH_FAIL"
  exit 1
}
