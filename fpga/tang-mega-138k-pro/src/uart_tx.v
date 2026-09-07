//
// uart_tx.v — minimal 8N1 UART transmitter.
//
// Plain Verilog-2001: GowinSynthesis parses `add_file -type verilog` in Verilog
// mode and rejects SystemVerilog constructs. See blinky_top.v.
//
// Handshake: assert `send` for one cycle while `busy` is low; `data` is captured
// on that cycle. `busy` stays high until the stop bit has been held for a full
// bit period, so the caller can simply wait for `!busy` before the next byte.
//
// 10 bit periods per byte: 1 start (low), 8 data (LSB first), 1 stop (high).
//
module uart_tx (
    input            clk,
    input      [7:0] data,
    input            send,
    output reg       busy,
    output reg       tx
);

  parameter CLK_HZ = 32'd50_000_000;
  parameter BAUD   = 32'd115_200;

  // Cycles per bit. 50 MHz / 115200 = 434 (0.16% error, well inside the ~5%
  // a UART receiver tolerates). Sized explicitly at 20 bits so the comparison
  // below is width-matched (Verilator WIDTHEXPAND otherwise) and so slow bauds
  // still fit: 20 bits covers down to ~48 baud at 50 MHz.
  localparam [31:0] DIV32 = CLK_HZ / BAUD;
  localparam [19:0] DIV   = DIV32[19:0];   // part-select an identifier: Verilog-2001 legal

  reg [19:0] baud_cnt;
  reg  [3:0] bit_idx;
  reg  [8:0] shreg;      // stop bit + 8 data bits; the start bit is driven directly

  initial begin
    tx       = 1'b1;     // idle high
    busy     = 1'b0;
    baud_cnt = 20'd0;
    bit_idx  = 4'd0;
    shreg    = 9'h1FF;
  end

  always @(posedge clk) begin
    if (!busy) begin
      tx <= 1'b1;
      if (send) begin
        shreg    <= {1'b1, data};   // stop bit trails the data
        tx       <= 1'b0;           // start bit, driven now
        bit_idx  <= 4'd0;
        baud_cnt <= 20'd0;
        busy     <= 1'b1;
      end
    end else begin
      if (baud_cnt == DIV - 20'd1) begin
        baud_cnt <= 20'd0;
        tx       <= shreg[0];
        shreg    <= {1'b1, shreg[8:1]};
        // bit_idx 9 means the stop bit has just had its full period: done.
        if (bit_idx == 4'd9) busy <= 1'b0;
        bit_idx <= bit_idx + 4'd1;
      end else begin
        baud_cnt <= baud_cnt + 20'd1;
      end
    end
  end

endmodule
