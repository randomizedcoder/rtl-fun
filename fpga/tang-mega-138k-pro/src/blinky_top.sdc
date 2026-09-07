#
# blinky_top.sdc — timing constraints for the Tang Mega 138K Pro blinky.
#
# A 6-LED walker does not need timing help. This exists so the flow reports real
# timing from the very first build: Phase 6 closed verification gaps G1-G13 and
# explicitly deferred G14 (timing / physical) to Phase 8, so every board build
# from here on should produce a timing report we can read.
#
# 50 MHz on P16 -> 20 ns period.
#
create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {clk}]
