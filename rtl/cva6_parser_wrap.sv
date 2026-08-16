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
// SPECULATION SAFETY (I1, docs/analysis/cva6-verification-design.md §1): the
// persistent parser register state is made COMMIT-visible, not execute-visible.
// The speculative working copy (st_q) advances at EXECUTE and forwards to the next
// in-flight parser op, but the ARCHITECTURAL copy (st_arch_q) advances only when an
// op commits. On flush_i — which in CVA6 is a *commit-boundary* flush (exception /
// eret / fence / CSR side-effect; a branch mispredict only flushes un-issued
// instructions and IF, never the EX stage — see controller.sv) — every uncommitted
// op is squashed and will re-execute, so st_q rolls back to st_arch_q. This mirrors
// the LSU store buffer's speculative/commit-queue split (store_buffer.sv).

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

    // ---- commit notification (COMMIT_STAGE) : make parser state commit-visible ----
    input  logic                     commit_i,          // an op retired on commit port 0
    input  logic [TRANS_ID_BITS-1:0] commit_trans_id_i, // its trans_id (commit port 0)

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

  // ---- persistent parser machine state (the p-registers live here, in the unit) --
  // st_q      : speculative working state — advances at EXECUTE, forwards to the next
  //             in-flight parser op; may reflect ops not yet committed.
  // st_arch_q : committed architectural shadow — advances only when an op COMMITS.
  pstate_t st_q, st_n;
  pstate_t st_arch_q;

  // the reset / initial architectural state (databound=all-ones, loop/next presets)
  function automatic pstate_t reset_state();
    pstate_t s;
    s           = '0;
    s.databound = 32'hFFFF_FFFF;
    s.loop      = P_OKAY_RET;
    s.next      = P_STOP_OKAY;
    return s;
  endfunction

  // ---- pending queue: {trans_id, resulting state} per accepted, uncommitted op ---
  // Depth = worst-case parser ops outstanding between issue and commit. DECISION:
  // start at 4 (must be a power of two for the free ring wrap); stall issue when
  // full. Single-issue + in-order commit ⇒ a plain ring buffer, head = oldest
  // uncommitted op. When that op commits (commit_i & trans_id match) it advances
  // st_arch_q. On flush the whole queue is discarded (all its ops re-execute).
  localparam int unsigned PEND_DEPTH = 4;
  localparam int unsigned PEND_AW    = $clog2(PEND_DEPTH);
  typedef struct packed {
    logic [TRANS_ID_BITS-1:0] trans_id;
    pstate_t                  st;
  } pend_t;
  pend_t              pend_q [PEND_DEPTH];
  logic [PEND_AW:0]   pend_cnt_q;                 // 0..PEND_DEPTH
  logic [PEND_AW-1:0] pend_head_q, pend_tail_q;   // wrap mod PEND_DEPTH
  logic               pend_full, pend_empty, pend_commit;

  assign pend_full   = (pend_cnt_q == PEND_DEPTH[PEND_AW:0]);
  assign pend_empty  = (pend_cnt_q == '0);
  // the op committing on port 0 is the head of our queue (in-order commit)
  assign pend_commit = commit_i & ~pend_empty &
                       (commit_trans_id_i == pend_q[pend_head_q].trans_id);

  // ---- single-instruction execute datapath (combinational) -----------------------
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
  // Ready whenever not exited AND the pending queue can take another op.
  assign parser_ready_o = rst_ni & ~st_q.done & ~pend_full;

  // metadata writeback path (to the metadata frame / common-vs-frame — Phase-4
  // §4.4). Exposed for the in-core patch; not consumed standalone (I2 wires it).
  wire _unused_meta = meta_we & (|meta_off) & (|meta_wdata) & (|meta_nbytes);

  logic accept;
  assign accept = parser_valid_i & parser_ready_o & ~flush_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q              <= reset_state();
      st_arch_q         <= reset_state();
      pend_cnt_q        <= '0;
      pend_head_q       <= '0;
      pend_tail_q       <= '0;
      for (int unsigned i = 0; i < PEND_DEPTH; i++) pend_q[i] <= '0;
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

      // ---- EXECUTE: retire to the scoreboard + steer fetch (speculative) ----------
      if (accept) begin
        st_q              <= st_n;                // speculative fast path (forwards)
        parser_valid_o    <= 1'b1;                // retire this micro-op
        parser_trans_id_o <= trans_id_i;
        parser_result_o   <= st_n.accum;          // custom-3 reads select rd from accum/p-reg
        parser_we_o       <= 1'b0;                // custom-0: no integer rd write
        // end-of-node: redirect fetch, or signal parse exit
        if (st_n.done) begin
          parse_exit_o <= 1'b1;
          parse_code_o <= st_n.code;
        end else if (st_n.next_pc != (st_q.next_pc + 1'b1)) begin
          resolve_branch_o <= 1'b1;              // a node/loop redirect happened
          redirect_pc_o    <= {{(VLEN-PC_W){1'b0}}, st_n.next_pc};
        end
      end

      // ---- pending-queue bookkeeping: enqueue on accept, apply head on commit -----
      if (pend_commit) begin
        st_arch_q   <= pend_q[pend_head_q].st;    // architectural state advances
        pend_head_q <= pend_head_q + 1'b1;
      end
      if (accept) begin
        pend_q[pend_tail_q].trans_id <= trans_id_i;
        pend_q[pend_tail_q].st       <= st_n;
        pend_tail_q                  <= pend_tail_q + 1'b1;
      end
      pend_cnt_q <= pend_cnt_q + (PEND_AW+1)'(accept) - (PEND_AW+1)'(pend_commit);

      // ---- FLUSH (commit-boundary): roll speculative state back to committed -------
      // Apply an in-flight head commit first (older than the flush point), then roll
      // st_q back. accept is impossible here (accept has ~flush_i). All queued ops
      // are younger than the flush and will re-execute, so the queue is discarded.
      if (flush_i) begin
        st_q        <= pend_commit ? pend_q[pend_head_q].st : st_arch_q;
        st_arch_q   <= pend_commit ? pend_q[pend_head_q].st : st_arch_q;
        pend_cnt_q  <= '0;
        pend_head_q <= '0;
        pend_tail_q <= '0;
      end
    end
  end

  // resolved_branch_o payload is bound to ariane_pkg::bp_resolve_t in the in-core
  // patch (target_address/is_taken/is_mispredict/cf_type); left at default here.
  assign resolved_branch_o = '0;

  // ---- handshake + speculation-safety assertions (compiled out unless
  //      +define+PARSER_ASSERT / +define+FORMAL) --------------------------------
`include "parser_asserts.svh"
  // once the parser has exited, it stops accepting work
  `PRS_ASSERT(a_ready_low_when_done, clk_i, rst_ni, st_q.done |-> !parser_ready_o)
  // a writeback only follows an accepted issue the previous cycle
  `PRS_ASSERT(a_valid_after_accept, clk_i, rst_ni, parser_valid_o |-> $past(accept))
  // custom-0 parser ops never write the integer register file
  `PRS_ASSERT(a_no_int_writeback, clk_i, rst_ni, !parser_we_o)
  // SPECULATION SAFETY (G2): the architectural state only ever advances on a commit
  `PRS_ASSERT(a_arch_committed, clk_i, rst_ni, !$stable(st_arch_q) |-> $past(pend_commit))
  // SPECULATION SAFETY (G2): after a flush the speculative state == committed state
  `PRS_ASSERT(a_flush_rollback, clk_i, rst_ni, $past(flush_i) |-> (st_q == st_arch_q))

endmodule : cva6_parser_wrap
