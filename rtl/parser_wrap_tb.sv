// parser_wrap_tb.sv — directed testbench for cva6_parser_wrap's commit-visible
// parser state (I1, docs/analysis/cva6-verification-design.md §1; closes gap G2).
//
// The gap: parser register state used to commit at EXECUTE, so a squashed
// speculative op corrupted state permanently. The fix keeps a speculative working
// copy (st_q) but a committed architectural shadow (st_arch_q) that advances only
// on commit; a flush rolls st_q back to st_arch_q. This TB proves the four
// structural invariants of that mechanism, independent of parser_execute's value
// semantics (it only needs each op to change st_q, which advancing next_pc does):
//
//   1. ROLLBACK       : after a flush, st_q == st_arch_q and the pending queue is empty.
//   2. NO-COMMIT-STABLE: while nothing commits, st_arch_q never changes.
//   3. COMMIT-ADVANCE : on commit of the head op, st_arch_q becomes that op's post-state.
//   4. BACKPRESSURE   : with PEND_DEPTH ops outstanding, parser_ready_o drops.
//
// The concurrent SVA in cva6_parser_wrap (a_arch_committed / a_flush_rollback) run
// alongside as a second oracle (+define+PARSER_ASSERT). Run: nix run .#parser-wrap-test.

module parser_wrap_tb
  import parser_pkg::*;
