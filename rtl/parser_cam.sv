// parser_cam.sv — behavioral CAM lookup (Phase 5, §4.3/§4.6).
//
// A CAM entry is a 20-bit key (share[3:0] + match[15:0]) → 32-bit target, per the
// patent (20-bit key + 32-bit target). This is the *behavioral* model chosen for
// bring-up (phase-5 §5.6 decision); a synthesizable structure lands later behind
// this same interface. Entries are loaded by the testbench via a hierarchical
// $readmemh into `entry`; in the real core they are written from the integer side
// via the custom-3 CPPRSWRCAM path (see docs/analysis/cva6-integration.md).
//
// Lookup mirrors cam_lookup() in parser.c: match on (share == req_share) &&
// (match == req_match); first hit wins; miss → hit_o = 0.

module parser_cam
  import parser_pkg::*;
#(
    parameter string INIT_FILE = ""            // sim: CAM entries ($readmemh)
) (
    input  logic [3:0]  share_i,
    input  logic [15:0] match_i,
    output logic        hit_o,
    output logic [31:0] target_o
);

  // one packed word per entry: {valid, share[3:0], match[15:0], target[31:0]}
  localparam int unsigned ENTRY_W = 1 + 4 + 16 + 32;   // 53
  logic [ENTRY_W-1:0] entry [0:CAM_DEPTH-1];
  initial begin
    for (int i = 0; i < CAM_DEPTH; i++) entry[i] = '0;
    if (INIT_FILE != "") $readmemh(INIT_FILE, entry);
  end

  always_comb begin
    hit_o    = 1'b0;
    target_o = 32'h0;
    for (int i = 0; i < CAM_DEPTH; i++) begin
      logic        v;
      logic [3:0]  sh;
      logic [15:0] mt;
      logic [31:0] tg;
      {v, sh, mt, tg} = entry[i];
      if (!hit_o && v && (sh == share_i) && (mt == match_i)) begin
        hit_o    = 1'b1;
        target_o = tg;
      end
    end
  end

endmodule : parser_cam
