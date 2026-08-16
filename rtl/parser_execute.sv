// parser_execute.sv — the parser functional unit datapath (Phase 5, §4.2/§4.4).
//
// A hardware `exec_one` (model/libparsermodel/parser.c): given the current
// machine state and one decoded micro-op, it computes the next state, any
// metadata write, and the control transfer (next_pc / done / exit code). Each
// branch mirrors an execute_* / common_end_of_node routine 1:1 so Phase-6
// co-simulation compares like with like.
//
// This is combinational (single-cycle per micro-op for the bring-up slice); the
// variable-latency ready/valid framing decided in Phase 4 (§4.4, D3) is added by
// the CVA6 seam wrapper (cva6_parser_wrap.sv). Address/key generation lives in a
// separate always_comb (depends only on state+op) so the packet-window and CAM
// reads form an acyclic path — no combinational loop through this unit.

module parser_execute
  import parser_pkg::*;
(
    input  pstate_t              st_i,
    input  micro_op_t            op_i,
    input  logic [PC_W-1:0]      pc_i,
    input  logic [15:0]          parse_len_i,

    // packet window (parser_pktbuf)
    output logic [PKT_OFF_W-1:0] mem_off_o,
    input  logic [63:0]          mem_win_be_i,

    // CAM (parser_cam)
    output logic [3:0]           cam_share_o,
    output logic [15:0]          cam_match_o,
    input  logic                 cam_hit_i,
    input  logic [31:0]          cam_target_i,

    // metadata write (parser_top applies to the metadata RAM)
    output logic                 meta_we_o,
    output logic [META_OFF_W-1:0] meta_off_o,
    output logic [63:0]          meta_wdata_o,
    output logic [3:0]           meta_nbytes_o,

    // next machine state
    output pstate_t              st_o
);

  localparam logic [15:0] MAX_NODES = 16'd32;   // pm_init
  localparam logic [7:0]  MAX_ENCAP = 8'd4;
  localparam logic [63:0] ALL_ONES  = {64{1'b1}};

  // ---- termination / control helpers (all pure: pstate -> pstate) ----
  function automatic pstate_t f_fail(input pstate_t s, input logic signed [31:0] c);
    s.done = 1'b1; s.code = c; return s;
  endfunction

  function automatic pstate_t f_eon(input pstate_t s);
    logic [31:0]          nx, addr32;
    logic [PKT_OFF_W-1:0] new_cur;
    // Stage 1: the Loop register (data-header / sub-node level)
    if (!is_ret_code(s.loop)) begin                 // Loop = address -> live loop
      s.databound = s.databound - {23'h0, s.dat_len};
      s.dat_off   = s.dat_off + s.dat_len;
      s.dat_len   = '0;
      s.next_pc   = s.loop[PC_W-1:0];
      return s;
    end else if (!is_ok_code(s.loop)) begin         // Loop = error code
      return f_fail(s, s.loop);
    end
    // Stage 2: the Next register (protocol-header level)
    nx = s.next;
    if (!is_ret_code(s.next)) begin                 // Next = address
      s.node_cnt = s.node_cnt + 16'd1;
      if (s.node_cnt > MAX_NODES) return f_fail(s, P_STOP_MAX_NODES);
      addr32 = nx & NEXT_ADDR_MASK;
      if (|(nx & NEXT_ENCAP_BIT)) begin
        s.encap = s.encap + 8'd1;
        if (s.encap > MAX_ENCAP) return f_fail(s, P_STOP_ENCAP_DEPTH);
      end
      if (|(nx & NEXT_OVERLAY_BIT)) begin
        // overlay: offsets / lengths unchanged
      end else begin                                // normal transition
        new_cur    = s.cur_off + s.cur_len;
        s.cur_off  = new_cur;
        s.dat_off  = new_cur;
        s.cur_len  = '0;
        s.dat_len  = '0;
        s.databound = 32'hFFFF_FFFF;
      end
      s.loop    = P_OKAY_RET;
      s.next    = P_STOP_OKAY;
      s.next_pc = addr32[PC_W-1:0];
      return s;
    end else if (is_ok_code(s.next)) begin          // Next = OK code -> normal exit
      s.done = 1'b1; s.code = P_STOP_OKAY; return s;
    end else begin                                  // Next = error code
      return f_fail(s, s.next);
    end
  endfunction

  function automatic pstate_t f_2bit(input pstate_t s, input logic [1:0] er);
    unique case (er)
      ER_STOP:     return f_fail(s, P_STOP_COMPARE);
      ER_STOPNODE: return f_eon(s);
      ER_STOPSUB:  begin s.loop = P_STOP_SUB_NODE_OKAY; return f_eon(s); end
      default:     return f_fail(s, P_STOP_FAIL);   // ER_FAIL
    endcase
  endfunction

  function automatic pstate_t f_cam_miss(input pstate_t s, input logic [2:0] miss);
    unique case (miss)
      MISS_STOP:    return f_fail(s, P_STOP_UNKNOWN_PROTO);
      MISS_STOPSUB: begin s.loop = P_STOP_SUB_NODE_OKAY; return f_eon(s); end
      MISS_FAIL:    return f_fail(s, P_STOP_UNKNOWN_PROTO);
      MISS_FAILSUB: return f_fail(s, P_STOP_TLV_LENGTH);
      default:      return s;   // WILD/ALT wildcard regs — deferred
    endcase
  endfunction

  // byte count for a load/store of this Sz
  logic [31:0] n32;
  assign n32 = load_nbytes(op_i.sz);

  // ---- address / key generation (depends only on state + op) ----
  // Kept separate so parser_pktbuf/parser_cam reads are acyclic (no UNOPTFLAT).
  logic [31:0] absoff;
  always_comb begin
    logic [31:0] base32;
    logic [63:0] key64;
    base32 = op_i.x ? {23'h0, st_i.dat_off} : {23'h0, st_i.cur_off};
    absoff = base32 + {23'h0, op_i.offset};
    mem_off_o = (op_i.op == OP_LOAD) ? absoff[PKT_OFF_W-1:0] : '0;

    // CAM key (harmless when the op is not a CAM op)
    cam_share_o = op_i.share;
    key64       = extract_subreg(op_i.f ? st_i.flags : st_i.accum, op_i.sz, op_i.pos);
    cam_match_o = key64[15:0];
  end

  // ---- execute ----
  always_comb begin
    pstate_t s;
    logic    did_ret;
    logic [31:0] off32, lastb;
    logic [63:0] raw, val, field, src, tval;
    logic [8:0]  len;
    logic [63:0] mask64;
    logic        cmp_ok;
    logic signed [31:0] camr;
    logic [31:0] nbytes;

    // defaults
    s              = st_i;
    s.next_pc      = pc_i + 1'b1;      // pm_run: default fall-through
    did_ret        = 1'b0;
    meta_we_o      = 1'b0;
    meta_off_o     = '0;
    meta_wdata_o   = '0;
    meta_nbytes_o  = '0;
    off32          = {23'h0, op_i.offset};
    nbytes         = n32;

    unique case (op_i.op)

      OP_INITPARSER: ;  // handled by reset/init in parser_top

      // ---- PLOAD (execute_load) ----
      OP_LOAD: begin
        logic ok;
        ok = 1'b1;
        if (op_i.x) begin                                   // data-header relative (TLV)
          if ((off32 + nbytes) > st_i.databound)                                  begin s = f_fail(st_i, P_STOP_TLV_LENGTH); ok = 0; end
          else if (({23'h0, st_i.dat_off} + off32 + nbytes) > {16'h0, parse_len_i}) begin s = f_fail(st_i, P_STOP_TLV_LENGTH); ok = 0; end
        end else begin                                      // current-header relative
          if (({23'h0, st_i.cur_off} + off32 + nbytes) > {16'h0, parse_len_i})     begin s = f_fail(st_i, P_STOP_LENGTH);     ok = 0; end
        end

        if (ok) begin
          raw = mem_win_be_i >> (8 * (8 - nbytes));         // high n bytes, right-aligned
          val = op_i.e ? raw : bswap_n(raw, nbytes);        // E: keep BE; else host order
          val = val << op_i.shift;
          if (op_i.blen != 0) begin
            logic [31:0] mb;
            mb = (nbytes == 32'd8) ? ({28'h0, op_i.blen} << 1) : {28'h0, op_i.blen};
            mask64 = (mb >= 32'd64) ? 64'h0 : (ALL_ONES >> mb[5:0]);
            val = val & mask64;
          end
          begin
            logic [31:0] shl;
            shl = 32'd64 - (nbytes << 3);                  // 64 - 8n
            s.accum = val << shl[6:0];                      // place field at MSB
          end
          // load-sets-length
          begin
            logic [31:0] endb;
            endb = off32 + nbytes;
            if (op_i.x) begin
              if (endb > {23'h0, st_i.dat_len}) s.dat_len = endb[PKT_OFF_W-1:0];
            end else begin
              if (endb > {23'h0, st_i.cur_len}) s.cur_len = endb[PKT_OFF_W-1:0];
            end
          end
        end else did_ret = 1'b1;
      end

      // ---- PLENCUR / lensetmin (execute_lencur) ----
      OP_LENCUR: begin
        field = extract_subreg(st_i.accum, op_i.sz, op_i.pos);
        if (op_i.shift == 3'd7)      len = op_i.value[8:0];
        else if (!op_i.d)            len = (field[8:0] << op_i.shift) + op_i.value[8:0];
        else                         len = (field[8:0] << op_i.shift);
        // (len is 9-bit => the model's & 0x1FF truncation is implicit)
        lastb = {23'h0, st_i.cur_off} + {23'h0, len};
        if (op_i.d && (len < ((op_i.value == 0) ? 9'd1 : op_i.value[8:0]))) begin
          s = f_fail(st_i, P_STOP_LENGTH); did_ret = 1'b1;
        end else if ((lastb > {16'h0, parse_len_i}) || (len < st_i.cur_len)) begin
          s = f_fail(st_i, P_STOP_LENGTH); did_ret = 1'b1;
        end else begin
          s.cur_len = len;
          if (op_i.d || (op_i.shift == 3'd7)) s.dat_off = st_i.cur_off + op_i.value[PKT_OFF_W-1:0];
          s.databound = ({23'h0, st_i.cur_off} + {23'h0, len}) - {23'h0, s.dat_off};
        end
      end

      // ---- compare family (execute_cmpib / cmpineb / cmpord) ----
      OP_CMPIB: begin
        tval = extract_subreg(st_i.accum, 2'd1, op_i.pos);          // byte
        if ((tval[7:0] & op_i.mask) != op_i.value[7:0]) begin s = f_2bit(st_i, op_i.er); did_ret = 1'b1; end
      end
      OP_CMPINEB: begin
        tval = extract_subreg(st_i.accum, 2'd1, op_i.pos);
        if ((tval[7:0] & op_i.mask) == op_i.value[7:0]) begin s = f_2bit(st_i, op_i.er); did_ret = 1'b1; end
      end
      OP_CMPORD: begin
        val = extract_subreg(st_i.accum, op_i.sz, op_i.pos);
        unique case (op_i.func3)
          2'd0:    cmp_ok = (val <  {48'h0, op_i.value});
          2'd1:    cmp_ok = (val <= {48'h0, op_i.value});
          2'd2:    cmp_ok = (val >  {48'h0, op_i.value});
          default: cmp_ok = (val >= {48'h0, op_i.value});
        endcase
        if (!cmp_ok) begin s = f_2bit(st_i, op_i.er); did_ret = 1'b1; end
      end

      // ---- CAM (execute_cam / execute_camnext) ----
      OP_CAM: begin
        if (cam_hit_i) begin
          s.accum = {32'h0, cam_target_i};
        end else begin
          s = f_cam_miss(st_i, op_i.miss);
          if (!s.done) s.accum = {32'h0, 32'hFFFF_FFFF};
          did_ret = 1'b1;
        end
      end
      OP_CAMNEXT: begin
        if (cam_hit_i) begin
          camr   = cam_target_i;
          s.next = camr & (NEXT_ADDR_MASK | NEXT_CTRL_MASK);
        end else begin
          s = f_cam_miss(st_i, op_i.miss);
          did_ret = 1'b1;
        end
      end

      // ---- store family (execute_store / execute_storeimm) ----
      OP_STORE: begin
        src = op_i.j ? st_i.flags : st_i.accum;
        if (op_i.sz == 2'd0) begin tval = src;                                     nbytes = 32'd8; end
        else                 begin tval = extract_subreg(src, op_i.sz, op_i.pos);  nbytes = (32'd1 << (op_i.sz - 1)); end
        if (op_i.e) tval = bswap_n(tval, nbytes);
        if ((off32 + nbytes) <= META_MAX) begin
          meta_we_o     = 1'b1;
          meta_off_o    = op_i.offset;
          meta_wdata_o  = tval;
          meta_nbytes_o = nbytes[3:0];
        end
      end
      OP_STOREIMM: begin
        nbytes = (op_i.sz == 2'd0) ? 32'd4 : (32'd1 << (op_i.sz - 1));
        if ((off32 + nbytes) <= META_MAX) begin
          meta_we_o     = 1'b1;
          meta_off_o    = op_i.offset;
          meta_wdata_o  = {48'h0, op_i.value};
          meta_nbytes_o = nbytes[3:0];
        end
      end

      // ---- control / next (execute_nextnode / setcode) ----
      OP_NEXTNODE: begin
        s.next = {{16{op_i.payload[15]}}, op_i.payload} & (NEXT_ADDR_MASK | NEXT_CTRL_MASK);
        if (op_i.value != 0) s.next = s.next | NEXT_OVERLAY_BIT;
      end
      OP_SETCODE: begin
        s.next = NEXT_CODE_BIT | ({{16{op_i.payload[15]}}, op_i.payload} & 32'hFF);
      end

      // ---- PSTP ----
      OP_STP: begin s = f_eon(st_i); did_ret = 1'b1; end

      default: begin s = f_fail(st_i, P_STOP_FAIL); did_ret = 1'b1; end
    endcase

    // trailing `if (in->s) common_end_of_node(ps)` for the s-capable ops
    if (op_i.s && !did_ret && !s.done) begin
      unique case (op_i.op)
        OP_LENCUR, OP_CMPIB, OP_CMPINEB, OP_CMPORD,
        OP_CAM, OP_CAMNEXT, OP_STORE, OP_STOREIMM,
        OP_NEXTNODE, OP_SETCODE: s = f_eon(s);
        default: ;   // LOAD / INIT / STP: no trailing s-eon
      endcase
    end

    st_o = s;
  end

endmodule : parser_execute