;
  localparam int unsigned TIDW = 3;

  logic clk;
  logic rst_ni;
  logic flush;

  // issue side
  logic            valid;
  micro_op_t       uop;
  logic [TIDW-1:0] tid;
  // commit side
  logic            commit;
  logic [TIDW-1:0] commit_tid;
  // outputs
  logic            ready;
  logic            wb_valid;
  logic [TIDW-1:0] wb_tid;
  logic [63:0]     result;
  logic            we;
  logic            resolve_br;
  logic            resolved_br_unused;   // bp_resolve_t defaults to logic here
  logic [63:0]     redir_pc;
  logic            parse_exit;
  logic signed [31:0] parse_code;
  logic [PKT_OFF_W-1:0] pkt_off;
  logic [3:0]      cam_share;
  logic [15:0]     cam_match;

  cva6_parser_wrap #(
      .VLEN         (64),
      .TRANS_ID_BITS(TIDW)
  ) dut (
      .clk_i            (clk),
      .rst_ni           (rst_ni),
      .flush_i          (flush),
      .parser_valid_i   (valid),
      .uop_i            (uop),
      .trans_id_i       (tid),
      .pc_i             (64'h8000_0000),
      .parse_len_i      (16'(PKT_MAX)),
      .parser_ready_o   (ready),
      .commit_i         (commit),
      .commit_trans_id_i(commit_tid),
      .parser_valid_o   (wb_valid),
      .parser_trans_id_o(wb_tid),
      .parser_result_o  (result),
      .parser_we_o      (we),
      .resolved_branch_o(resolved_br_unused),
      .resolve_branch_o (resolve_br),
      .redirect_pc_o    (redir_pc),
      .parse_exit_o     (parse_exit),
      .parse_code_o     (parse_code),
      .pkt_off_o        (pkt_off),
      .pkt_win_be_i     (64'hA5A5_A5A5_A5A5_A5A5),  // nonzero: loads change accum
      .cam_share_o      (cam_share),
      .cam_match_o      (cam_match),
      .cam_hit_i        (1'b0),
      .cam_target_i     (32'd0)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // a state-advancing byte-load micro-op (advances next_pc; loads accum)
  function automatic micro_op_t load_op();
    micro_op_t m;
    m        = '0;
    m.op     = OP_LOAD;
    m.sz     = 2'd1;   // byte
    m.offset = 9'd0;
    m.d      = 1'b1;   // write into a p-register
    return m;
  endfunction

  int errors = 0;
  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $error("[parser_wrap_tb] CHECK FAILED: %s", msg);
    end
  endtask

  // issue one op on the next posedge (assumes ready); deassert after.
  task automatic issue(input logic [TIDW-1:0] t);
    uop   = load_op();
    tid   = t;
    valid = 1'b1;
    @(posedge clk);
    #1;
    valid = 1'b0;
  endtask

  pstate_t sA;

  initial begin
    // ---- reset ----
    rst_ni = 1'b0; flush = 1'b0; valid = 1'b0; commit = 1'b0;
    uop = '0; tid = '0; commit_tid = '0;
    repeat (3) @(posedge clk);
    #1 rst_ni = 1'b1;
    @(posedge clk); #1;

    // ================================================================
    // Scenario 1 — speculative advance then FLUSH must roll back (G2).
    // ================================================================
    check(ready, "ready should be high after reset");
    // two speculative accepts, no commit
    issue(3'd1);
    check(dut.pend_cnt_q == 1, "pend_cnt should be 1 after first accept");
    issue(3'd2);
    check(dut.pend_cnt_q == 2, "pend_cnt should be 2 after second accept");
    // st_arch_q must NOT have moved (no commit yet) — invariant 2
    check(dut.st_arch_q.next_pc == '0, "st_arch_q advanced without any commit");
    // speculative state has advanced past architectural
    check(dut.st_q !== dut.st_arch_q, "st_q should be speculatively ahead of st_arch_q");

    // FLUSH
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    // invariant 1: rolled back, queue empty
    check(dut.st_q === dut.st_arch_q, "ROLLBACK: st_q != st_arch_q after flush");
    check(dut.pend_cnt_q == 0,        "ROLLBACK: pending queue not cleared on flush");
    @(posedge clk); #1;

    // ================================================================
    // Scenario 2 — COMMIT advances the architectural shadow (invariant 3).
    // ================================================================
    check(ready, "ready should recover after flush rollback");
    issue(3'd0);
    sA = dut.st_q;                       // post-state of the accepted op
    check(dut.pend_cnt_q == 1, "pend_cnt should be 1");
    // commit that trans_id
    commit = 1'b1; commit_tid = 3'd0;
    @(posedge clk); #1;
    commit = 1'b0;
    check(dut.st_arch_q === sA, "COMMIT-ADVANCE: st_arch_q != committed op post-state");
    check(dut.pend_cnt_q == 0, "pending queue not popped on commit");

    // a non-matching commit must NOT advance arch (invariant 2)
    sA = dut.st_arch_q;
    commit = 1'b1; commit_tid = 3'd5;    // no such pending op
    @(posedge clk); #1;
    commit = 1'b0;
    check(dut.st_arch_q === sA, "arch advanced on a non-matching commit trans_id");
    @(posedge clk); #1;

    // ================================================================
    // Scenario 3 — BACKPRESSURE: PEND_DEPTH outstanding => ready drops.
    // ================================================================
    // fill the pending queue (PEND_DEPTH accepts, no commit)
    for (int unsigned i = 0; i < 4; i++) begin
      check(ready, "ready should stay high until the queue is full");
      issue(3'(i));
    end
    check(dut.pend_cnt_q == 4, "pending queue should be full (4)");
    check(!ready, "BACKPRESSURE: ready should drop when the pending queue is full");

    // drain by committing in order; ready must recover
    commit = 1'b1; commit_tid = 3'd0;
    @(posedge clk); #1;
    commit = 1'b0;
    check(ready, "ready should recover after a commit frees a slot");
    @(posedge clk); #1;

    // ---- verdict ----
    if (errors == 0)
      $display("parser_wrap_tb: PASS (I1 commit-visible state: rollback/commit/backpressure)");
    else
      $fatal(1, "parser_wrap_tb: FAIL (%0d checks failed)", errors);
    $finish;
  end

  // safety net: never hang
  initial begin
    repeat (2000) @(posedge clk);
    $fatal(1, "parser_wrap_tb: TIMEOUT");
  end
endmodule : parser_wrap_tb
