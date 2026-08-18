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
// Scenario 4 additionally proves the I2 commit-gated METADATA sink (gaps G1/G8): a
// store's metadata write is buffered on accept and byte-scattered into meta_mem ONLY
// when the op commits, and a flush discards an uncommitted store's write — the frame
// is an architectural side effect gated exactly like the register state.
//
// Scenario 5 proves the I3 custom-3 register READBACK (gap G4): a `prs.mv.x.p` op
// retires with we=1 and rd = the selected parser register, and does NOT advance
// parser state or enter the pending queue (it is a register move, not a parse op).
//
// Scenario 6 proves the I4 end-of-node REDIRECT target translation (gap G3): a
// next-node jump asserts resolve and drives redirect_pc_o as a BYTE PC
// (pc_i + node_delta*4), not the raw parser node index.
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
  logic [63:0]     rs1;               // integer rs1 operand (custom-3)
  // CAM lookup + program wiring (I4b): a real parser_cam closes the program->lookup loop
  logic [3:0]      cam_share;
  logic [15:0]     cam_match;
  logic            cam_hit;
  logic [31:0]     cam_target;
  logic            cam_prog_en;
  logic [CAM_IDX_W-1:0] cam_prog_index;
  logic            cam_prog_valid;
  logic [3:0]      cam_prog_share;
  logic [15:0]     cam_prog_match;
  logic [31:0]     cam_prog_target;
  logic [META_OFF_W-1:0] meta_rd_addr;   // MMIO flow_keys readback (I5)
  logic [63:0]     meta_rd_data;
  logic [63:0]     parse_status;         // latched exit status (I5)

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
      .rs1_i            (rs1),
      .parse_len_i      (16'(PKT_MAX)),
      .parse_exit_pc_i  (64'h8000_1000),   // exit landing PC (I5)
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
      .cam_hit_i        (cam_hit),
      .cam_target_i     (cam_target),
      .cam_prog_en_o    (cam_prog_en),
      .cam_prog_index_o (cam_prog_index),
      .cam_prog_valid_o (cam_prog_valid),
      .cam_prog_share_o (cam_prog_share),
      .cam_prog_match_o (cam_prog_match),
      .cam_prog_target_o(cam_prog_target),
      .meta_rd_addr_i   (meta_rd_addr),   // MMIO flow_keys readback (I5)
      .meta_rd_data_o   (meta_rd_data),
      .parse_status_o   (parse_status)
  );

  // real CAM, so a CPPRSWRCAM program is observable by a later CPPRSRDCAM lookup (I4b)
  parser_cam u_cam (
      .clk_i       (clk),
      .prog_en_i   (cam_prog_en),
      .prog_index_i(cam_prog_index),
      .prog_valid_i(cam_prog_valid),
      .prog_share_i(cam_prog_share),
      .prog_match_i(cam_prog_match),
      .prog_target_i(cam_prog_target),
      .share_i     (cam_share),
      .match_i     (cam_match),
      .hit_o       (cam_hit),
      .target_o    (cam_target)
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

  // a store-immediate micro-op: writes `val`'s low byte to metadata offset `off`.
  // sz=1 => 1 byte (parser_execute: nbytes = 1<<(sz-1)); s=0 => no end-of-node.
  function automatic micro_op_t storeimm_op(input logic [8:0]  off,
                                            input logic [15:0] val);
    micro_op_t m;
    m        = '0;
    m.op     = OP_STOREIMM;
    m.sz     = 2'd1;   // 1 byte
    m.offset = off;
    m.value  = val;
    m.s      = 1'b0;   // no trailing end-of-node (stays live)
    return m;
  endfunction

  // a custom-3 register-read micro-op (CPPRSRD): read parser register `cp` into rd.
  function automatic micro_op_t rdpreg_op(input logic [4:0] cp);
    micro_op_t m;
    m         = '0;
    m.rd_preg = 1'b1;
    m.cpreg   = cp;
    return m;
  endfunction

  // a next-node micro-op with the end-of-node (s) bit: jumps to node `target`.
  function automatic micro_op_t nextnode_op(input logic signed [15:0] target);
    micro_op_t m;
    m         = '0;
    m.op      = OP_NEXTNODE;
    m.payload = target;   // absolute node index (address form)
    m.s       = 1'b1;     // trailing end-of-node => control transfer
    return m;
  endfunction

  // custom-3 write-p-register (CPPRSWR): p[cp] = rs1.
  function automatic micro_op_t wrpreg_op(input logic [4:0] cp);
    micro_op_t m; m = '0; m.wr_preg = 1'b1; m.cpreg = cp; return m;
  endfunction
  // custom-3 immediate-load (CPPRSWRIMM): p[cp] = {53'b0, imm}, no integer operand.
  function automatic micro_op_t wrpregimm_op(input logic [4:0] cp, input logic [10:0] imm);
    micro_op_t m; m = '0; m.wr_preg_imm = 1'b1; m.cpreg = cp; m.imm = imm; return m;
  endfunction
  // custom-3 CAM program/delete (CPPRSWRCAM): CAM[rs1] from p[cp]; del=1 => remove.
  function automatic micro_op_t wrcam_op(input logic [4:0] cp, input logic del);
    micro_op_t m; m = '0; m.wr_cam = 1'b1; m.cpreg = cp; m.cam_del = del; return m;
  endfunction
  // custom-3 CAM read (CPPRSRDCAM): lookup key=rs1 -> rd.
  function automatic micro_op_t rdcam_op();
    micro_op_t m; m = '0; m.rd_cam = 1'b1; return m;
  endfunction

  // shared check primitive + tally (tb_checks / tb_fails) — same one
  // parser_smoke_tb uses; drives its own verdict from tb_fails below.
`include "tb_check.svh"

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
  pstate_t st_before;
  logic [63:0] exp_next;
  int cnt_before;

  initial begin
    // ---- reset ----
    rst_ni = 1'b0; flush = 1'b0; valid = 1'b0; commit = 1'b0;
    uop = '0; tid = '0; commit_tid = '0; rs1 = '0; meta_rd_addr = '0;
    repeat (3) @(posedge clk);
    #1 rst_ni = 1'b1;
    @(posedge clk); #1;

    // ================================================================
    // Scenario 0 — V11: reset => defined, X-free state (Table C, G13).
    // ================================================================
    // Straight out of reset, before any op is issued, the speculative and
    // architectural state and the handshake outputs must be fully defined (no X),
    // agree with each other, and present an empty pending queue.
    check(!$isunknown(ready),         "RESET: ready must be defined (no X)");
    check(!$isunknown(dut.st_q),      "RESET: speculative st_q must be X-free");
    check(!$isunknown(dut.st_arch_q), "RESET: architectural st_arch_q must be X-free");
    check(dut.pend_cnt_q == 0,        "RESET: pending queue must be empty");
    check(dut.st_q === dut.st_arch_q, "RESET: spec and arch state must agree at reset");
    // The FIRST op after reset must yield a defined result / post-state — no X leaks
    // out of an uninitialised register. A custom-3 readback is used because it neither
    // enqueues nor advances state, leaving the clean post-reset condition Scenario 1
    // expects.
    uop = rdpreg_op(5'd11); tid = 3'd0; valid = 1'b1;
    #1;
    check(!$isunknown(result),        "RESET: first-op result must be X-free");
    @(posedge clk); #1; valid = 1'b0;
    check(!$isunknown(dut.st_q),      "RESET: first-op post-state must be X-free");
    check(dut.pend_cnt_q == 0,        "RESET: readback must not perturb the queue");
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

    // ================================================================
    // Scenario 4 — METADATA commit-gating (I2, gaps G1/G8).
    // ================================================================
    // clean slate: flush drains the queue left over from scenario 3
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    @(posedge clk); #1;
    check(dut.pend_cnt_q == 0, "queue should be empty entering scenario 4");
    check(dut.meta_mem[4] == 8'h00, "meta frame should be clear before any store commits");

    // issue a store-immediate: 1 byte 0xAB at metadata offset 4
    uop = storeimm_op(9'd4, 16'h00AB); tid = 3'd1; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    check(dut.pend_cnt_q == 1, "storeimm should enqueue one pending op");
    check(dut.pend_q[dut.pend_head_q].meta_we, "pending head should carry the metadata write");
    // the write is buffered, NOT yet applied (op not committed) — invariant like I1
    check(dut.meta_mem[4] == 8'h00, "metadata must NOT land before commit (speculative)");

    // commit that trans_id => the byte lands in the frame
    commit = 1'b1; commit_tid = 3'd1;
    @(posedge clk); #1; commit = 1'b0;
    check(dut.meta_mem[4] == 8'hAB, "COMMIT: metadata byte should land in the frame");
    check(dut.pend_cnt_q == 0,      "queue should pop after the store commits");
    // I5: the MMIO flow_keys read port sees the same committed byte (combinational).
    // 64-bit beat from offset 0: byte 4 sits in lane 4 (bits [39:32]).
    meta_rd_addr = 9'd0; #1;
    check(meta_rd_data[39:32] == 8'hAB, "MMIO meta read port should return the committed byte");
    @(posedge clk); #1;

    // a second store, then FLUSH before it commits => it must be discarded
    uop = storeimm_op(9'd5, 16'h00CD); tid = 3'd2; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    check(dut.meta_mem[5] == 8'h00, "second store must not land before commit");
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    check(dut.meta_mem[5] == 8'h00, "FLUSH: a squashed store's metadata must be discarded");
    check(dut.pend_cnt_q == 0,      "flush should clear the pending queue");
    check(dut.meta_mem[4] == 8'hAB, "committed metadata must survive the flush");
    @(posedge clk); #1;

    // ================================================================
    // Scenario 5 — custom-3 register READBACK (I3, gap G4).
    // ================================================================
    // Read p11 (Next) == the reset value P_STOP_OKAY (sign-extended). A read must
    // retire with we=1 and the selected register value, and must NOT advance parser
    // state or enter the pending queue.
    exp_next   = {{32{P_STOP_OKAY[31]}}, P_STOP_OKAY};
    st_before  = dut.st_q;
    cnt_before = int'(dut.pend_cnt_q);
    uop = rdpreg_op(5'd11); tid = 3'd4; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    check(wb_valid,                     "readback should retire (parser_valid_o)");
    check(we,                           "readback should assert we (writes integer rd)");
    check(result === exp_next,          "readback of p11 (Next) != P_STOP_OKAY");
    check(wb_tid == 3'd4,               "readback trans_id mismatch");
    check(dut.st_q === st_before,       "readback must NOT advance parser state");
    check(int'(dut.pend_cnt_q) == cnt_before, "readback must NOT enter the pending queue");
    // we is a per-op strobe: it drops the cycle after (no accept)
    @(posedge clk); #1;
    check(!we, "we should deassert after the readback retires");

    // ================================================================
    // Scenario 6 — end-of-node REDIRECT target translation (I4, gap G3).
    // ================================================================
    // From whatever the current node index is, a next-node jump forward by +10 nodes
    // must assert resolve and produce a BYTE PC = pc_i + 10*4 (pc_i is the dut's fixed
    // 0x8000_0000), NOT the raw node index. Capturing the base from (pc_i, cur node)
    // keeps the target correct regardless of the committed state left by prior scenarios.
    cnt_before = int'(dut.st_q.next_pc);          // current node index
    uop = nextnode_op(16'(cnt_before + 10)); tid = 3'd6; valid = 1'b1;
    #1;   // resolve is now COMBINATIONAL (same-cycle as the op in EX) — sample while
          // valid is still high, before the clock edge advances/releases it.
    check(resolve_br,   "REDIRECT: resolve should assert on a node jump");
    check(!parse_exit,  "REDIRECT: a jump is not a parse exit");
    check(redir_pc == (64'h8000_0000 + 64'd10 * 4),
          "REDIRECT: target should be pc_i + node_delta*4 (byte PC, not node index)");
    @(posedge clk); #1; valid = 1'b0;
    @(posedge clk); #1;

    // ================================================================
    // Scenario 7 — CAM PROGRAM + READBACK (I4b, gap G3 CAM path).
    // ================================================================
    // Clear scenario 6's speculative residue, then program a CAM entry from the
    // integer side (CPPRSWR stages {key,target} into Accum; CPPRSWRCAM writes it),
    // and read it back with a CPPRSRDCAM key lookup — a full program->lookup loop.
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    @(posedge clk); #1;

    // (a) CPPRSWR p15 <- {key,target}: key32=(share<<16)|match=(1<<16)|0x0800; target=0xCD.
    rs1 = 64'h0001_0800_0000_00CD;
    uop = wrpreg_op(5'd15); tid = 3'd0; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    commit = 1'b1; commit_tid = 3'd0; @(posedge clk); #1; commit = 1'b0;
    check(dut.st_q.accum == 64'h0001_0800_0000_00CD, "CPPRSWR: Accum should hold {key,target}");

    // (b) CPPRSWRCAM index=rs1(0), cpreg=p15: BUFFER the CAM program (commit-gated, N3).
    // The strobe must NOT fire at execute; it enqueues and marks a CAM write pending.
    rs1 = 64'd0;
    uop = wrcam_op(5'd15, 1'b0); tid = 3'd1; valid = 1'b1;
    #1;
    check(!cam_prog_en, "CPPRSWRCAM: must NOT program the CAM at execute (commit-gated)");
    @(posedge clk); #1; valid = 1'b0;        // enqueued
    check(dut.pend_cnt_q     == 1, "CPPRSWRCAM: enqueued, awaiting commit");
    check(dut.cam_pend_cnt_q == 1, "CPPRSWRCAM: a CAM write is pending");

    // a dependent CAM lookup must INTERLOCK while the program is uncommitted.
    rs1 = 64'h0000_0000_0001_0800;
    uop = rdcam_op(); valid = 1'b1;
    #1;
    check(!ready, "CPPRSRDCAM: must interlock behind an uncommitted CAM write");
    valid = 1'b0; uop = '0; #1;

    // COMMIT the CAM write: the buffered program applies to the CAM on this commit and
    // releases the interlock.
    commit = 1'b1; commit_tid = 3'd1;
    #1;
    check(cam_prog_en,                       "CPPRSWRCAM: program strobe asserts on COMMIT");
    check(cam_prog_index == '0,              "CPPRSWRCAM: index should be rs1 (0)");
    check(cam_prog_valid,                    "CPPRSWRCAM: write, not delete");
    check(cam_prog_share  == 4'd1,           "CPPRSWRCAM: share = key[19:16]");
    check(cam_prog_match  == 16'h0800,       "CPPRSWRCAM: match = key[15:0]");
    check(cam_prog_target == 32'h0000_00CD,  "CPPRSWRCAM: target = p[cpreg][31:0]");
    @(posedge clk); #1; commit = 1'b0;       // CAM entry latches on this edge
    check(dut.cam_pend_cnt_q == 0, "CPPRSWRCAM: no CAM write pending after commit");
    @(posedge clk); #1;

    // (c) CPPRSRDCAM: interlock released, lookup {share=1,match=0x0800} -> target 0xCD.
    rs1 = 64'h0000_0000_0001_0800;
    uop = rdcam_op(); tid = 3'd2; valid = 1'b1;
    #1;
    check(ready,                      "CPPRSRDCAM: interlock released after the write commits");
    check(cam_hit,                    "CPPRSRDCAM: programmed entry should hit");
    check(cam_target == 32'h0000_00CD, "CPPRSRDCAM: lookup returns programmed target");
    @(posedge clk); #1; valid = 1'b0;        // accept edge: rd result registered
    check(we,                         "CPPRSRDCAM: writes integer rd");
    check(result == 64'h0000_0000_0000_00CD, "CPPRSRDCAM: rd = target");
    @(posedge clk); #1;

    // ================================================================
    // Scenario 8 — CAMNEXT-hit REDIRECT via a programmed entry (I4b, unblocks OP_CAMNEXT).
    // ================================================================
    // Program CAM[1] {share=2,match=0x0006,target=cur+5}; then a CAMNEXT.s whose key
    // (share=2 from the op, match from Accum) hits, so end-of-node redirects fetch to
    // the programmed node — byte PC = pc_i + (target-cur)*4.
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    @(posedge clk); #1;
    cnt_before = int'(dut.st_q.next_pc);     // current node index (cur)
    // (a) stage {key,target}: key32=(2<<16)|0x0006; target = cur+5.
    rs1 = {32'h0002_0006, 32'(cnt_before + 5)};
    uop = wrpreg_op(5'd15); tid = 3'd3; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    commit = 1'b1; commit_tid = 3'd3; @(posedge clk); #1; commit = 1'b0;
    // (b) program CAM[1] — buffer then COMMIT (N3: the entry applies on commit).
    rs1 = 64'd1;
    uop = wrcam_op(5'd15, 1'b0); tid = 3'd4; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    commit = 1'b1; commit_tid = 3'd4; @(posedge clk); #1; commit = 1'b0;  // CAM[1] programmed
    @(posedge clk); #1;
    // (c) reload Accum low16 = match 0x0006 (Accum is the CAMNEXT key source).
    rs1 = 64'h0000_0000_0000_0006;
    uop = wrpreg_op(5'd15); tid = 3'd5; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    commit = 1'b1; commit_tid = 3'd5; @(posedge clk); #1; commit = 1'b0;
    check(int'(dut.st_q.next_pc) == cnt_before, "CAMNEXT: node index must be unchanged by custom-3 ops");
    // (d) CAMNEXT.s: share=2 (op), match from Accum (sz=half,pos=3 => Accum[15:0]).
    uop = '0; uop.op = OP_CAMNEXT; uop.d = 1'b1; uop.share = 4'd2;
    uop.sz = 2'd2; uop.pos = 4'd3; uop.miss = 3'd0; uop.s = 1'b1;
    tid = 3'd6; valid = 1'b1;
    #1;
    check(cam_hit,     "CAMNEXT: programmed entry should hit");
    check(resolve_br,  "CAMNEXT: a CAM hit should redirect at end-of-node");
    check(!parse_exit, "CAMNEXT: a redirect is not a parse exit");
    check(redir_pc == (64'h8000_0000 + 64'd5 * 4),
          "CAMNEXT: byte PC = pc_i + (target-cur)*4 from the programmed node index");
    @(posedge clk); #1; valid = 1'b0;
    @(posedge clk); #1;

    // ================================================================
    // Scenario 9 — V4: WAW on the parser register file (Table C, last writer wins).
    // ================================================================
    // Two CPPRSWR writes to the SAME p-register (p16 Flags) are both accepted into the
    // pending queue before either commits, then committed in order. The speculative
    // value tracks the YOUNGER write immediately; the architectural shadow reaches the
    // older value on the first commit and the younger on the second. A readback returns
    // the surviving (younger) value. Proves write-after-write ordering survives the
    // commit pipeline.
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    @(posedge clk); #1;
    // (a) older write: p16 <- 0x1111
    rs1 = 64'h0000_0000_0000_1111;
    uop = wrpreg_op(5'd16); tid = 3'd0; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    check(dut.pend_cnt_q == 1,             "WAW: first write should enqueue");
    // (b) younger write: p16 <- 0x2222, in flight before the first commits
    rs1 = 64'h0000_0000_0000_2222;
    uop = wrpreg_op(5'd16); tid = 3'd1; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    check(dut.pend_cnt_q == 2,             "WAW: both writes in flight (queue depth 2)");
    check(dut.st_q.flags == 64'h2222,      "WAW: speculative flags = younger write");
    check(dut.st_arch_q.flags == 64'h0,    "WAW: arch flags unchanged before any commit");
    // commit the older then the younger
    commit = 1'b1; commit_tid = 3'd0; @(posedge clk); #1; commit = 1'b0;
    check(dut.st_arch_q.flags == 64'h1111, "WAW: arch = older write after first commit");
    commit = 1'b1; commit_tid = 3'd1; @(posedge clk); #1; commit = 1'b0;
    check(dut.st_arch_q.flags == 64'h2222, "WAW: arch = younger write after second commit");
    check(dut.pend_cnt_q == 0,             "WAW: queue empty after both commits");
    // readback confirms the surviving value
    uop = rdpreg_op(5'd16); tid = 3'd2; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    check(result == 64'h0000_0000_0000_2222, "WAW: readback returns the younger write");
    @(posedge clk); #1;

    // ================================================================
    // Scenario 10 — Table B: store-past-frame is bounds-gated (no write, no corruption).
    // ================================================================
    // parser_execute suppresses a metadata write whose (offset+nbytes) exceeds META_MAX
    // (64), so the commit-time byte-scatter never runs for it. A store at the LAST valid
    // byte (off=63, 1 byte) lands; a store PAST the frame (off=64) asserts no meta_we and
    // disturbs no committed byte (in particular it must not wrap to offset 0).
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    @(posedge clk); #1;
    // (a) in-bounds store at the last frame byte: off=63, 1 byte 0x5A -> lands on commit
    uop = storeimm_op(9'd63, 16'h005A); tid = 3'd0; valid = 1'b1;
    #1;
    check(dut.meta_we,  "STORE-BOUND: in-bounds store (off=63) should assert meta_we");
    @(posedge clk); #1; valid = 1'b0;
    commit = 1'b1; commit_tid = 3'd0; @(posedge clk); #1; commit = 1'b0;
    check(dut.meta_mem[63] == 8'h5A, "STORE-BOUND: in-bounds byte should land at offset 63");
    // (b) out-of-bounds store at off=64 (== META_MAX): must be suppressed
    uop = storeimm_op(9'd64, 16'h00A5); tid = 3'd1; valid = 1'b1;
    #1;
    check(!dut.meta_we, "STORE-BOUND: store past the frame (off=64) must not assert meta_we");
    @(posedge clk); #1; valid = 1'b0;
    commit = 1'b1; commit_tid = 3'd1; @(posedge clk); #1; commit = 1'b0;
    check(dut.meta_mem[63] == 8'h5A, "STORE-BOUND: OOB store must not corrupt the valid frame");
    check(dut.meta_mem[0]  == 8'h00, "STORE-BOUND: OOB store must not wrap into offset 0");
    @(posedge clk); #1;

    // ================================================================
    // Scenario 11 — N2: CPPRSWRIMM immediate-load is commit-gated (rollback + commit).
    // ================================================================
    // The immediate form drives the SAME pending-queue path as CPPRSWR: the written
    // value tracks the speculative shadow immediately, the architectural shadow only
    // moves on commit, and a flush before commit rolls it back — so a squashed
    // immediate write leaves no architectural trace. imm=0x1DC -> p16 (Flags).
    // (arch flags carry the 0x2222 committed by Scenario 9 — flush rolls back, it does
    // not zero arch — so assert against that inherited value, not literal 0.)
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    @(posedge clk); #1;
    // (a) speculative immediate write, then FLUSH before commit -> rolled back
    uop = wrpregimm_op(5'd16, 11'h1DC); tid = 3'd0; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    check(dut.pend_cnt_q == 1,             "IMM: immediate write should enqueue");
    check(dut.st_q.flags == 64'h1DC,       "IMM: speculative flags = immediate");
    check(dut.st_arch_q.flags != 64'h1DC,  "IMM: arch flags not updated before commit");
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    check(dut.pend_cnt_q == 0,                        "IMM: flush drains the pending queue");
    check(dut.st_q.flags == dut.st_arch_q.flags,      "IMM: flush rolls speculative flags back to arch");
    check(dut.st_q.flags != 64'h1DC,                  "IMM: flush discards the speculative immediate");
    @(posedge clk); #1;
    // (b) immediate write, then COMMIT -> architectural; readback returns it
    uop = wrpregimm_op(5'd16, 11'h1DC); tid = 3'd1; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    commit = 1'b1; commit_tid = 3'd1; @(posedge clk); #1; commit = 1'b0;
    check(dut.st_arch_q.flags == 64'h1DC, "IMM: arch flags = immediate after commit");
    uop = rdpreg_op(5'd16); tid = 3'd2; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    check(result == 64'h0000_0000_0000_01DC, "IMM: readback returns the committed immediate");
    @(posedge clk); #1;

    // ================================================================
    // Scenario 12 — N3: CAM-write speculation safety (rollback vs commit).
    // ================================================================
    // A CPPRSWRCAM buffers its program in the pending queue; a flush before commit
    // discards it, so the CAM entry never appears (a lookup misses). Committing instead
    // programs the CAM and makes the entry visible. Uses a fresh entry: index 2,
    // key {share=3, match=0x0009}, target 0x77.
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    @(posedge clk); #1;
    // stage {key,target} into Accum (p15), commit it.
    rs1 = 64'h0003_0009_0000_0077;
    uop = wrpreg_op(5'd15); tid = 3'd0; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    commit = 1'b1; commit_tid = 3'd0; @(posedge clk); #1; commit = 1'b0;
    // (a) SPECULATIVE CAM program at index 2 — then FLUSH before commit.
    rs1 = 64'd2;
    uop = wrcam_op(5'd15, 1'b0); tid = 3'd1; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    check(dut.cam_pend_cnt_q == 1, "CAM-RB: speculative CAM write is pending");
    check(!cam_prog_en,            "CAM-RB: not programmed before commit");
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    check(dut.cam_pend_cnt_q == 0, "CAM-RB: flush discards the pending CAM write");
    @(posedge clk); #1;
    // lookup must MISS — the squashed program never reached the CAM.
    rs1 = 64'h0000_0000_0003_0009;
    uop = rdcam_op(); tid = 3'd2; valid = 1'b1;
    #1;
    check(!cam_hit, "CAM-RB: a flushed CAM write leaves NO entry (lookup misses)");
    @(posedge clk); #1; valid = 1'b0;
    check(result == 64'hFFFF_FFFF_FFFF_FFFF, "CAM-RB: a miss returns all-ones");
    @(posedge clk); #1;
    // (b) program the SAME entry again and COMMIT -> now visible.
    rs1 = 64'd2;
    uop = wrcam_op(5'd15, 1'b0); tid = 3'd3; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    commit = 1'b1; commit_tid = 3'd3;
    #1; check(cam_prog_en, "CAM-RB: a committed CAM write programs the CAM");
    @(posedge clk); #1; commit = 1'b0;
    @(posedge clk); #1;
    rs1 = 64'h0000_0000_0003_0009;
    uop = rdcam_op(); tid = 3'd4; valid = 1'b1;
    #1;
    check(cam_hit,                      "CAM-RB: the committed entry now hits");
    check(cam_target == 32'h0000_0077, "CAM-RB: lookup returns the committed target");
    @(posedge clk); #1; valid = 1'b0;
    @(posedge clk); #1;

    // ================================================================
    // Scenario 13 — N7 functional-coverage closure: exercise the FU pipeline
    // events the earlier scenarios leave uncovered — full-queue backpressure, the
    // CAM dependent-lookup interlock, and a real parser EXIT + caller redirect —
    // so every §2.6.5 cross-product bin (rtl/cva6_parser_wrap.sv c_*) is hit.
    // These are self-validating (the same events the cover points sample are
    // asserted here), not coverage-only no-ops.
    // ================================================================
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    @(posedge clk); #1;
    check(dut.pend_cnt_q == 0, "COV: queue empty entering scenario 13");

    // (0) OP-CLASS sweep: accept one of every parse op class the model-generated smoke
    // program does not emit, so the merged op-class bins reach 100%. Each op is flushed
    // away after (we only need it ACCEPTED once — accept_state ticks c_op_<class>; its
    // datapath result is irrelevant here and is proven elsewhere). share 9 / MISS_STOP
    // keep the CAM ops a clean unprogrammed miss.
    begin
      opcode_e sweep [8];
      sweep = '{OP_LENCUR, OP_CMPIB, OP_CMPINEB, OP_CMPORD,
                OP_CAM, OP_SETCODE, OP_STORE, OP_STP};
      foreach (sweep[i]) begin
        uop = '0; uop.op = sweep[i];
        uop.share = 4'd9; uop.miss = MISS_STOP; uop.sz = 2'd2; uop.pos = 4'd3; uop.s = 1'b1;
        tid = 3'd0; valid = 1'b1;
        @(posedge clk); #1; valid = 1'b0;                 // <- c_op_<class> samples
        flush = 1'b1; @(posedge clk); #1; flush = 1'b0;   // reset state for the next class
        @(posedge clk); #1;
      end
    end
    check(dut.pend_cnt_q == 0, "COV: op-class sweep left the queue drained");

    // (a) BACKPRESSURE while the pending queue is FULL: hold a fresh parse op valid
    // against a full queue across a clock so c_bp_full (valid & pend_full) samples.
    for (int unsigned i = 0; i < 4; i++) issue(3'(i));   // fill to PEND_DEPTH, no commit
    check(dut.pend_cnt_q == 4, "COV: queue full (backpressure)");
    uop = load_op(); tid = 3'd0; valid = 1'b1;           // a 5th op, rejected while full
    @(posedge clk); #1;                                  // <- c_bp_full samples here
    check(!ready, "COV: ready low while the queue is full (op not accepted)");
    valid = 1'b0;
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;      // drain
    @(posedge clk); #1;

    // (b) CAM dependent-lookup INTERLOCK: a lookup that follows a still-uncommitted
    // CPPRSWRCAM must stall at issue (c_interlock). Stage p15, commit it, program the
    // CAM speculatively (no commit), then drive a dependent rdcam while it is pending.
    rs1 = 64'h0003_0009_0000_0077;
    uop = wrpreg_op(5'd15); tid = 3'd0; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    commit = 1'b1; commit_tid = 3'd0; @(posedge clk); #1; commit = 1'b0;
    rs1 = 64'd4;
    uop = wrcam_op(5'd15, 1'b0); tid = 3'd1; valid = 1'b1;   // CAM write pending, NOT committed
    @(posedge clk); #1; valid = 1'b0;
    check(dut.cam_pend_cnt_q == 1, "COV: CAM write pending for the interlock");
    rs1 = 64'h0000_0000_0003_0009;
    uop = rdcam_op(); tid = 3'd2; valid = 1'b1;              // dependent lookup while pending
    @(posedge clk); #1;                                     // <- c_interlock samples here
    check(!ready, "COV: dependent CAM lookup stalls while an older CPPRSWRCAM is uncommitted");
    valid = 1'b0;
    commit = 1'b1; commit_tid = 3'd1; @(posedge clk); #1; commit = 1'b0;   // release
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    @(posedge clk); #1;

    // (c) a real parser EXIT + caller REDIRECT: an OP_CAMNEXT whose key is NOT
    // programmed misses; with miss=MISS_STOP the datapath ends the parse (f_fail ->
    // done). With parse_exit_pc_i != 0 the FU steers fetch back to the caller landing
    // PC — c_parse_exit + c_redirect_exit (a jump and an exit are mutually exclusive,
    // so redirect_jump stays low: a_jump_xor_exit still holds).
    uop = '0; uop.op = OP_CAMNEXT; uop.miss = MISS_STOP;    // miss => f_fail => exit
    uop.share = 4'd9; uop.sz = 2'd2; uop.pos = 4'd3; uop.s = 1'b1;  // share 9: unprogrammed
    tid = 3'd0; valid = 1'b1;
    #1;
    check(!cam_hit,             "COV: the exit lookup key is unprogrammed (miss)");
    check(dut.parse_exit_o,     "COV: an OP_CAMNEXT miss with MISS_STOP exits the parser");
    check(dut.resolve_branch_o, "COV: an exit with a landing PC redirects the frontend");
    check(dut.redirect_pc_o == 64'h8000_1000, "COV: exit redirect targets the caller landing PC");
    @(posedge clk); #1; valid = 1'b0;                       // <- c_parse_exit/c_redirect_exit sampled
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;         // clear the done state
    @(posedge clk); #1;

    // ================================================================
    // Scenario 14 — M1: mid-parse register-state round-trip (§3.1 item 4,
    // register half). The new writable position registers {p1,p2,p6,p7,p8}
    // save/clobber/restore bit-for-bit via the custom-3 CPPRSWR/CPPRSRD ABI.
    // p9 (Done) is READ-ONLY: it is observable (CPPRSRD) but a CPPRSWR to it is
    // ignored — done is a status flag, not restorable cursor state.
    // ================================================================
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    @(posedge clk); #1;
    check(dut.pend_cnt_q == 0, "M1: queue empty entering scenario 14");

    // (a) round-trip: for each new writable cpreg, WRITE a field-width-exercising
    // value (high bits set to prove write-masking + read zero-extension), COMMIT,
    // and read it back field-masked; CLOBBER with 0xA5.. and prove the readback
    // changed (the write is not a no-op); RESTORE the saved value and prove the
    // readback matches again — a genuine save/clobber/restore round-trip.
    begin
      logic [4:0]  m1_cp  [5];
      logic [63:0] m1_wr  [5];   // value driven on rs1 (upper bits are garbage)
      logic [63:0] m1_exp [5];   // expected CPPRSRD readback (field-masked, zero-extended)
      m1_cp  = '{5'd1, 5'd2, 5'd6, 5'd7, 5'd8};
      m1_wr  = '{64'hDEAD_BEEF_0002_AAAA, 64'hCAFE_F00D_0001_873C,
                 64'hFFFF_FFFF_FFFF_BEEF, 64'hFFFF_FFFF_FFFF_FFC7,
                 64'hFFFF_FFFF_FFFF_FEA5};
      m1_exp = '{64'h0000_0000_0002_AAAA, 64'h0000_0000_0001_873C,
                 64'h0000_0000_0000_BEEF, 64'h0000_0000_0000_00C7,
                 64'h0000_0000_0000_02A5};
      foreach (m1_cp[i]) begin
        // write took
        rs1 = m1_wr[i]; uop = wrpreg_op(m1_cp[i]); tid = 3'd0; valid = 1'b1;
        @(posedge clk); #1; valid = 1'b0;
        commit = 1'b1; commit_tid = 3'd0; @(posedge clk); #1; commit = 1'b0;
        uop = rdpreg_op(m1_cp[i]); tid = 3'd1; valid = 1'b1;
        @(posedge clk); #1; valid = 1'b0;
        check(result === m1_exp[i], "M1 round-trip: CPPRSRD != field-masked CPPRSWR value");
        @(posedge clk); #1;
        // clobber changes the readback
        rs1 = 64'hA5A5_A5A5_A5A5_A5A5; uop = wrpreg_op(m1_cp[i]); tid = 3'd2; valid = 1'b1;
        @(posedge clk); #1; valid = 1'b0;
        commit = 1'b1; commit_tid = 3'd2; @(posedge clk); #1; commit = 1'b0;
        uop = rdpreg_op(m1_cp[i]); tid = 3'd3; valid = 1'b1;
        @(posedge clk); #1; valid = 1'b0;
        check(result !== m1_exp[i], "M1 clobber: readback should differ after an A5 clobber");
        @(posedge clk); #1;
        // restore round-trips back bit-exact
        rs1 = m1_wr[i]; uop = wrpreg_op(m1_cp[i]); tid = 3'd4; valid = 1'b1;
        @(posedge clk); #1; valid = 1'b0;
        commit = 1'b1; commit_tid = 3'd4; @(posedge clk); #1; commit = 1'b0;
        uop = rdpreg_op(m1_cp[i]); tid = 3'd5; valid = 1'b1;
        @(posedge clk); #1; valid = 1'b0;
        check(result === m1_exp[i], "M1 restore: readback should match the saved value again");
        @(posedge clk); #1;
      end
    end
    check(dut.pend_cnt_q == 0, "M1: queue drained after the register round-trip");

    // (b) p9 (Done) is READ-ONLY. It is observable via CPPRSRD (the context switcher
    // reads it to decide "is this thread mid-parse?"), but a CPPRSWR to p9 is IGNORED
    // (write_preg has no p9 case) — done is a status flag, not restorable cursor state,
    // and injecting done=1 out of band would be a spurious mid-stream exit. Prove both:
    // the read works, and a write does not disturb it.
    uop = rdpreg_op(5'd9); tid = 3'd0; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    check(result === 64'd0, "M1: CPPRSRD p9 reads done (0 here, no parse has exited)");
    @(posedge clk); #1;
    // attempt to write p9<-1: it must be a no-op (done stays 0, spec and arch)
    rs1 = 64'hFFFF_FFFF_FFFF_FFFF; uop = wrpreg_op(5'd9); tid = 3'd0; valid = 1'b1;
    @(posedge clk); #1; valid = 1'b0;
    commit = 1'b1; commit_tid = 3'd0; @(posedge clk); #1; commit = 1'b0;
    check(dut.st_q.done      == 1'b0, "M1: CPPRSWR p9 is ignored — done stays 0 (spec)");
    check(dut.st_arch_q.done == 1'b0, "M1: CPPRSWR p9 is ignored — done stays 0 (arch)");
    flush = 1'b1; @(posedge clk); #1; flush = 1'b0;
    @(posedge clk); #1;

    // ---- verdict ----
    if (tb_fails == 0)
      $display("parser_wrap_tb: PASS (I1 rollback/commit/backpressure + I2 metadata + I3 readback + I4a redirect + I4b CAM program/readback/camnext + I5 MMIO meta read + V4 WAW + V11 reset/X + store-bound + CPPRSWRIMM + CAM commit-gate/rollback + COV backpressure/interlock/exit-redirect + M1 mid-parse register round-trip + p9 read-only)");
    else
      $fatal(1, "parser_wrap_tb: FAIL (%0d checks failed)", tb_fails);
    $finish;
  end

  // safety net: never hang
  initial begin
    repeat (2000) @(posedge clk);
    $fatal(1, "parser_wrap_tb: TIMEOUT");
  end
endmodule : parser_wrap_tb
