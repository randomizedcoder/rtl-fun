// parser_top.sv — bring-up scaffold that runs a whole parse program (Phase 5).
//
// IMPORTANT (honesty / layering): this module is NOT the Phase-4 microarchitecture.
// Phase 4 (D2) puts the parser in CVA6 as a single-instruction functional unit
// whose end-of-node drives CVA6's fetch redirect (resolved_branch_o). Here, a tiny
// micro-PC + program ROM stand in for CVA6's fetch+redirect so the parser_execute
// datapath can run a full program in Verilator on its own — a self-contained smoke
// test producing a flow_keys. The real seam is cva6_parser_wrap.sv + the CVA6
// patch (docs/analysis/cva6-integration.md); this scaffold is a sim harness that
// mirrors the golden model's pm_run() loop exactly.
//
// Memories (prog_rom, u_cam.entry, u_pktbuf.mem) are filled by the testbench via
// hierarchical $readmemh; meta_mem is read back by the testbench to compare with
// the model's flow_keys.

module parser_top
  import parser_pkg::*;
#(
    parameter string PROG_FILE = "",
    parameter string CAM_FILE  = "",
    parameter string PKT_FILE  = "",
    parameter string ENC_FILE  = "",     // 32-bit encoded words (decode mode)
    parameter bit    USE_DECODE = 1'b0   // 1: source micro-ops via parser_decode
) (
    input  logic                clk_i,
    input  logic                rst_ni,
    input  logic [15:0]         parse_len_i,
    input  logic [META_OFF_W-1:0] meta_raddr_i,   // metadata read-back (sim)
    output logic [7:0]          meta_rdata_o,
    output logic                done_o,
    output logic signed [31:0]  code_o,
    output logic                busy_o
);

  // ---- program ROM + metadata RAM (ROM filled from PROG_FILE in sim) ----
  // Two program images of the SAME slice, so decode mode is a true equivalence
  // check: prog_rom holds the model-generated 96-bit micro-ops; enc_rom holds
  // the 32-bit Phase-3 words that parser_decode turns back into micro-ops.
  logic [ROM_W-1:0] prog_rom [0:PROG_MAX-1];
  logic [31:0]      enc_rom  [0:PROG_MAX-1];
  logic [7:0]       meta_mem [0:META_MAX-1];
  initial begin
    for (int i = 0; i < PROG_MAX; i++) prog_rom[i] = '0;
    for (int i = 0; i < PROG_MAX; i++) enc_rom[i]  = '0;
    if (PROG_FILE != "") $readmemh(PROG_FILE, prog_rom);
    if (ENC_FILE  != "") $readmemh(ENC_FILE,  enc_rom);
  end

  // ---- machine state ----
  pstate_t   st_q;
  logic [PC_W-1:0] pc_cur;
  logic [19:0]     guard_q;   // infinite-loop guard (model: 100000)

  assign pc_cur       = st_q.next_pc;
  assign done_o       = st_q.done;
  assign code_o       = st_q.code;
  assign busy_o       = rst_ni & ~st_q.done;
  localparam int unsigned META_IDX_W = $clog2(META_MAX);
  assign meta_rdata_o = meta_mem[meta_raddr_i[META_IDX_W-1:0]];

  // ---- current micro-op: from the ROM, or decoded from the 32-bit word ----
  micro_op_t op_rom, op_dec, op;
  logic      dec_illegal;
  assign op_rom = mop_from_word(prog_rom[pc_cur[$clog2(PROG_MAX)-1:0]]);
  parser_decode u_decode (
      .word_i   (enc_rom[pc_cur[$clog2(PROG_MAX)-1:0]]),
      .op_o     (op_dec),
      .illegal_o(dec_illegal)
  );
  assign op = USE_DECODE ? op_dec : op_rom;

  // ---- leaf units ----
  logic [PKT_OFF_W-1:0] mem_off;
  logic [63:0]          mem_win_be;
  parser_pktbuf #(.INIT_FILE(PKT_FILE)) u_pktbuf (.req_off_i(mem_off), .win_be_o(mem_win_be));

  logic [3:0]  cam_share;
  logic [15:0] cam_match;
  logic        cam_hit;
  logic [31:0] cam_target;
  parser_cam #(.INIT_FILE(CAM_FILE)) u_cam (
      .share_i(cam_share), .match_i(cam_match),
      .hit_o(cam_hit),     .target_o(cam_target)
  );

  // ---- functional unit ----
  pstate_t              st_n;
  logic                 meta_we;
  logic [META_OFF_W-1:0] meta_off;
  logic [63:0]          meta_wdata;
  logic [3:0]           meta_nbytes;
  parser_execute u_exec (
      .st_i(st_q), .op_i(op), .pc_i(pc_cur), .parse_len_i(parse_len_i),
      .mem_off_o(mem_off),   .mem_win_be_i(mem_win_be),
      .cam_share_o(cam_share), .cam_match_o(cam_match),
      .cam_hit_i(cam_hit),   .cam_target_i(cam_target),
      .meta_we_o(meta_we),   .meta_off_o(meta_off),
      .meta_wdata_o(meta_wdata), .meta_nbytes_o(meta_nbytes),
      .st_o(st_n)
  );

  // ---- initial machine state (pm_init) ----
  function automatic pstate_t init_state();
    pstate_t s;
    s = '0;
    s.databound = 32'hFFFF_FFFF;
    s.loop      = P_OKAY_RET;
    s.next      = P_STOP_OKAY;
    s.next_pc   = '0;
    return s;
  endfunction

  // ---- sequencer: one micro-op per cycle until done (pm_run) ----
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q    <= init_state();
      guard_q <= '0;
      for (int i = 0; i < META_MAX; i++) meta_mem[i] <= 8'h0;
    end else if (!st_q.done) begin
      guard_q <= guard_q + 20'd1;
      if (pc_cur >= PROG_MAX[PC_W-1:0]) begin
        st_q.done <= 1'b1; st_q.code <= P_STOP_FAIL;           // ran off the end
      end else if (guard_q > 20'd100000) begin
        st_q.done <= 1'b1; st_q.code <= P_STOP_FAIL;
      end else begin
        st_q <= st_n;
        // scatter the metadata write byte-by-byte; the write is bounds-checked
        // upstream (a_meta_inbounds), so meta_off+i never wraps META_MAX.
        if (meta_we) begin
          for (int i = 0; i < 8; i++)
            if (i < int'(meta_nbytes))
              meta_mem[META_IDX_W'(meta_off + i[META_OFF_W-1:0])]
                  <= meta_wdata[8*i +: 8];
        end
      end
    end
  end

  // ---- design assertions (compiled out unless +define+PARSER_ASSERT/FORMAL) ----
`include "parser_asserts.svh"
  // safety: metadata writes never escape the frame
  `PRS_ASSERT(a_meta_inbounds, clk_i, rst_ni,
      (!meta_we) || (({23'h0, meta_off} + {28'h0, meta_nbytes}) <= META_MAX))
  `PRS_ASSERT(a_meta_nbytes, clk_i, rst_ni, (meta_nbytes <= 4'd8))
  // safety: a load never addresses outside the packet buffer
  `PRS_ASSERT(a_load_off_range, clk_i, rst_ni,
      (op.op != OP_LOAD) || ({2'b0, mem_off} < 11'(PKT_MAX)))
  // liveness/consistency: exit code is always a negative parser code
  `PRS_ASSERT(a_exit_code_neg, clk_i, rst_ni, (!st_n.done) || (st_n.code < 0))
  // done is sticky — the parser never "un-exits"
  `PRS_ASSERT(a_done_sticky, clk_i, rst_ni, st_q.done |=> st_q.done)
  // encap depth never exceeds the configured max + the one that trips the fail
  `PRS_ASSERT(a_encap_bound, clk_i, rst_ni, (st_q.encap <= 8'd5))
  // decode mode: every instruction the running parser fetches is a legal decode
  `PRS_ASSERT(a_decode_legal, clk_i, rst_ni,
      (!USE_DECODE) || (!busy_o) || (!dec_illegal))

endmodule : parser_top
