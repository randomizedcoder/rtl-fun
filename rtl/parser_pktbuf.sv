// parser_pktbuf.sv — packet buffer + byte aligner (Phase 5, §4.2/§4.6).
//
// Holds the packet bytes and serves the extract datapath a big-endian value of
// the 8 bytes starting at an arbitrary byte offset. Internally this is a
// PKT_WINDOW_W (128-bit) read at an 8-byte-aligned base plus an aligner that
// selects the requested 8 bytes — the D1 decision (a 16-byte window based at the
// 8-aligned offset always contains the ≤8 bytes a load needs, no straddle).
//
// `mem` is written by the testbench via a hierarchical $readmemh in simulation;
// in the real core it is filled through the write port below — driven by the SoC
// MMIO packet-buffer peripheral, so a bare-metal program `sd`s the packet in (I5;
// closes the deferred MMIO escalation). The combinational read window is unchanged.

module parser_pktbuf
  import parser_pkg::*;
#(
    parameter string INIT_FILE = ""            // sim: packet bytes ($readmemh)
) (
    input  logic                 clk_i,
    // ---- 64-bit write port (MMIO packet preload, I5) ----
    // Mirrors the SoC axi2mem beat: an 8-byte-aligned base + per-lane byte enables,
    // so a bare-metal `sd` scatters up to 8 packet bytes in one transaction. Byte k
    // (wr_be_i[k]) is wr_data_i[8*k +: 8] and lands at packet offset wr_addr_i + k.
    input  logic                 wr_en_i,      // write strobe (one AXI beat)
    input  logic [PKT_OFF_W-1:0] wr_addr_i,    // 8-byte-aligned base offset
    input  logic [7:0]           wr_be_i,      // per-byte write enables
    input  logic [63:0]          wr_data_i,    // 8 bytes, little-endian
    // ---- read window (extract datapath) ----
    input  logic [PKT_OFF_W-1:0] req_off_i,   // absolute byte offset
    output logic [63:0]          win_be_o     // 8 bytes at req_off, big-endian (req_off = MSB)
);

  // packet storage (byte-addressable)
  logic [7:0] mem [0:PKT_MAX-1];
  initial begin
    for (int i = 0; i < PKT_MAX; i++) mem[i] = 8'h0;
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  // MMIO write: scatter the enabled lanes (range-checked like the read path). The
  // zero-init above still runs in sim; the write port overrides bytes as the
  // preload stores land.
  always_ff @(posedge clk_i) begin
    if (wr_en_i) begin
      for (int k = 0; k < 8; k++) begin
        logic [PKT_OFF_W:0] a;
        a = {1'b0, wr_addr_i} + k[PKT_OFF_W:0];
        if (wr_be_i[k] && a < PKT_MAX[PKT_OFF_W:0])
          mem[a[$clog2(PKT_MAX)-1:0]] <= wr_data_i[8*k +: 8];
      end
    end
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
