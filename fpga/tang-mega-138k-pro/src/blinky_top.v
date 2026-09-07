//
// blinky_top.v — the first design WE build for the Tang Mega 138K Pro (Phase 8).
//
// Purpose is not the design, it is the loop: prove that our own RTL goes through
// Gowin synthesis + place-and-route, becomes a .fs, programs over USB-JTAG, and
// visibly runs. Everything after this (UART hello world, then CVA6) rides on the
// same path.
//
// PLAIN VERILOG-2001 ON PURPOSE. GowinSynthesis parses `add_file -type verilog`
// in Verilog mode and rejects SystemVerilog `logic` / `always_ff`, which is why
// nix/gowin/blinky.v is written the same way. Do not "modernize" this file.
//
// Board facts (see docs/fpga-bringup-tang-mega-138k-pro.md):
//   clk       P16, 50 MHz
//   led[5:0]  N23 N21 M25 L20 R26 J14, ACTIVE LOW (vendor led.v drives `~led_reg`)
//
// No reset input. The board has four buttons and the vendor examples disagree
// about which is reset and in what polarity (led/src/top.cst uses U4 active-high,
// pro_ddr_test/src/pro.cst uses K16 active-low), so this removes the question
// entirely: the counters self-initialize and free-run.
//
// It cycles through six patterns, ~3.75 s each. A SEQUENCE is a much better
// bring-up signal than any single pattern: the board's factory flash image
// ping-pongs a dot forever and Sipeed's led.fs fills a bar, so either one alone
// can be mistaken for ours, but neither ever CHANGES to something else. Watch it
// for ten seconds and there is no doubt whose bitstream is running. (Two earlier
// single-pattern versions were both ambiguous on real hardware, 2026-09-07.)
//
//   0  all six flash together
//   1  single dot walking up, wrapping
//   2  single dot ping-ponging back and forth
//   3  bar filling up, then resetting
//   4  odd/even LEDs alternating
//   5  two dots converging to the middle and back out
//
module blinky_top (
    input        clk,
    output [5:0] led
);

  // Animation step rate. 50 MHz / 6_250_000 = 8 steps/sec.
  // THIS IS THE KNOB: change it, rebuild, reload, and everything must visibly
  // speed up or slow down — that round trip is the deliverable of this design.
  parameter TICK_DIV  = 32'd6_250_000;

  // Steps per pattern. 30 is divisible by 6 and 10, so the walk and ping-pong
  // sub-counters always land back at 0 exactly when the pattern changes.
  parameter PAT_STEPS = 6'd30;

  reg [31:0] tick_cnt;   // clock divider
  reg  [5:0] step_cnt;   // 0..29, position within the current pattern
  reg  [2:0] c6;         // 0..5   six-step cycle (walk, bar, converge)
  reg  [3:0] c10;        // 0..9   ten-step cycle (ping-pong: 0..5 then 4..1)
  reg  [2:0] pat;        // 0..5   which pattern is playing

  initial begin
    tick_cnt = 32'd0;
    step_cnt = 6'd0;
    c6       = 3'd0;
    c10      = 4'd0;
    pat      = 3'd0;
  end

  always @(posedge clk) begin
    if (tick_cnt >= TICK_DIV - 1) begin
      tick_cnt <= 32'd0;

      c6  <= (c6  == 3'd5) ? 3'd0 : c6  + 3'd1;
      c10 <= (c10 == 4'd9) ? 4'd0 : c10 + 4'd1;

      if (step_cnt == PAT_STEPS - 6'd1) begin
        step_cnt <= 6'd0;
        pat      <= (pat == 3'd5) ? 3'd0 : pat + 3'd1;
      end else begin
        step_cnt <= step_cnt + 6'd1;
      end
    end else begin
      tick_cnt <= tick_cnt + 32'd1;
    end
  end

  // --- pattern shapes, each in its own block (flat case statements only; nested
  // cases inside one always are legal Verilog but needless risk in a vendor tool)

  reg [2:0] ppos;   // ping-pong position: 0,1,2,3,4,5,4,3,2,1
  always @(*) begin
    case (c10)
      4'd0:    ppos = 3'd0;
      4'd1:    ppos = 3'd1;
      4'd2:    ppos = 3'd2;
      4'd3:    ppos = 3'd3;
      4'd4:    ppos = 3'd4;
      4'd5:    ppos = 3'd5;
      4'd6:    ppos = 3'd4;
      4'd7:    ppos = 3'd3;
      4'd8:    ppos = 3'd2;
      default: ppos = 3'd1;
    endcase
  end

  reg [5:0] bar;    // filling bar
  always @(*) begin
    case (c6)
      3'd0:    bar = 6'b000001;
      3'd1:    bar = 6'b000011;
      3'd2:    bar = 6'b000111;
      3'd3:    bar = 6'b001111;
      3'd4:    bar = 6'b011111;
      default: bar = 6'b111111;
    endcase
  end

  reg [5:0] conv;   // two dots converging, then back out
  always @(*) begin
    case (c6)
      3'd0:    conv = 6'b100001;
      3'd1:    conv = 6'b010010;
      3'd2:    conv = 6'b001100;
      3'd3:    conv = 6'b001100;
      3'd4:    conv = 6'b010010;
      default: conv = 6'b100001;
    endcase
  end

  // --- the sequencer -------------------------------------------------------
  reg [5:0] dot;    // active-HIGH "which LEDs should be lit"
  always @(*) begin
    case (pat)
      3'd0:    dot = step_cnt[1] ? 6'b111111 : 6'b000000;  // all flash (2 Hz)
      3'd1:    dot = 6'b000001 << c6;                      // walk up
      3'd2:    dot = 6'b000001 << ppos;                    // ping-pong
      3'd3:    dot = bar;                                  // filling bar
      3'd4:    dot = step_cnt[0] ? 6'b101010 : 6'b010101;  // odd/even
      default: dot = conv;                                 // converge/diverge
    endcase
  end

  // Active low: a 1 in `dot` must pull its pin to 0 to light that LED.
  assign led = ~dot;

endmodule
