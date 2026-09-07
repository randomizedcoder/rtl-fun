#
# hello_top.sdc — timing constraints for the Tang Mega 138K Pro hello.
#
# A UART at 115200 baud does not need timing help. This exists so the flow reports
# real timing on every board build: Phase 6 closed verification gaps G1-G13 and
# explicitly deferred G14 (timing / physical) to Phase 8, so every board build
# from here on should produce a timing report we can read.
#
# 50 MHz on P16 -> 20 ns period.
#
create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {clk}]
