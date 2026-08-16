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
//
// METADATA SINK (I2, docs/analysis/cva6-verification-design.md §1; closes G1/G8):
// the parser's metadata frame (flow_keys) is an ARCHITECTURAL side effect, so it is
// commit-gated exactly like the register state — again mirroring the LSU store
// buffer (which holds store data speculatively and writes memory only on commit).
// The per-op metadata write {we,off,wdata,nbytes} is captured into the pending FIFO
// on accept and byte-scattered into meta_mem only when that op commits; a flush
// discards the queue, so a squashed op's metadata write never lands. meta_mem is a
// 64×8 frame (mirrors parser_top.sv), read back combinationally — hierarchically by
// the wrap testbench / harness backdoor (I2 sim-only feed), no external port yet.
//
// CUSTOM-3 READBACK (I3, docs/analysis/cva6-verification-design.md §1; closes G4):
// a custom-3 `prs.mv.x.p rd, p<cpreg>` (CPPRSRD) reads a parser register into an
// integer rd. It is a register MOVE serviced by this FU — not a parse micro-op — so
// it never advances parser state, never redirects/exits, and never enters the pending
// queue; it reads the working state st_q and is squashed with the op on flush. CVA6
// writes the integer RF via the statically-decoded rd (custom-3 rd=itype.rd) +
// wt_valid[PARSER_WB], so parser_we_o is vestigial here (kept as a documented strobe).

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
  //
  // Each entry also carries the op's METADATA write (I2), so the flow_keys frame is
  // committed with the same in-order gate as the register state.
  localparam int unsigned PEND_DEPTH = 4;
  localparam int unsigned PEND_AW    = $clog2(PEND_DEPTH);
  typedef struct packed {
    logic [TRANS_ID_BITS-1:0] trans_id;
    pstate_t                  st;
    logic                     meta_we;      // this op wrote the metadata frame
    logic [META_OFF_W-1:0]    meta_off;     // byte offset into the frame
    logic [63:0]              meta_wdata;   // up to 8 bytes, little-endian
    logic [3:0]               meta_nbytes;  // 1..8
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

  // ---- custom-3 register readback (CPPRSRD `prs.mv.x.p rd,p<cpreg>`) (I3) --------
  // A custom-3 read moves a parser register into an integer rd. It is NOT a parse
  // micro-op: it never advances parser state, never redirects/exits, and never enters
  // the pending queue. It reads the current working state st_q — which already
  // reflects every older accepted parse op, so the value is program-order correct; if
  // the op is later squashed, its rd writeback is squashed with it (scoreboard/flush).
  // Cpreg selects a pstate_t field per the patent p0..p31 map (FIG 42). Registers
  // outside this execution subset read 0. p1/p2 return the flattened {len,off} of the
  // current/data header (an implementation-defined packing of the exec subset).
  function automatic logic [63:0] read_preg(input pstate_t s, input logic [4:0] sel);
    unique case (sel)
      5'd1:    read_preg = {{(64-2*PKT_OFF_W){1'b0}}, s.cur_len, s.cur_off}; // p1  CurHdr*
      5'd2:    read_preg = {{(64-2*PKT_OFF_W){1'b0}}, s.dat_len, s.dat_off}; // p2  DataHdr*
      5'd11:   read_preg = {{32{s.next[31]}}, s.next};             // p11 Next
      5'd13:   read_preg = {s.loop, s.databound};                  // p13 DataBndLoop {Loop,DataBound}
      5'd14:   read_preg = {{32{s.code[31]}}, s.code};             // p14 ParserExitCode
      5'd15:   read_preg = s.accum;                                 // p15 Accum
      5'd16:   read_preg = s.flags;                                 // p16 Flags
      default: read_preg = 64'h0;        // p-reg outside the execution subset: reads 0
    endcase
  endfunction

  wire rd_preg_op = parser_valid_i & uop_i.rd_preg;   // a custom-3 read is offered

  // Single-cycle FU for the slice (Phase-4 D3: variable latency; here 1 cycle). A
  // parse op is ready when not exited AND the pending queue has room; a custom-3 read
  // is always ready (it neither advances state nor uses the queue), so parser state
  // stays readable even after a parse has exited (e.g. read ParserExitCode).
  assign parser_ready_o = rst_ni & (rd_preg_op | (~st_q.done & ~pend_full));

  // ---- metadata frame (flow_keys) : the commit-gated architectural sink (I2) -----
  // 64×8 byte frame, mirroring parser_top.sv's meta_mem. The per-op metadata write
  // produced by parser_execute (meta_we/off/wdata/nbytes) is buffered in the pending
  // queue and byte-scattered here only when the op COMMITS (see always_ff below), so
  // a squashed speculative op never dirties the frame. Read back combinationally;
  // the wrap TB / harness backdoor reads meta_mem hierarchically (I2 sim-only feed).
  localparam int unsigned META_IDX_W = $clog2(META_MAX);
  logic [7:0] meta_mem [0:META_MAX-1];

  logic accept;
  assign accept = parser_valid_i & parser_ready_o & ~flush_i;
  wire accept_state = accept & ~uop_i.rd_preg;   // a state-advancing parse op
  wire accept_rd    = accept &  uop_i.rd_preg;   // a custom-3 register read

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q              <= reset_state();
      st_arch_q         <= reset_state();
      pend_cnt_q        <= '0;
      pend_head_q       <= '0;
      pend_tail_q       <= '0;
      for (int unsigned i = 0; i < PEND_DEPTH; i++) pend_q[i] <= '0;
      for (int unsigned i = 0; i < META_MAX; i++) meta_mem[i] <= 8'h0;
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
      parser_we_o      <= 1'b0;
      resolve_branch_o <= 1'b0;
      parse_exit_o     <= 1'b0;

      // ---- EXECUTE: retire to the scoreboard + steer fetch (speculative) ----------
      if (accept) begin
        parser_valid_o    <= 1'b1;                // retire this micro-op
        parser_trans_id_o <= trans_id_i;
        parser_we_o       <= uop_i.rd_preg;       // custom-3 read writes rd; custom-0 does not
        if (uop_i.rd_preg) begin
          // custom-3 register read: drive rd from the selected p-register.
          // No parser-state change, no redirect, no exit — it is a register move.
          parser_result_o <= read_preg(st_q, uop_i.cpreg);
        end else begin
          st_q              <= st_n;              // speculative fast path (forwards)
          parser_result_o   <= st_n.accum;
          // end-of-node: redirect fetch, or signal parse exit
          if (st_n.done) begin
            parse_exit_o <= 1'b1;
            parse_code_o <= st_n.code;
          end else if (st_n.next_pc != (st_q.next_pc + 1'b1)) begin
            resolve_branch_o <= 1'b1;            // a node/loop redirect happened
            redirect_pc_o    <= {{(VLEN-PC_W){1'b0}}, st_n.next_pc};
          end
        end
      end

      // ---- pending-queue bookkeeping: enqueue on accept, apply head on commit -----
      if (pend_commit) begin
        st_arch_q   <= pend_q[pend_head_q].st;    // architectural state advances
        pend_head_q <= pend_head_q + 1'b1;
        // COMMIT the head op's metadata write into the frame (byte-scatter). The
        // write was bounds-checked upstream (parser_execute a_meta_inbounds), so
        // meta_off + i never wraps META_MAX — same scatter as parser_top.sv.
        if (pend_q[pend_head_q].meta_we) begin
          for (int i = 0; i < 8; i++)
            if (i < int'(pend_q[pend_head_q].meta_nbytes))
              meta_mem[META_IDX_W'(pend_q[pend_head_q].meta_off + i[META_OFF_W-1:0])]
                  <= pend_q[pend_head_q].meta_wdata[8*i +: 8];
        end
      end
      // Only state-advancing parse ops enter the pending queue; a custom-3 read
      // changes no parser state, so it is never enqueued (its rd writeback is tracked
      // by the scoreboard/commit like any other instruction).
      if (accept_state) begin
        pend_q[pend_tail_q].trans_id    <= trans_id_i;
        pend_q[pend_tail_q].st          <= st_n;
        pend_q[pend_tail_q].meta_we     <= meta_we;      // buffer the metadata write;
        pend_q[pend_tail_q].meta_off    <= meta_off;     // it lands only on commit
        pend_q[pend_tail_q].meta_wdata  <= meta_wdata;
        pend_q[pend_tail_q].meta_nbytes <= meta_nbytes;
        pend_tail_q                     <= pend_tail_q + 1'b1;
      end
      pend_cnt_q <= pend_cnt_q + (PEND_AW+1)'(accept_state) - (PEND_AW+1)'(pend_commit);

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
  // once the parser has exited, it stops accepting PARSE work — but a custom-3 read
  // is still serviced (e.g. to read ParserExitCode after the exit)
  `PRS_ASSERT(a_ready_low_when_done, clk_i, rst_ni, (st_q.done & ~rd_preg_op) |-> !parser_ready_o)
  // a writeback only follows an accepted issue the previous cycle
  `PRS_ASSERT(a_valid_after_accept, clk_i, rst_ni, parser_valid_o |-> $past(accept))
  // integer rd is written ONLY by a custom-3 read (custom-0 parse ops never do)
  `PRS_ASSERT(a_we_iff_rdpreg, clk_i, rst_ni, parser_we_o |-> $past(accept & uop_i.rd_preg))
  // SPECULATION SAFETY (G2): the architectural state only ever advances on a commit
  `PRS_ASSERT(a_arch_committed, clk_i, rst_ni, !$stable(st_arch_q) |-> $past(pend_commit))
  // SPECULATION SAFETY (G2): after a flush the speculative state == committed state
  `PRS_ASSERT(a_flush_rollback, clk_i, rst_ni, $past(flush_i) |-> (st_q == st_arch_q))

endmodule : cva6_parser_wrap
