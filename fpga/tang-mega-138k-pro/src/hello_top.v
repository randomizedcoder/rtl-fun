//
// hello_top.v — UART "hello world" for the Tang Mega 138K Pro (Phase 8).
//
// The successor to blinky_top.v: proves the second half of the debug channel.
// The board's single "USB JTAG&UART" cable carries TWO FT2232 interfaces —
// interface A is the JTAG we program over, interface B is a UART that lands on
// the host as /dev/ttyUSB1. This drives it.
//
// Why this matters more than it looks: six LEDs carry six bits and only a human
// can read them. A UART carries unbounded structured text that a HOST SCRIPT can
// read and diff against the golden model. It is the transport every later test
// rides on — including rung A of the packet ladder (inject a frame, read the
// flow_keys back) which needs no Ethernet at all.
//
// Plain Verilog-2001 on purpose — see blinky_top.v.
//
// Board facts (docs/fpga-bringup-tang-mega-138k-pro.md):
//   clk       P16, 50 MHz
//   uart_tx   P15   (FPGA -> debugger -> host /dev/ttyUSB1)
//   led[5:0]  N23 N21 M25 L20 R26 J14, ACTIVE LOW
//
// Emits, twice a second:
//     rtl-fun uart 0000
//     rtl-fun uart 0001
//     ...
// The counter is the point: a static banner could be a stuck buffer or an echo,
// but a monotonically incrementing sequence proves the design is live and that
// we are reading it at the right baud. The LEDs show the low 6 bits of the same
// counter, so the blinking and the text are visibly correlated — if they disagree,
// something is wrong with one of the two paths.
//
module hello_top (
    input        clk,
    output [5:0] led,
    output       uart_tx_pin
);

  parameter CLK_HZ  = 32'd50_000_000;
  parameter BAUD    = 32'd115_200;
  parameter GAP_DIV = 32'd25_000_000;   // 0.5 s between lines

  // "rtl-fun uart XXXX\r\n"
  localparam MSG_LEN = 5'd19;

  reg [31:0] gap_cnt;
  reg  [4:0] idx;
  reg [15:0] seq;
  reg  [1:0] st;
  reg        send;

  wire       busy;
  reg  [7:0] ch;

  initial begin
    gap_cnt = 32'd0;
    idx     = 5'd0;
    seq     = 16'd0;
    st      = 2'd0;
    send    = 1'b0;
  end

  uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
      .clk  (clk),
      .data (ch),
      .send (send),
      .busy (busy),
      .tx   (uart_tx_pin)
  );

  // 4-bit nibble -> ASCII hex digit.
  function [7:0] hexchar;
    input [3:0] n;
    begin
      hexchar = (n < 4'd10) ? (8'd48 + {4'd0, n})          // '0'..'9'
                            : (8'd87 + {4'd0, n});         // 'a'..'f' (97 - 10)
    end
  endfunction

  always @(*) begin
    case (idx)
      5'd0:    ch = "r";
      5'd1:    ch = "t";
      5'd2:    ch = "l";
      5'd3:    ch = "-";
      5'd4:    ch = "f";
      5'd5:    ch = "u";
      5'd6:    ch = "n";
      5'd7:    ch = " ";
      5'd8:    ch = "u";
      5'd9:    ch = "a";
      5'd10:   ch = "r";
      5'd11:   ch = "t";
      5'd12:   ch = " ";
      5'd13:   ch = hexchar(seq[15:12]);
      5'd14:   ch = hexchar(seq[11:8]);
      5'd15:   ch = hexchar(seq[7:4]);
      5'd16:   ch = hexchar(seq[3:0]);
      5'd17:   ch = 8'd13;   // CR
      default: ch = 8'd10;   // LF
    endcase
  end

  always @(posedge clk) begin
    send <= 1'b0;
    case (st)
      2'd0: begin                       // idle gap between lines
        if (gap_cnt >= GAP_DIV - 1) begin
          gap_cnt <= 32'd0;
          idx     <= 5'd0;
          st      <= 2'd1;
        end else begin
          gap_cnt <= gap_cnt + 32'd1;
        end
      end
      2'd1: begin                       // offer the next character
        if (!busy) begin
          send <= 1'b1;
          st   <= 2'd2;
        end
      end
      default: begin                    // wait for the byte to be accepted
        if (busy) begin
          if (idx == MSG_LEN - 5'd1) begin
            seq <= seq + 16'd1;
            st  <= 2'd0;
          end else begin
            idx <= idx + 5'd1;
            st  <= 2'd1;
          end
        end
      end
    endcase
  end

  // Active low. Low 6 bits of the line counter, so the LEDs and the text agree.
  assign led = ~seq[5:0];

endmodule
