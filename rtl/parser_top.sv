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
    parameter string PKT_FILE  = ""
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
  logic [ROM_W-1:0] prog_rom [0:PROG_MAX-1];
  logic [7:0]       meta_mem [0:META_MAX-1];
  initial begin
    for (int i = 0; i < PROG_MAX; i++) prog_rom[i] = '0;
    if (PROG_FILE != "") $readmemh(PROG_FILE, prog_rom);
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

  // ---- current micro-op ----
  micro_op_t op;
  assign op = mop_from_word(prog_rom[pc_cur[$clog2(PROG_MAX)-1:0]]);

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
        if (meta_we) begin
          for (int i = 0; i < 8; i++)
            if (i < int'(meta_nbytes)) begin
              logic [META_OFF_W-1:0] wa;
              wa = meta_off + i[META_OFF_W-1:0];
              meta_mem[wa[META_IDX_W-1:0]] <= meta_wdata[8*i +: 8];
            end
        end
      end
    end
  end

endmodule : parser_top
