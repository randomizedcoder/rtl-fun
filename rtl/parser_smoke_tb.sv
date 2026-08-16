// parser_smoke_tb.sv — Verilator smoke test for the parser unit (Phase 5).
//
// Runs the generated slice program (rtl/gen/gen_parser_rom.c) on a canned packet
// through parser_top and asserts the resulting metadata bytes equal the golden
// model's flow_keys, byte-for-byte. Build/run: scripts/parser-sim.sh
// (nix run .#parser-sim). Requires Verilator `--assert` for the checks below.
//
// smoke_params.svh is generated alongside the hex files and defines:
//   PKT_LEN, META_LEN, and the expected exit CODE.

// A tiny test macro: assert + tally, so one run reports every mismatch.
`define CHECK(cond, msg) \
  do begin \
    checks++; \
    assert (cond) else begin fails++; $error("CHECK failed: %s", msg); end \
  end while (0)

module parser_smoke_tb
  import parser_pkg::*;
;

  // generated: localparam PKT_LEN, META_LEN, EXP_CODE
  `include "smoke_params.svh"

  logic clk;
  logic rst_n;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  logic [15:0]          parse_len;
  logic [META_OFF_W-1:0] meta_raddr;
  logic [7:0]           meta_rdata;
  logic                 done;
  logic signed [31:0]   code;
  logic                 busy;

  parser_top #(
      .PROG_FILE("program.hex"),
      .CAM_FILE ("cam.hex"),
      .PKT_FILE ("packet.hex")
  ) dut (
      .clk_i(clk), .rst_ni(rst_n),
      .parse_len_i(parse_len),
      .meta_raddr_i(meta_raddr), .meta_rdata_o(meta_rdata),
      .done_o(done), .code_o(code), .busy_o(busy)
  );

  // expected metadata bytes (the model's flow_keys image)
  logic [7:0] exp_mem [0:META_MAX-1];

  int checks = 0;
  int fails  = 0;

  // waveform dump — enabled only in the trace/debug Verilator targets
  // (nix run .#parser-sim-trace / .#parser-sim-debug), which pass +define+DUMP.
`ifdef DUMP
  initial begin
    $dumpfile("parser.vcd");
    $dumpvars(0, parser_smoke_tb);
  end
`endif

  initial begin
    for (int i = 0; i < META_MAX; i++) exp_mem[i] = 8'h0;
    $readmemh("expected.hex", exp_mem);
    parse_len  = PKT_LEN[15:0];
    meta_raddr = '0;

    // reset
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    // run until the parser exits (guarded)
    fork
      begin : run
        int cyc;
        cyc = 0;
        while (!done && cyc < 5000) begin @(posedge clk); cyc++; end
        `CHECK(done, "parser reached done");
      end
    join

    // exit code matches the model
    `CHECK(code == EXP_CODE, "exit code == model exit code");

    // metadata (flow_keys) matches the model, byte for byte
    for (int b = 0; b < META_LEN; b++) begin
      meta_raddr = b[META_OFF_W-1:0];
      #1;   // settle combinational read
      `CHECK(meta_rdata == exp_mem[b],
             $sformatf("meta[%0d]=%02x exp=%02x", b, meta_rdata, exp_mem[b]));
    end

    $display("--------------------------------------------------");
    $display("parser smoke: exit code = %0d (expected %0d)", code, EXP_CODE);
    $display("parser smoke: %0d checks, %0d failures", checks, fails);
    if (fails == 0) $display("parser smoke: PASS");
    else            $display("parser smoke: FAIL");
    $display("--------------------------------------------------");
    if (fails != 0) $fatal(1, "smoke test failed");
    $finish;
  end

endmodule : parser_smoke_tb
