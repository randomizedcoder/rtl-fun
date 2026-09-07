#
# m1_top.sdc — timing constraints for the M1 parser-on-ROM design.
#
# The parser datapath is combinational per micro-op (parser_execute) clocked one
# op/cycle by parser_top's sequencer; the UART runs at 115200. Neither is timing-
# hard, but every board build should report real timing — Phase 6 deferred gap G14
# (timing / physical) to Phase 8, and this is the first design with non-trivial
# logic depth to close it against.
#
# 50 MHz on P16 -> 20 ns period.
#
create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {clk}]
