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
//
// CUSTOM-3 WRITE + CAM PROGRAMMING (I4b, docs/analysis/cva6-verification-design.md §1;
// closes G3's CAM path): three more custom-3 moves join CPPRSRD, all threading the
// integer rs1 operand from ex_stage. CPPRSWR writes a p-register from rs1 (enqueued +
// commit-gated like a parse op). CPPRSWRCAM programs a CAM entry: index=rs1, and the
// {key,target} come from p[cpreg] (per the patent, key=p>>32, target=p[31:0]); D deletes.
// CPPRSRDCAM does a CAM lookup keyed by rs1 and returns the target into rd (all-ones on
// a miss). This unblocks OP_CAMNEXT: a programmed CAM entry now drives a real end-of-node
// redirect. NOTE: the CAM write itself is applied at EXECUTE (speculative, so a following
// lookup sees it) and is NOT yet commit-gated / rolled back on flush — a deliberate
// deferred escalation (like the I2 sim-only backdoor), tracked in the status doc.

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
    input  logic [63:0]              rs1_i,            // integer rs1 operand (custom-3)
    input  logic [15:0]              parse_len_i,      // PktLen.ParseLen
    input  logic [VLEN-1:0]          parse_exit_pc_i,  // byte PC to resume at on parse exit (I5)
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

    // ---- CAM (parser_cam) : lookup (parse ops + CPPRSRDCAM) + program (CPPRSWRCAM) ----
    output logic [3:0]               cam_share_o,
    output logic [15:0]              cam_match_o,
    input  logic                     cam_hit_i,
    input  logic [31:0]              cam_target_i,
    output logic                     cam_prog_en_o,     // CPPRSWRCAM: program this cycle
    output logic [CAM_IDX_W-1:0]     cam_prog_index_o,  // = regs[rs1]
    output logic                     cam_prog_valid_o,  // 1 = write, 0 = delete (D bit)
    output logic [3:0]               cam_prog_share_o,
    output logic [15:0]              cam_prog_match_o,
    output logic [31:0]              cam_prog_target_o,

    // ---- metadata frame read port (MMIO flow_keys readback, I5) ----
    // The SoC MMIO metadata peripheral reads the committed flow_keys so a bare-metal
    // program can `ld` the result and compare it to the model (closes the deferred MMIO
    // escalation; replaces the I2/I4 sim-only backdoor XMR reads). 64-bit beat: 8
    // little-endian bytes from an 8-aligned offset (byte k = meta_rd_addr_i + k).
    input  logic [META_OFF_W-1:0]    meta_rd_addr_i,
    output logic [63:0]              meta_rd_data_o,

    // ---- latched parse-exit status (MMIO readback, I5) ----
    // parse_exit_o/parse_code_o are valid only the cycle the parser exits; the cosim
    // reads the result later, so latch it: [32] = an exit was seen, [31:0] = the signed
    // ParserExitCode. Lets negative/boundary cases distinguish a real failure from a
    // coincidentally-matching partial flow_keys.
    output logic [63:0]              parse_status_o
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
  logic [3:0]           exec_cam_share;   // CAM lookup key from a parse op (OP_CAM*)
  logic [15:0]          exec_cam_match;

  parser_execute u_exec (
      .st_i(st_q), .op_i(uop_i), .pc_i(st_q.next_pc), .parse_len_i(parse_len_i),
      .mem_off_o(pkt_off_o),  .mem_win_be_i(pkt_win_be_i),
      .cam_share_o(exec_cam_share), .cam_match_o(exec_cam_match),
      .cam_hit_i(cam_hit_i),  .cam_target_i(cam_target_i),
      .meta_we_o(meta_we),    .meta_off_o(meta_off),
      .meta_wdata_o(meta_wdata), .meta_nbytes_o(meta_nbytes),
      .st_o(st_n)
  );

  // CAM LOOKUP mux: a parse op (OP_CAM/OP_CAMNEXT) keys the CAM from parser_execute;
  // a custom-3 CPPRSRDCAM keys it from the integer rs1 (share=rs1[19:16], match=rs1[15:0],
  // per isa/parser-opcodes.yaml cam_key.shared). Only one is live per issued op.
  assign cam_share_o = uop_i.rd_cam ? rs1_i[19:16] : exec_cam_share;
  assign cam_match_o = uop_i.rd_cam ? rs1_i[15:0]  : exec_cam_match;

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
      5'd13:   read_preg = {s.loop, s.databound};                  // p13 DataBndLoop
      5'd14:   read_preg = {{32{s.code[31]}}, s.code};             // p14 ParserExitCode
      5'd15:   read_preg = s.accum;                                 // p15 Accum
      5'd16:   read_preg = s.flags;                                 // p16 Flags
      default: read_preg = 64'h0;        // p-reg outside the execution subset: reads 0
    endcase
  endfunction

  // ---- custom-3 register write (CPPRSWR `prs.mv.p.x p<cpreg>, rs1`) (I4b) ----------
  // The write-twin of read_preg: overwrite the selected pstate_t field from the
  // integer rs1. It advances parser state (a p-register is architectural), so — like
  // a parse op — it is enqueued and commit-gated (I1). Registers outside the writable
  // subset are ignored. p15 (Accum) is the natural staging register for CPPRSWRCAM's
  // {key,target} word (see the CAM program drive below).
  function automatic pstate_t write_preg(input pstate_t s, input logic [4:0] sel,
                                         input logic [63:0] v);
    write_preg = s;
    unique case (sel)
      5'd11:   write_preg.next  = v[31:0];                         // p11 Next
      5'd13:   begin write_preg.databound = v[31:0]; write_preg.loop = v[63:32]; end
      5'd14:   write_preg.code  = v[31:0];                         // p14 ParserExitCode
      5'd15:   write_preg.accum = v;                               // p15 Accum
      5'd16:   write_preg.flags = v;                               // p16 Flags
      default: ;   // p-reg outside the writable subset: ignored
    endcase
  endfunction

  // ---- issued-op classification -------------------------------------------------
  // A genuine custom-0 PARSE op (advances the node index, can redirect/exit, keys the
  // CAM lookup); vs the custom-3 coprocessor moves (register/CAM I/O, no node advance).
  wire op_rd     = uop_i.rd_preg | uop_i.rd_cam;     // custom-3 read  -> integer rd
  wire op_wr_reg = uop_i.wr_preg | uop_i.wr_preg_imm; // custom-3 write p-register (rs1 or imm)
  wire op_wr_cam = uop_i.wr_cam;                      // custom-3 program CAM
  wire is_parse  = ~(op_rd | op_wr_reg | op_wr_cam);  // custom-0 parse micro-op

  // Single-cycle FU for the slice (Phase-4 D3: variable latency; here 1 cycle). Ops
  // that advance parser state (parse ops + CPPRSWR) need pending-queue room and stop
  // once the parser has exited; reads and CAM programming are always ready (they never
  // enter the queue), so state stays readable / the CAM stays writable after an exit.
  wire needs_queue = is_parse | op_wr_reg;
  assign parser_ready_o = rst_ni & ((op_rd | op_wr_cam) | (~st_q.done & ~pend_full));

  // ---- metadata frame (flow_keys) : the commit-gated architectural sink (I2) -----
  // 64×8 byte frame, mirroring parser_top.sv's meta_mem. The per-op metadata write
  // produced by parser_execute (meta_we/off/wdata/nbytes) is buffered in the pending
  // queue and byte-scattered here only when the op COMMITS (see always_ff below), so
  // a squashed speculative op never dirties the frame. Read back combinationally;
  // the wrap TB / harness backdoor reads meta_mem hierarchically (I2 sim-only feed).
  localparam int unsigned META_IDX_W = $clog2(META_MAX);
  logic [7:0] meta_mem [0:META_MAX-1];

  // latched parse-exit status for MMIO readback (I5)
  logic               exit_seen_q;
  logic signed [31:0] exit_code_q;
  assign parse_status_o = {31'b0, exit_seen_q, exit_code_q};

  // MMIO flow_keys readback (I5): combinational 64-bit read, range-checked per lane.
  // Reads the COMMITTED frame (meta_mem is only written on commit), so an `ld` after
  // the parse program retires observes exactly the architectural flow_keys.
  always_comb begin
    meta_rd_data_o = 64'h0;
    for (int k = 0; k < 8; k++) begin
      logic [META_OFF_W:0] a;
      a = {1'b0, meta_rd_addr_i} + k[META_OFF_W:0];
      if (a < META_MAX[META_OFF_W:0])
        meta_rd_data_o[8*k +: 8] = meta_mem[a[META_IDX_W-1:0]];
    end
  end

  logic accept;
  assign accept = parser_valid_i & parser_ready_o & ~flush_i;
  wire accept_state   = accept & is_parse;    // a parse op (advances node, may redirect)
  wire accept_advance = accept & needs_queue; // parse op OR CPPRSWR (enqueues, commit-gated)
  wire accept_rd      = accept & op_rd;       // custom-3 read -> integer rd
  wire accept_wrcam   = accept & op_wr_cam;   // custom-3 CAM program

  // The architectural state THIS accepted op advances to: st_n for a parse op, or the
  // written p-register for a custom-3 write (both enter the pending queue / commit-gate).
  // CPPRSWR takes its value from the integer rs1; CPPRSWRIMM from the decoded immediate
  // (zero-extended to 64 bits) — no integer operand.
  wire [63:0] wr_preg_val = uop_i.wr_preg_imm ? {53'b0, uop_i.imm} : rs1_i;
  pstate_t st_adv;
  assign st_adv = op_wr_reg ? write_preg(st_q, uop_i.cpreg, wr_preg_val) : st_n;

  // custom-3 read result: CPPRSRD selects a p-register; CPPRSRDCAM returns the CAM
  // lookup target (all-ones on a miss, matching cam_lookup() in parser.c).
  wire [63:0] rd_result = uop_i.rd_cam
      ? (cam_hit_i ? {32'h0, cam_target_i} : 64'hFFFF_FFFF_FFFF_FFFF)
      : read_preg(st_q, uop_i.cpreg);

  // ---- CAM program drive (CPPRSWRCAM) : index = regs[rs1]; {key,target} = p[cpreg] --
  // Per the patent pseudo-code: WriteCAMEntryByIndex(regs[Rs], p[Cpreg]>>32, p[Cpreg]).
  // The 20-bit key is the low bits of p[Cpreg]>>32 (share=key[19:16], match=key[15:0]);
  // the target is p[Cpreg][31:0]. D (cam_del) selects delete. Programmed at EXECUTE
  // (speculative, immediately visible to a following lookup); CAM speculation-safety is
  // a deferred escalation (see the header + status tracker).
  wire [63:0] cam_src = read_preg(st_q, uop_i.cpreg);   // {key[63:32], target[31:0]}
  assign cam_prog_en_o    = accept_wrcam;
  assign cam_prog_index_o = rs1_i[CAM_IDX_W-1:0];
  assign cam_prog_valid_o = ~uop_i.cam_del;             // D=1 => delete (valid=0)
  assign cam_prog_share_o = cam_src[51:48];             // key[19:16]
  assign cam_prog_match_o = cam_src[47:32];             // key[15:0]
  assign cam_prog_target_o= cam_src[31:0];

  // ---- end-of-node redirect target (I4, closes G3) ------------------------------
  // parser_execute reports the next NODE INDEX in st_n.next_pc (0..2^PC_W-1), not a
  // byte PC. The parser program is a contiguous block of parser instructions — node
  // i at ParserInstrBase + i*4 — so the real fetch target is the current op's byte PC
  // plus the signed node delta times 4. Deriving the base from (pc_i, current node)
  // needs no external ParserInstrBase and stays correct across jumps, PROVIDED the
  // block is contiguous (no non-parser instructions interspersed within the parse
  // program, and custom-3 reads — which don't advance the node index — sit outside
  // the jump range). A fall-through (delta==+1) does not redirect; see below.
  wire signed [VLEN-1:0] node_delta_v =
        $signed({{(VLEN-PC_W){1'b0}}, st_n.next_pc}) -
        $signed({{(VLEN-PC_W){1'b0}}, st_q.next_pc});
  wire [VLEN-1:0] redirect_pc_calc = pc_i + (node_delta_v <<< 2);   // + delta*4 bytes

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q              <= reset_state();
      st_arch_q         <= reset_state();
      pend_cnt_q        <= '0;
      pend_head_q       <= '0;
      pend_tail_q       <= '0;
      for (int unsigned i = 0; i < PEND_DEPTH; i++) pend_q[i] <= '0;
      for (int unsigned i = 0; i < META_MAX; i++) meta_mem[i] <= 8'h0;
      exit_seen_q       <= 1'b0;
      exit_code_q       <= '0;
      parser_valid_o    <= 1'b0;
      parser_trans_id_o <= '0;
      parser_result_o   <= '0;
      parser_we_o       <= 1'b0;
    end else begin
      parser_valid_o   <= 1'b0;
      parser_we_o      <= 1'b0;

      // ---- EXECUTE: retire to the scoreboard (the fetch steer is combinational,
      //      see resolve_branch_o/redirect_pc_o below) --------------------------------
      if (accept) begin
        parser_valid_o    <= 1'b1;                // retire this micro-op
        parser_trans_id_o <= trans_id_i;
        parser_we_o       <= op_rd;               // custom-3 reads write rd; others don't
        if (op_rd) begin
          // custom-3 read (CPPRSRD / CPPRSRDCAM): drive rd. No parser-state change,
          // no redirect, no exit, no queue entry — it is a register/CAM move.
          parser_result_o <= rd_result;
        end else if (accept_advance) begin
          // parse op OR CPPRSWR: advance the speculative working state (forwards to
          // the next in-flight op); the architectural copy waits for commit (I1).
          st_q              <= st_adv;
          parser_result_o   <= st_adv.accum;
        end
        // CPPRSWRCAM (op_wr_cam): retires with no state advance / no rd; the CAM
        // write is driven combinationally on cam_prog_* (accept_wrcam) this cycle.
      end

      // latch the parse-exit status for MMIO readback (I5): the exiting op is an
      // accepted parse op whose st_n.done just latched (same cycle parse_exit_o pulses).
      // Gated on the exit EVENT (not the redirect), so status is captured even when no
      // landing PC was set (an inline parse program that falls through on exit).
      if (parse_exited) begin
        exit_seen_q <= 1'b1;
        exit_code_q <= st_n.code;
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
      // State-advancing ops enter the pending queue (parse ops + CPPRSWR), so their
      // architectural effect is commit-gated (I1). Custom-3 reads change no parser
      // state and CPPRSWRCAM's CAM write is not queued (its rd/CAM effects are tracked
      // by the scoreboard / driven at execute), so neither is enqueued. CPPRSWR writes
      // no metadata frame, so its buffered meta_we is forced 0.
      if (accept_advance) begin
        pend_q[pend_tail_q].trans_id    <= trans_id_i;
        pend_q[pend_tail_q].st          <= st_adv;
        pend_q[pend_tail_q].meta_we     <= meta_we & is_parse;  // buffer the metadata write;
        pend_q[pend_tail_q].meta_off    <= meta_off;            // it lands only on commit
        pend_q[pend_tail_q].meta_wdata  <= meta_wdata;
        pend_q[pend_tail_q].meta_nbytes <= meta_nbytes;
        pend_tail_q                     <= pend_tail_q + 1'b1;
      end
      pend_cnt_q <= pend_cnt_q + (PEND_AW+1)'(accept_advance) - (PEND_AW+1)'(pend_commit);

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

  // ---- end-of-node fetch steer : COMBINATIONAL, same-cycle as the executing op ----
  // The frontend/controller resolve contract is same-cycle: controller.sv flushes on
  // resolved_branch_i.is_mispredict and the ex_stage mux samples the LIVE pc_i in the
  // very cycle the op is in EX (exactly how branch_unit.sv drives its resolve). A
  // registered/late strobe would carry a stale pc_i and miss the flush window, so the
  // core never refetches (fetch hangs). We therefore drive the steer combinationally
  // off accept_state. Only the FETCH steer is speculative here — parser register state
  // (st_q/st_arch_q) and the metadata frame stay commit-gated (I1), just like a real
  // branch resolves (steers) at execute but retires at commit.
  // A parse op steers fetch when either (a) it jumps to a non-fall-through node (I4),
  // or (b) it EXITS the parser (I5): once st_q.done latches, no further parse op can
  // issue (a_ready_low_when_done stalls the pipe forever), so on exit the FU must
  // redirect the frontend to a program-provided landing PC (parse_exit_pc_i) — the
  // "parser subroutine return" that lets a full in-core graph walk resume the caller
  // (e.g. to `ld` the committed flow_keys over MMIO). Exit takes priority over the
  // node-delta jump (an exiting op has no meaningful next node).
  wire redirect_jump = accept_state & ~st_n.done &
                       (st_n.next_pc != (st_q.next_pc + 1'b1));
  wire parse_exited  = accept_state &  st_n.done;             // parser reached STP/exit
  // Steer fetch back to the caller ONLY if a landing PC was provided (I5). A parser
  // program that runs INLINE in the instruction stream (e.g. the directed
  // parser_insn.S) leaves parse_exit_pc_i at its reset 0 and simply falls through to
  // the next instruction on exit — no redirect. A program that jumped into a SEPARATE
  // parse block (the cosim) sets parse_exit_pc_i first, so exit returns to it (else the
  // pipe would stall on the block's next custom-0 word). PC 0 is the reset vector /
  // boot ROM, never a valid landing target, so 0 == "unset" is unambiguous.
  wire have_exit_pc  = (parse_exit_pc_i != '0);
  wire redirect_exit = parse_exited & have_exit_pc;          // exit -> caller landing (I5)
  assign resolve_branch_o = redirect_jump | redirect_exit;
  assign redirect_pc_o    = redirect_exit ? parse_exit_pc_i   // exit -> caller landing (I5)
                                          : redirect_pc_calc;  // node index -> byte PC (I4)
  assign parse_exit_o     = parse_exited;                      // parser exited (okay/fail)
  assign parse_code_o     = st_n.code;
  // resolved_branch_o payload is rebuilt in the in-core patch's redirect mux from
  // {resolve_branch_o, redirect_pc_o, pc_i}; this port is left unbound here.
  assign resolved_branch_o = '0;

  // ---- handshake + speculation-safety assertions (compiled out unless
  //      +define+PARSER_ASSERT / +define+FORMAL) --------------------------------
`include "parser_asserts.svh"
  // once the parser has exited, it stops accepting PARSE work — but custom-3 reads
  // and CAM programming are still serviced (e.g. read ParserExitCode after the exit)
  `PRS_ASSERT(a_ready_low_when_done, clk_i, rst_ni,
              (st_q.done & ~(op_rd | op_wr_cam)) |-> !parser_ready_o)
  // a writeback only follows an accepted issue the previous cycle
  `PRS_ASSERT(a_valid_after_accept, clk_i, rst_ni, parser_valid_o |-> $past(accept))
  // integer rd is written ONLY by a custom-3 read (CPPRSRD/CPPRSRDCAM); parse ops
  // and CPPRSWR/CPPRSWRCAM never write rd
  `PRS_ASSERT(a_we_iff_rd, clk_i, rst_ni,
              parser_we_o |-> $past(accept & (uop_i.rd_preg | uop_i.rd_cam)))
  // CAM programming pulses only for an accepted CPPRSWRCAM (I4b)
  `PRS_ASSERT(a_camprog_iff_wrcam, clk_i, rst_ni, cam_prog_en_o |-> (accept & uop_i.wr_cam))
  // SPECULATION SAFETY (G2): the architectural state only ever advances on a commit
  `PRS_ASSERT(a_arch_committed, clk_i, rst_ni, !$stable(st_arch_q) |-> $past(pend_commit))
  // SPECULATION SAFETY (G2): after a flush the speculative state == committed state
  `PRS_ASSERT(a_flush_rollback, clk_i, rst_ni, $past(flush_i) |-> (st_q == st_arch_q))
  // REDIRECT (I5): a parse exit WITH a programmed landing PC steers fetch back to the
  // caller (else the pipe would stall on the block's next parse op); an inline program
  // with no landing PC falls through instead. A node jump vs an exit-redirect are
  // mutually exclusive (an exiting op has no next node) — so never both.
  `PRS_ASSERT(a_exit_redirects, clk_i, rst_ni, (parse_exit_o & have_exit_pc) |-> resolve_branch_o)
  `PRS_ASSERT(a_jump_xor_exit, clk_i, rst_ni, !(redirect_jump & redirect_exit))
  // REDIRECT (I4/G3): a redirect strobe is combinational — it co-asserts with the
  // accepted parse op it steers on (same-cycle resolve contract, like branch_unit)
  `PRS_ASSERT(a_redirect_after_state, clk_i, rst_ni, resolve_branch_o |-> accept_state)

endmodule : cva6_parser_wrap
