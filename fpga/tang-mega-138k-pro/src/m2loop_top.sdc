#
# m2loop_top.sdc — timing constraints for the M2 UART loopback.
#
# A UART at 115200 baud does not need timing help; this exists so the flow emits a
# real timing report on every board build (Phase 6 gap G14). The RX path is an async
# input double-flopped into the clock domain, so it has no launch clock to constrain.
#
# 50 MHz on P16 -> 20 ns period.
#
create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {clk}]
