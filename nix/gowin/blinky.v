//
// nix/gowin/blinky.v — trivial design-under-test for the Tier-1 Gowin license/device gate.
//
// A 26-bit counter driving one LED. Plain Verilog-2001 (GowinSynthesis parses `add_file
// -type verilog` in Verilog mode — SystemVerilog `logic`/`always_ff` are rejected there).
// Deliberately tiny: it exercises synth + place-and-route for GW5AST-LV138FPG676A without
// any board-specific IP, so a clean run proves the license permits the part. Just a probe.
//
module blinky (
    input  clk,
    input  rst_n,
    output led
);
  reg [25:0] cnt;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) cnt <= 26'd0;
    else        cnt <= cnt + 26'd1;
  end

  assign led = cnt[25];
endmodule
