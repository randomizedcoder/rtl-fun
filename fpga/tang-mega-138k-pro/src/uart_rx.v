//
// uart_rx.v — minimal 8N1 UART receiver (oversampling, majority-free mid-bit sample).
//
// Plain Verilog-2001 to match uart_tx.v (GowinSynthesis Verilog mode). Companion to
// uart_tx: 1 start (low), 8 data (LSB first), 1 stop (high). No parity, no flow ctrl.
//
// Output: `valid` pulses high for exactly one clk when a byte has been received;
// `data` holds it that cycle. The async `rx` line is double-flopped first.
//
// Sampling: wait for the falling edge (start bit), then sample each of the 8 data
// bits at the CENTRE of its bit period (DIV/2 + k*DIV from the edge). Robust to the
// 0.16% baud error at 50 MHz / 115200.
//
module uart_rx (
    input            clk,
    input            rx,
    output reg [7:0] data,
    output reg       valid
);

  parameter CLK_HZ = 32'd50_000_000;
  parameter BAUD   = 32'd115_200;

  localparam [31:0] DIV32 = CLK_HZ / BAUD;
  localparam [19:0] DIV   = DIV32[19:0];        // cycles per bit
  localparam [19:0] HALF  = DIV32[20:1];        // DIV/2, mid-bit offset

  // double-flop the async input
  reg rx_s0, rx_s1, rx_s2;

  reg        busy;
  reg [19:0] cnt;        // sub-bit counter
  reg  [3:0] bit_idx;    // 0..7 data bits, then stop
  reg  [7:0] shreg;

  initial begin
    data    = 8'h00;
    valid   = 1'b0;
    rx_s0   = 1'b1;
    rx_s1   = 1'b1;
    rx_s2   = 1'b1;
    busy    = 1'b0;
    cnt     = 20'd0;
    bit_idx = 4'd0;
    shreg   = 8'h00;
  end

  always @(posedge clk) begin
    rx_s0 <= rx;
    rx_s1 <= rx_s0;
    rx_s2 <= rx_s1;
    valid <= 1'b0;                 // default; pulsed for one cycle on a full byte

    if (!busy) begin
      // idle: look for the start-bit falling edge (rx_s2 high, rx_s1 low)
      if (rx_s2 & ~rx_s1) begin
        busy    <= 1'b1;
        cnt     <= HALF;           // first sample at the centre of the start bit
        bit_idx <= 4'd0;
      end
    end else begin
      if (cnt == 20'd0) begin
        cnt <= DIV - 20'd1;        // next sample one full bit later
        if (bit_idx == 4'd0) begin
          // centre of the start bit: confirm it is still low (else false start)
          if (rx_s1) busy <= 1'b0; // glitch — abandon
          bit_idx <= 4'd1;
        end else if (bit_idx <= 4'd8) begin
          // centre of data bit (bit_idx-1); LSB first
          shreg <= {rx_s1, shreg[7:1]};
          if (bit_idx == 4'd8) begin
            data    <= {rx_s1, shreg[7:1]};
            valid   <= 1'b1;       // byte complete (do not wait for the stop bit)
            busy    <= 1'b0;
          end
          bit_idx <= bit_idx + 4'd1;
        end
      end else begin
        cnt <= cnt - 20'd1;
      end
    end
  end

endmodule
