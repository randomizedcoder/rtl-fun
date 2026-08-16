// parser_pktbuf.sv — packet buffer + byte aligner (Phase 5, §4.2/§4.6).
//
// Holds the packet bytes and serves the extract datapath a big-endian value of
// the 8 bytes starting at an arbitrary byte offset. Internally this is a
// PKT_WINDOW_W (128-bit) read at an 8-byte-aligned base plus an aligner that
// selects the requested 8 bytes — the D1 decision (a 16-byte window based at the
// 8-aligned offset always contains the ≤8 bytes a load needs, no straddle).
//
// `mem` is written by the testbench via a hierarchical $readmemh in simulation;
// in the real core it is filled by the packet DMA / preload path (Phase 8).

module parser_pktbuf
  import parser_pkg::*;
#(
    parameter string INIT_FILE = ""            // sim: packet bytes ($readmemh)
) (
    input  logic [PKT_OFF_W-1:0] req_off_i,   // absolute byte offset
    output logic [63:0]          win_be_o     // 8 bytes at req_off, big-endian (req_off = MSB)
);

  // packet storage (byte-addressable)
  logic [7:0] mem [0:PKT_MAX-1];
  initial begin
    for (int i = 0; i < PKT_MAX; i++) mem[i] = 8'h0;
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  // 8-byte-aligned base + 3-bit sub-offset within the 16-byte window
  logic [PKT_OFF_W-1:0] base;
  logic [2:0]           sub;
  assign base = {req_off_i[PKT_OFF_W-1:3], 3'b000};
  assign sub  = req_off_i[2:0];

  // 128-bit window (16 bytes) at base; win[0] is the byte at `base`.
  localparam int unsigned PKT_IDX_W = $clog2(PKT_MAX);
  logic [7:0] win [0:15];
  always_comb begin
    for (int i = 0; i < 16; i++) begin
      logic [PKT_OFF_W+1:0] a;
      a = {2'b0, base} + i[PKT_OFF_W+1:0];
      win[i] = (a < (PKT_MAX[PKT_OFF_W+1:0])) ? mem[a[PKT_IDX_W-1:0]] : 8'h00;
    end
  end

  // aligner: select the 8 bytes starting at `sub`, pack big-endian (first = MSB).
  always_comb begin
    win_be_o = 64'h0;
    for (int k = 0; k < 8; k++) begin
      win_be_o = win_be_o | ({56'h0, win[sub + k[3:0]]} << (8 * (7 - k)));
    end
  end

endmodule : parser_pktbuf
