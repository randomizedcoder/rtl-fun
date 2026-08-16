// cva6_parser_wrap.sv — the parser functional unit as it attaches to CVA6 (Phase 5).
//
// This is the Phase-4 microarchitecture (D2): custom-0 parser instructions are a
// new in-pipeline functional unit (fu_t::PARSER) in EX. Unlike parser_top.sv (a
// sim scaffold that owns a micro-PC), here CVA6's frontend fetches each parser
// instruction and this unit executes exactly ONE per issue, holding the parser
// register state across instructions and driving CVA6's fetch redirect at
// end-of-node. Port names/semantics follow docs/analysis/cva6-integration.md
// (§3–§5), grounded in the pinned CVA6 v5.3.0 signals.
//
// Type parameters mirror CVA6's own style (branch_unit.sv / ex_stage.sv use
// `parameter type bp_resolve_t = logic`, etc.) so this elaborates and lints
// standalone; the in-core patch binds them to ariane_pkg's real types.
//
// SCOPE (honest): the ready/valid + state + redirect plumbing is real and
// lint-clean. The decoded micro-op arrives on uop_i from parser_decode (32-bit
// word -> micro_op_t) — that decoder and the CVA6 decode/issue patch are the
// documented next increment (docs/phase-5-rtl.md §5.2, cva6-integration.md §8).

module cva6_parser_wrap
  import parser_pkg::*;
#(
    parameter type bp_resolve_t     = logic,       // ariane_pkg::bp_resolve_t
    parameter int unsigned VLEN     = 64,
    parameter int unsigned TRANS_ID_BITS = 3
) (
    input  logic                     clk_i,
    input  logic                     rst_ni,
    input  logic                     flush_i,          // pipeline flush (CONTROLLER)

    // ---- issue handshake (ISSUE_STAGE) ----
    input  logic                     parser_valid_i,   // a PARSER op is issued
    input  micro_op_t                uop_i,            // decoded op (from parser_decode)
    input  logic [TRANS_ID_BITS-1:0] trans_id_i,       // scoreboard id
    input  logic [VLEN-1:0]          pc_i,             // PC of this instruction
    input  logic [15:0]              parse_len_i,      // PktLen.ParseLen
    output logic                     parser_ready_o,   // unit can accept

    // ---- writeback (ISSUE_STAGE) : integer rd only for custom-3 reads ----
    output logic                     parser_valid_o,
    output logic [TRANS_ID_BITS-1:0] parser_trans_id_o,
    output logic [63:0]              parser_result_o,
    output logic                     parser_we_o,      // 0 for custom-0 (parser-reg only)

    // ---- end-of-node fetch redirect : reuse branch_unit's path (ID/ISSUE) ----
    output bp_resolve_t              resolved_branch_o,
    output logic                     resolve_branch_o,
    output logic [VLEN-1:0]          redirect_pc_o,    // node/loop target or exit target
    output logic                     parse_exit_o,     // parser exited (okay/fail)
    output logic signed [31:0]       parse_code_o,     // ParserExitCode.Error

    // ---- packet window (parser_pktbuf / packet buffer) ----
    output logic [PKT_OFF_W-1:0]     pkt_off_o,
    input  logic [63:0]              pkt_win_be_i,

    // ---- CAM (parser_cam) ----
    output logic [3:0]               cam_share_o,
    output logic [15:0]              cam_match_o,
    input  logic                     cam_hit_i,
    input  logic [31:0]              cam_target_i
);

  // persistent parser machine state (the p-registers live here, in the unit)
  pstate_t st_q, st_n;

  // single-instruction execute datapath (combinational)
  logic                 meta_we;
  logic [META_OFF_W-1:0] meta_off;
  logic [63:0]          meta_wdata;
  logic [3:0]           meta_nbytes;

  parser_execute u_exec (
      .st_i(st_q), .op_i(uop_i), .pc_i(st_q.next_pc), .parse_len_i(parse_len_i),
      .mem_off_o(pkt_off_o),  .mem_win_be_i(pkt_win_be_i),
      .cam_share_o(cam_share_o), .cam_match_o(cam_match_o),
      .cam_hit_i(cam_hit_i),  .cam_target_i(cam_target_i),
      .meta_we_o(meta_we),    .meta_off_o(meta_off),
      .meta_wdata_o(meta_wdata), .meta_nbytes_o(meta_nbytes),
      .st_o(st_n)
  );

  // Single-cycle FU for the slice (Phase-4 D3: variable latency; here 1 cycle).
  // Ready whenever not exited; a multi-cycle CAM/extract would gate this instead.
  assign parser_ready_o = rst_ni & ~st_q.done;

  // metadata writeback path (to the metadata frame / common-vs-frame — Phase-4
  // §4.4). Exposed for the in-core patch; not consumed standalone.
  wire _unused_meta = meta_we & (|meta_off) & (|meta_wdata) & (|meta_nbytes);

  logic accept;
  assign accept = parser_valid_i & parser_ready_o & ~flush_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q              <= '0;
      st_q.databound    <= 32'hFFFF_FFFF;
      st_q.loop         <= P_OKAY_RET;
      st_q.next         <= P_STOP_OKAY;
      parser_valid_o    <= 1'b0;
      parser_trans_id_o <= '0;
      parser_result_o   <= '0;
      parser_we_o       <= 1'b0;
      resolve_branch_o  <= 1'b0;
      parse_exit_o      <= 1'b0;
      parse_code_o      <= '0;
      redirect_pc_o     <= '0;
    end else begin
      parser_valid_o   <= 1'b0;
      resolve_branch_o <= 1'b0;
      parse_exit_o     <= 1'b0;
      if (accept) begin
        st_q              <= st_n;
        parser_valid_o    <= 1'b1;               // retire this micro-op
        parser_trans_id_o <= trans_id_i;
        parser_result_o   <= st_n.accum;         // custom-3 reads select rd from accum/p-reg
        parser_we_o       <= 1'b0;               // custom-0: no integer rd write
        // end-of-node: redirect fetch, or signal parse exit
        if (st_n.done) begin
          parse_exit_o <= 1'b1;
          parse_code_o <= st_n.code;
        end else if (st_n.next_pc != (st_q.next_pc + 1'b1)) begin
          resolve_branch_o <= 1'b1;              // a node/loop redirect happened
          redirect_pc_o    <= {{(VLEN-PC_W){1'b0}}, st_n.next_pc};
        end
      end
    end
  end

  // resolved_branch_o payload is bound to ariane_pkg::bp_resolve_t in the in-core
  // patch (target_address/is_taken/is_mispredict/cf_type); left at default here.
  assign resolved_branch_o = '0;

  // ---- handshake assertions (compiled out unless +define+PARSER_ASSERT/FORMAL) ----
`include "parser_asserts.svh"
  // once the parser has exited, it stops accepting work
  `PRS_ASSERT(a_ready_low_when_done, clk_i, rst_ni, st_q.done |-> !parser_ready_o)
  // a writeback only follows an accepted issue the previous cycle
  `PRS_ASSERT(a_valid_after_accept, clk_i, rst_ni, parser_valid_o |-> $past(accept))
  // custom-0 parser ops never write the integer register file
  `PRS_ASSERT(a_no_int_writeback, clk_i, rst_ni, !parser_we_o)

endmodule : cva6_parser_wrap
