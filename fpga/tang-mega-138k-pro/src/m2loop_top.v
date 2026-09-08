//
// m2loop_top.v — Phase 8 M2 rung 0: confirm the UART RX pin (host -> FPGA) on the
// board before building the real packet-injection datapath.
//
// The USB debug UART is transmit-only from fabric: its RX net (N16) is a dedicated CPU
// pin PnR refuses. So M2's UART runs over an EXTERNAL 3.3 V USB-TTL adapter wired to
// PMOD2 (bank 5): uart_rx_pin = C21 (adapter TX), uart_tx_pin = B20 (adapter RX). This
// design registers the async RX line and echoes it straight back out TX, so anything
// the host types on the adapter's /dev/ttyUSB* round-trips to its own terminal. If the
// echo comes back, the adapter + pins + wiring are good — the milestone fails for
// exactly one reason before we build the real injection datapath.
//
// Plain Verilog-2001 (like hello_top.v): a pure loopback needs no SystemVerilog, so
// it also sidesteps the GowinSynthesis SP00018 front-end bug (status challenge #13).
//
// Whole bank is 3.3 V.
//
module m2loop_top (
    input  wire       clk,          // P16, 50 MHz
    input  wire       uart_rx_pin,  // N16, debugger -> FPGA (host TX)
    output wire       uart_tx_pin,  // P15, FPGA -> debugger (host RX)
    output wire [5:0] led           // active low
);
    // Double-flop the asynchronous RX line into the clock domain, then drive TX from
    // it. At 50 MHz this oversamples the 115200-baud line ~434x, so the echoed
    // waveform is a clean, <=40 ns-delayed copy — the host reads back what it sent.
    reg rx_s0, rx_s1, rx_s2;
    always @(posedge clk) begin
        rx_s0 <= uart_rx_pin;
        rx_s1 <= rx_s0;
        rx_s2 <= rx_s1;
    end

    assign uart_tx_pin = rx_s1;

    // Second, eyeball-only path: stretch a ~0.17 s pulse on every falling edge (a
    // UART start bit) so led[0] visibly flickers while the host is sending, even
    // with no terminal attached. led[5] mirrors the idle-high line level.
    reg [22:0] act;                 // 2^23 / 50e6 ~= 0.168 s
    always @(posedge clk) begin
        if (rx_s2 & ~rx_s1)         // high -> low: start bit seen
            act <= 23'h7FFFFF;
        else if (act != 23'd0)
            act <= act - 23'd1;
    end
    wire active = (act != 23'd0);

    assign led = ~{ rx_s1, 4'b0000, active };
endmodule
