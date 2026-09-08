#
# m2_top.sdc — timing constraints for Phase-8 M2 (host packet injection).
#
# A 115200-baud UART needs no timing help; this exists so the flow emits a real timing
# report on every board build (Phase 6 gap G14). The uart_rx input is async and
# double-flopped inside uart_rx.v, so it has no launch clock to constrain.
#
# 50 MHz on P16 -> 20 ns period.
#
create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {clk}]
