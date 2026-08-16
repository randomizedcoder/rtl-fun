// parser_decode.sv — 32-bit Phase-3 instruction word -> micro_op_t (Phase 5 §5.2).
//
// This is the CVA6 decode path: it turns a custom-0 parser instruction word (the
// bit-accurate Phase-3 encoding) into the decoded micro-op the executor runs. It
// is the RTL twin of model/libparsermodel/encoding.c (pm_decode_opcode + the
// per-group field extraction) and of the machine-readable table
// isa/parser-opcodes.yaml — the same bit positions, so bits never drift between
// the model, the assembler, and the silicon.
//
// Combinational and pure (word -> micro-op). CAM/next TARGETS are NOT in the
// instruction word — they live in the CAM table (parser_cam) and are resolved at
// run time — so this decoder produces every micro-op field EXCEPT the CAM target,
// exactly as parser_execute expects (the target arrives on cam_target_i).
//
// Bit numbering is LSB0 (bit 0 = LSB), matching encoding.c and the yaml. A field
// the recovered patent doc draws [hi:lo] occupies the same hi..lo bits here.

module parser_decode
  import parser_pkg::*;
(
    input  logic [31:0] word_i,
    output micro_op_t   op_o,
    output logic        illegal_o   // opcode/Fnc4 not in the slice ISA
);

  // ---- framing (isa/parser-opcodes.yaml: framing) ----
  localparam logic [6:0] OPCODE_C0 = 7'h0B;   // custom-0: 32-bit parser instrs
  localparam logic [6:0] OPCODE_C3 = 7'h7B;   // custom-3: parser coprocessor moves

  // ---- Fnc4 group map (encoding.h enum prs_fnc4 / yaml fnc4_map) ----
  localparam logic [3:0] FNC4_LOAD    = 4'h0;
  localparam logic [3:0] FNC4_LEN     = 4'h2;
  localparam logic [3:0] FNC4_STORE   = 4'h4;
  localparam logic [3:0] FNC4_STOREIMM= 4'h6;
  localparam logic [3:0] FNC4_CAM     = 4'h8;
  localparam logic [3:0] FNC4_NEXT    = 4'hA;
  localparam logic [3:0] FNC4_CMPORD  = 4'hB;
  localparam logic [3:0] FNC4_CMPIB   = 4'hD;
  localparam logic [3:0] FNC4_CMPNEIB = 4'hE;

  // Pos discriminator inside the NEXT group (yaml groups.next.discriminator).
  localparam logic [1:0] NEXT_POS_NEXTNODE = 2'd0;
  localparam logic [1:0] NEXT_POS_SETCODE  = 2'd2;   // V=0 => PSETCODE, V=1 => PSTP

  logic [6:0] opcode;
  logic [3:0] fnc4;
  assign opcode = word_i[6:0];
  assign fnc4   = word_i[10:7];

  always_comb begin
    micro_op_t m;
    logic [1:0] next_pos;

    // defaults: a NOP-ish micro-op; illegal unless a group claims the word.
    m         = '0;
    m.op      = OP_INITPARSER;
    illegal_o = 1'b1;

    if (opcode == OPCODE_C0) begin
      unique case (fnc4)

        // ---- PLOAD (yaml groups.load) ----
        // X[31] D[30] Sz[29:28] Blen[27:24] Shift[23:21] E[20] Offset[19:11]
        FNC4_LOAD: begin
          m.op     = OP_LOAD;
          m.x      = word_i[31];
          m.d      = word_i[30];
          m.sz     = word_i[29:28];
          m.blen   = word_i[27:24];
          m.shift  = word_i[23:21];
          m.e      = word_i[20];
          m.offset = word_i[19:11];
          illegal_o = 1'b0;
        end

        // ---- PLENCUR (yaml groups.length; F2=0 in the slice) ----
        // S[31] D[30] Sz[29:28] Pos[27:24] Shift[23:21] F2[20:19] Len[18:11]
        FNC4_LEN: begin
          m.op     = OP_LENCUR;
          m.s      = word_i[31];
          m.d      = word_i[30];
          m.sz     = word_i[29:28];
          m.pos    = word_i[27:24];
          m.shift  = word_i[23:21];
          m.value  = {8'h0, word_i[18:11]};   // Len -> the min/const length
          illegal_o = 1'b0;
        end

        // ---- PSTORE (yaml groups.store) ----
        // S[31] F[30] Sz[29:28] Pos[27:24] J[23] Sind[22:20] Offset[19:11]
        FNC4_STORE: begin
          m.op     = OP_STORE;
          m.s      = word_i[31];
          m.f      = word_i[30];
          m.sz     = word_i[29:28];
          m.pos    = word_i[27:24];
          m.j      = word_i[23];
          m.offset = word_i[19:11];
          illegal_o = 1'b0;
        end

        // ---- PSTOREIMM (yaml groups.storeimm) ----
        // S[31] F[30] Sz[29:28] Value[27:20] Offset[19:11]
        FNC4_STOREIMM: begin
          m.op     = OP_STOREIMM;
          m.s      = word_i[31];
          m.f      = word_i[30];
          m.sz     = word_i[29:28];
          m.value  = {8'h0, word_i[27:20]};
          m.offset = word_i[19:11];
          illegal_o = 1'b0;
        end

        // ---- PCAM / PCAMNEXT (yaml groups.cam; D bit selects) ----
        // S[31] D[30] Sz[29:28] Pos[27:24] Func3[23:21] F[20] Share[19:16] Miss[15:11]
        // Func3 is 3 bits but the model uses only 0..3 (2 bits); Miss is a 5-bit
        // field but the dispositions are 0..5 (3 bits) — take the low bits.
        FNC4_CAM: begin
          m.op     = word_i[30] ? OP_CAMNEXT : OP_CAM;
          m.s      = word_i[31];
          m.d      = word_i[30];
          m.sz     = word_i[29:28];
          m.pos    = word_i[27:24];
          m.func3  = word_i[22:21];
          m.f      = word_i[20];
          m.share  = word_i[19:16];
          m.miss   = word_i[13:11];
          illegal_o = 1'b0;
        end

        // ---- PNEXTNODE / PSETCODE / PSTP (yaml groups.next) ----
        // S[31] V[30] Pos[29:28] A[27] Payload[26:11]
        FNC4_NEXT: begin
          next_pos = word_i[29:28];
          m.s      = word_i[31];
          m.payload= signed'(word_i[26:11]);
          unique case (next_pos)
            NEXT_POS_NEXTNODE: begin
              m.op    = OP_NEXTNODE;
              // overlay: the executor keys on value!=0 (model carries V here).
              m.value = {15'h0, word_i[30]};
              illegal_o = 1'b0;
            end
            NEXT_POS_SETCODE: begin
              // V=1 marks PSTP (end-of-node); V=0 marks PSETCODE (set exit code).
              m.op    = word_i[30] ? OP_STP : OP_SETCODE;
              illegal_o = 1'b0;
            end
            default: ;   // PSETIMM / PVARINT — deferred (not in the slice ISA)
          endcase
        end

        // ---- PCMPI{LT,LE,GT,GE}B ordered byte (yaml groups.cmp_ordered) ----
        // S[31] D[30] Sz[29:28] Pos[27:24] Func3[23:21] Er[20:19] Value[18:11]
        FNC4_CMPORD: begin
          m.op     = OP_CMPORD;
          m.s      = word_i[31];
          m.d      = word_i[30];
          m.sz     = word_i[29:28];
          m.pos    = word_i[27:24];
          m.func3  = word_i[22:21];
          m.er     = word_i[20:19];
          m.value  = {8'h0, word_i[18:11]};
          illegal_o = 1'b0;
        end

        // ---- PCMPIB / PCMPNEIB masked byte (yaml groups.cmp_masked_byte) ----
        // Er[31:30] Pos[29:27] Value[26:19] Mask[18:11]
        FNC4_CMPIB, FNC4_CMPNEIB: begin
          m.op     = (fnc4 == FNC4_CMPNEIB) ? OP_CMPINEB : OP_CMPIB;
          m.er     = word_i[31:30];
          m.pos    = {1'b0, word_i[29:27]};
          m.value  = {8'h0, word_i[26:19]};
          m.mask   = word_i[18:11];
          illegal_o = 1'b0;
        end

        default: ;   // FLAGSLOOP / EXTRACT / ARR / CMPIH / LIFECYCLE — deferred
      endcase
    end else if (opcode == OPCODE_C3) begin
      // ---- custom-3 parser coprocessor R-form (patent-encodings §2.2, FIG 43/44)
      // CoP[31:29]=000 Cpreg[28:24] C[23] S[22] I[21] R[20] Rs[19:15] Func3[14:12] Rd[11:7]
      // CPPRSRD (`prs.mv.x.p ireg,preg`, read p->int): CoP=000, S=I=R=0, Func3=000.
      // Cpreg selects the parser register; Rd (captured by the CVA6 decoder) is the
      // integer destination. Other custom-3 forms (write/imm/CAM/array) are deferred.
      if ((word_i[31:29] == 3'b000) &&        // CoP = parser coprocessor
          (word_i[22:20] == 3'b000) &&        // S=0, I=0, R=0  (register-move read)
          (word_i[14:12] == 3'b000)) begin    // Func3 = 000    (read, not write)
        m.rd_preg = 1'b1;
        m.cpreg   = word_i[28:24];
        illegal_o = 1'b0;
      end
    end

    op_o = m;
  end

endmodule : parser_decode
