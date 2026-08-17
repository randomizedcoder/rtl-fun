// parser_pkg.sv — types, parameters, and the decoded-instruction (micro-op)
// layout for the parser unit (Phase 5).
//
// This package is the RTL mirror of the golden model's machine state and
// decoded-instruction table (model/libparsermodel/parser.h + parser.c). The
// executor (parser_execute.sv) is a hardware `pm_run`: it interprets the SAME
// decoded program the C model runs, so Phase-6 co-simulation compares like with
// like. Constants here match model/libparsermodel and isa/parser-opcodes.yaml.
//
// NOTE (honesty): the micro-op ROM is *generated from the model* (verif/gen/
// gen_parser_rom.c) rather than decoded from 32-bit words, because CAM/next
// TARGETS are resolved at run time and are not carried in the instruction word
// (see model/libparsermodel/encoding.h). Decoding the Phase-3 32-bit encodings
// into micro-ops (the CVA6 decoder path) is the next increment; see
// docs/phase-5-rtl.md.

package parser_pkg;

  // ---- sizing parameters (RTL knobs; see phase-4 §4.6 / §5.5) ----
  localparam int unsigned XLEN         = 64;
  localparam int unsigned PKT_WINDOW_W = 128;                 // 16-byte read window
  localparam int unsigned PKT_MAX      = 256;                 // packet buffer bytes
  localparam int unsigned PKT_OFF_W    = 9;                   // byte-offset width (0..511)
  localparam int unsigned META_MAX     = 64;                  // metadata (flow_keys) bytes
  localparam int unsigned META_OFF_W   = 9;
  localparam int unsigned CAM_DEPTH    = 32;                  // provisioned CAM entries
  localparam int unsigned CAM_IDX_W    = $clog2(CAM_DEPTH);   // CAM entry index width
  localparam int unsigned PROG_MAX     = 128;                 // program ROM depth
  localparam int unsigned PC_W         = 10;

  // ---- opcodes (must match enum opcode in parser.h) ----
  typedef enum logic [3:0] {
    OP_INITPARSER = 4'd0,
    OP_LOAD       = 4'd1,
    OP_LENCUR     = 4'd2,
    OP_CMPIB      = 4'd3,
    OP_CMPINEB    = 4'd4,
    OP_CMPORD     = 4'd5,
    OP_CAM        = 4'd6,
    OP_CAMNEXT    = 4'd7,
    OP_STORE      = 4'd8,
    OP_STOREIMM   = 4'd9,
    OP_NEXTNODE   = 4'd10,
    OP_SETCODE    = 4'd11,
    OP_STP        = 4'd12
  } opcode_e;

  // ---- CAM miss dispositions / compare on-false actions (parser.h) ----
  localparam logic [2:0] MISS_WILD = 3'd0, MISS_ALT = 3'd1, MISS_STOP = 3'd2,
                         MISS_STOPSUB = 3'd3, MISS_FAIL = 3'd4, MISS_FAILSUB = 3'd5;
  localparam logic [1:0] ER_STOP = 2'd0, ER_STOPNODE = 2'd1, ER_STOPSUB = 2'd2, ER_FAIL = 2'd3;

  // ---- Next-register control bits (encodings §3 / parser.h) ----
  localparam logic [31:0] NEXT_ENCAP_BIT   = 32'h4000_0000;
  localparam logic [31:0] NEXT_OVERLAY_BIT = 32'h2000_0000;
  localparam logic [31:0] NEXT_CODE_BIT    = 32'h8000_0000;
  localparam logic [31:0] NEXT_ADDR_MASK   = 32'h00FF_FFFF;
  localparam logic [31:0] NEXT_CTRL_MASK   = 32'h7F00_0000;

  // ---- parser codes (negative bytes; parser.h enum parser_code) ----
  localparam logic signed [31:0] P_OKAY               = 32'sd0;
  localparam logic signed [31:0] P_OKAY_RET           = -32'sd1;
  localparam logic signed [31:0] P_STOP_OKAY          = -32'sd4;
  localparam logic signed [31:0] P_STOP_SUB_NODE_OKAY = -32'sd6;
  localparam logic signed [31:0] P_STOP_FAIL          = -32'sd13;
  localparam logic signed [31:0] P_STOP_LENGTH        = -32'sd14;
  localparam logic signed [31:0] P_STOP_UNKNOWN_PROTO = -32'sd15;
  localparam logic signed [31:0] P_STOP_ENCAP_DEPTH   = -32'sd16;
  localparam logic signed [31:0] P_STOP_TLV_LENGTH    = -32'sd18;
  localparam logic signed [31:0] P_STOP_MAX_NODES     = -32'sd24;
  localparam logic signed [31:0] P_STOP_COMPARE       = -32'sd25;

  // parser.h: IS_RET_CODE(x) = (int32)x < 0 ; IS_OK_CODE = ret && x > STOP_FAIL(-13)
  function automatic logic is_ret_code(input logic signed [31:0] x);
    return (x < 0);
  endfunction
  function automatic logic is_ok_code(input logic signed [31:0] x);
    return (x < 0) && (x > P_STOP_FAIL);
  endfunction

  // ---- decoded instruction (micro-op) ----
  typedef struct packed {
    opcode_e        op;
    logic [1:0]     sz;
    logic [3:0]     pos;
    logic [2:0]     shift;
    logic [3:0]     blen;
    logic           x, e, d, s, f, j;
    logic [8:0]     offset;
    logic [15:0]    value;
    logic [7:0]     mask;
    logic [1:0]     func3;
    logic [1:0]     er;
    logic [3:0]     share;   // CAM table id (shared 1..15); 0 = PC-selector (deferred)
    logic [2:0]     miss;
    logic signed [15:0] payload;  // PNEXTNODE target index / PSETCODE code
    // custom-3 coprocessor moves. None are parse micro-ops — the FU services them
    // directly (I3/I4b). `cpreg` selects a parser register (p0..p31, patent FIG 42).
    //   rd_preg : CPPRSRD    read  p[cpreg]                       -> integer rd
    //   wr_preg : CPPRSWR    write p[cpreg] = regs[rs1]           (I4b)
    //   wr_cam  : CPPRSWRCAM CAM[regs[rs1]] = {key,target} from p[cpreg]; cam_del=D (I4b)
    //   rd_cam  : CPPRSRDCAM lookup key=regs[rs1] -> integer rd   (I4b)
    //   wr_preg_imm : CPPRSWRIMM write p[cpreg] = {53'b0, imm}    (N2, I=1 form)
    logic [4:0]     cpreg;
    logic           rd_preg;
    logic           wr_preg;
    logic           wr_preg_imm;   // CPPRSWRIMM: write p[cpreg] from the 11-bit imm
    logic [10:0]    imm;           // CPPRSWRIMM immediate = {Imm2[20:15], Imm1[11:7]}
    logic           wr_cam;
    logic           rd_cam;
    logic           cam_del;   // CPPRSWRCAM D bit: 1 = remove entry, 0 = write
  } micro_op_t;

  // ---- ROM word bit-layout (LSB0). gen_parser_rom.c packs identically. ----
  // Total 83 bits used; stored in a 96-bit ROM word (top 13 bits = 0).
  localparam int unsigned ROM_W = 96;
  // [15:0] payload | [18:16] miss | [22:19] share | [24:23] er | [26:25] func3
  // [34:27] mask | [50:35] value | [59:51] offset | [60] j | [61] f | [62] s
  // [63] d | [64] e | [65] x | [69:66] blen | [72:70] shift | [76:73] pos
  // [78:77] sz | [82:79] op
  function automatic micro_op_t mop_from_word(input logic [ROM_W-1:0] w);
    micro_op_t m;
    m.payload = signed'(w[15:0]);
    m.miss    = w[18:16];
    m.share   = w[22:19];
    m.er      = w[24:23];
    m.func3   = w[26:25];
    m.mask    = w[34:27];
    m.value   = w[50:35];
    m.offset  = w[59:51];
    m.j       = w[60];
    m.f       = w[61];
    m.s       = w[62];
    m.d       = w[63];
    m.e       = w[64];
    m.x       = w[65];
    m.blen    = w[69:66];
    m.shift   = w[72:70];
    m.pos     = w[76:73];
    m.sz      = w[78:77];
    m.op      = opcode_e'(w[82:79]);
    m.cpreg       = 5'h0;     // ROM/custom-0 path never carries a custom-3 move
    m.rd_preg     = 1'b0;
    m.wr_preg     = 1'b0;
    m.wr_preg_imm = 1'b0;
    m.imm         = 11'h0;
    m.wr_cam      = 1'b0;
    m.rd_cam      = 1'b0;
    m.cam_del     = 1'b0;
    return m;
  endfunction

  // ---- machine state (subset of pstate the slice needs; parser.h) ----
  typedef struct packed {
    logic [PKT_OFF_W-1:0] cur_off;
    logic [PKT_OFF_W-1:0] cur_len;
    logic [PKT_OFF_W-1:0] dat_off;
    logic [PKT_OFF_W-1:0] dat_len;
    logic [31:0]          databound;
    logic signed [31:0]   loop;
    logic [63:0]          accum;
    logic [63:0]          flags;
    logic signed [31:0]   next;
    logic [7:0]           encap;
    logic [15:0]          node_cnt;
    logic                 done;
    logic signed [31:0]   code;
    logic [PC_W-1:0]      next_pc;
  } pstate_t;

  // ---- sub-register width helpers (parser.c) ----
  // general (extract/compare/cam/store): width = (sz==0)?4:(8<<(sz-1))  n/b/h/w
  function automatic int unsigned subreg_width(input logic [1:0] sz);
    return (sz == 2'd0) ? 4 : (8 << (sz - 1));
  endfunction
  // load/store byte count: (sz==0)?8:(1<<(sz-1))  dword/byte/half/word
  function automatic int unsigned load_nbytes(input logic [1:0] sz);
    return (sz == 2'd0) ? 8 : (1 << (sz - 1));
  endfunction

  // bswap_n (parser.c): reverse the low n bytes of v (n..8).
  function automatic logic [63:0] bswap_n(input logic [63:0] v, input int unsigned n);
    logic [63:0] r;
    logic [63:0] t;
    r = 64'h0;
    t = v;
    for (int i = 0; i < 8; i++) begin
      if (i < n) begin
        r = (r << 8) | (t & 64'hFF);
        t = t >> 8;
      end
    end
    return r;
  endfunction

  // pm_extract_subreg (parser.c): MSB-first sub-register numbering.
  function automatic logic [63:0] extract_subreg(input logic [63:0] val,
                                                  input logic [1:0]  sz,
                                                  input logic [3:0]  pos);
    int unsigned width;
    int unsigned shift;
    logic [63:0] m;
    width = subreg_width(sz);
    shift = 64 - width - pos * width;
    m     = (width >= 64) ? {64{1'b1}} : ((64'd1 << width) - 64'd1);
    return (val >> shift) & m;
  endfunction

endpackage : parser_pkg
