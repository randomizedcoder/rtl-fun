//
// m1_top.sv — Phase 8 milestone M1: the parser unit alone on the Tang Mega 138K Pro.
//
// Proves *our* RTL runs on real silicon, independently of the CPU, MAC and DDR.
// It instantiates the existing standalone parser datapath (tb/parser_top.sv — a
// micro-PC + program ROM driving parser_execute/parser_pktbuf/parser_cam, i.e. a
// hardware pm_run), feeds it ONE Ethernet packet baked into on-chip ROM, runs the
// parse once at power-on, and then streams the resulting flow_keys out over the M0
// UART (P15) forever. The host (nix run .#fpga-m1-check) diffs the bytes against
// libparsermodel's expected.hex — the identical Phase-6 oracle, transport swapped
// from Verilator DPI to a wire.
//
// ROM images come from the golden model via `nix run .#fpga-m1-roms` and are read
// by $readmemh at elaboration (parser_top's PROG_FILE / CAM_FILE / PKT_FILE). The
// paths below are GUEST paths: the microVM 9p-mounts the repo at /work.
//
// Board facts (docs/fpga-bringup-tang-mega-138k-pro.md):
//   clk       P16, 50 MHz
//   uart_tx   P15   (FPGA -> debugger -> host /dev/ttyUSB1)
//   led[5:0]  N23 N21 M25 L20 R26 J14, ACTIVE LOW
//
// UART line, emitted ~twice a second (repeating so the host can lock the baud and
// so a live, changing seq counter proves the design is running, per the M0 lesson).
// Three space-separated fields after the "FK" tag:
//   FK <96 hex chars = 48 flow_keys bytes> <8 hex exit code> <4 hex seq>\r\n
// e.g.  FK 0008060401...5678 fffffffc 0003
//
import parser_pkg::*;

module m1_top (
    input        clk,
    output [5:0] led,
    output       uart_tx_pin
);

  // ---- design parameters (from the model: params.hex = PKT_LEN, META_LEN, EXP_CODE) ----
  localparam int unsigned CLK_HZ   = 50_000_000;
  localparam int unsigned BAUD     = 115_200;
  localparam int unsigned GAP_DIV  = 25_000_000;        // ~0.5 s between lines
  localparam logic [15:0] PKT_LEN  = 16'd54;            // baseline eth/ipv4/tcp
  localparam int unsigned META_LEN  = 48;               // sizeof(struct flow_keys)
  localparam [5:0]        META_LAST = 6'(META_LEN - 1);  // last byte index (width-matched)
  localparam logic signed [31:0] EXP_CODE = -32'sd4;    // P_STOP_OKAY

  localparam string ROM = "/work/fpga/tang-mega-138k-pro/roms/m1";

  // ---- power-on reset: hold parser_top in reset for 16 cycles, then run ----
  reg [3:0] por = 4'd0;
  wire      rst_ni = &por;
  always @(posedge clk) if (!rst_ni) por <= por + 4'd1;

  // ---- the parser datapath (hardware pm_run) ----
  wire                    done;
  wire signed [31:0]      code;
  wire [7:0]              meta_rdata;
  reg  [META_OFF_W-1:0]   meta_raddr;

  parser_top #(
      .PROG_FILE ({ROM, "/program.hex"}),
      .CAM_FILE  ({ROM, "/cam.hex"}),
      .PKT_FILE  ({ROM, "/pktbuf.hex"}),
      .ENC_FILE  (""),
      .USE_DECODE(1'b0)
  ) u_parser (
      .clk_i       (clk),
      .rst_ni      (rst_ni),
      .parse_len_i (PKT_LEN),
      .meta_raddr_i(meta_raddr),
      .meta_rdata_o(meta_rdata),
      .done_o      (done),
      .code_o      (code),
      .busy_o      (/* unused */)
  );

  // latch the exit code once the parse finishes (it is sticky, but latch for LEDs)
  reg signed [31:0] code_q = '0;
  reg               done_q = 1'b0;
  always @(posedge clk) begin
    if (done && !done_q) code_q <= code;
    done_q <= done;
  end

  // ---- UART transmitter (reused M0 module, plain Verilog-2001) ----
  reg  [7:0] ch;
  reg        send;
  wire       busy;
  uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
      .clk (clk), .data(ch), .send(send), .busy(busy), .tx(uart_tx_pin));

  function automatic [7:0] hexchar(input [3:0] n);
    hexchar = (n < 4'd10) ? (8'd48 + {4'd0, n}) : (8'd87 + {4'd0, n});
  endfunction

  // ---- line-emitter phases ----
  localparam [3:0] P_WAIT = 4'd0,  // wait for the parse to finish
                   P_F    = 4'd1, P_K = 4'd2, P_SP0 = 4'd3,
                   P_DATA = 4'd4,  // META_LEN bytes, 2 hex nibbles each
                   P_SP1  = 4'd5,  P_CODE = 4'd6, P_SP2 = 4'd7,
                   P_SEQ  = 4'd8,  P_CR = 4'd9, P_LF = 4'd10, P_GAP = 4'd11;

  reg [3:0]  ph   = P_WAIT;
  reg [1:0]  ss   = 2'd0;          // handshake sub-state: 0 offer, 1 wait-accept
  reg [5:0]  bidx = 6'd0;          // byte index 0..META_LEN-1
  reg        nib  = 1'b0;          // 0 = high nibble, 1 = low nibble
  reg [2:0]  cnib = 3'd0;          // code nibble 0..7 (MSB first)
  reg [1:0]  snib = 2'd0;          // seq  nibble 0..3 (MSB first)
  reg [15:0] seq  = 16'd0;
  reg [31:0] gap  = 32'd0;

  // meta read address tracks the byte being emitted in P_DATA
  always @(*) meta_raddr = {{(META_OFF_W-6){1'b0}}, bidx};

  // combinational character select for the current phase/index
  always @(*) begin
    case (ph)
      P_F:    ch = "F";
      P_K:    ch = "K";
      P_SP0:  ch = " ";
      P_DATA: ch = nib ? hexchar(meta_rdata[3:0]) : hexchar(meta_rdata[7:4]);
      P_SP1:  ch = " ";
      P_CODE: ch = hexchar(code_q[(3'd7 - cnib)*4 +: 4]);
      P_SP2:  ch = " ";
      P_SEQ:  ch = hexchar(seq[(2'd3 - snib)*4 +: 4]);
      P_CR:   ch = 8'd13;
      default:ch = 8'd10;   // P_LF
    endcase
  end

  // advance to the next phase once the current char has been accepted
  task automatic next_phase;
    case (ph)
      P_F:    ph <= P_K;
      P_K:    ph <= P_SP0;
      P_SP0:  ph <= P_DATA;
      P_DATA: begin
        if (!nib) nib <= 1'b1;
        else begin
          nib <= 1'b0;
          if (bidx == META_LAST) begin bidx <= 6'd0; ph <= P_SP1; end
          else bidx <= bidx + 6'd1;
        end
      end
      P_SP1:  ph <= P_CODE;
      P_CODE: begin
        if (cnib == 3'd7) begin cnib <= 3'd0; ph <= P_SP2; end
        else cnib <= cnib + 3'd1;
      end
      P_SP2:  ph <= P_SEQ;
      P_SEQ:  begin
        if (snib == 2'd3) begin snib <= 2'd0; ph <= P_CR; end
        else snib <= snib + 2'd1;
      end
      P_CR:   ph <= P_LF;
      P_LF:   begin seq <= seq + 16'd1; ph <= P_GAP; end
      default: ;
    endcase
  endtask

  always @(posedge clk) begin
    send <= 1'b0;
    if (!rst_ni) begin
      ph <= P_WAIT; ss <= 2'd0;
    end else begin
      case (ph)
        P_WAIT: if (done) ph <= P_F;   // parse finished: start streaming
        P_GAP:  begin
          if (gap >= GAP_DIV - 1) begin gap <= 32'd0; ph <= P_F; end
          else gap <= gap + 32'd1;
        end
        default: begin                 // a character-emitting phase: run the handshake
          if (ss == 2'd0) begin
            if (!busy) begin send <= 1'b1; ss <= 2'd1; end
          end else begin
            if (busy) begin ss <= 2'd0; next_phase(); end
          end
        end
      endcase
    end
  end

  // Active-low status LEDs: liveness + a correctness tell, cross-checkable with UART.
  //   led[0] = parse done
  //   led[1] = parse code matched the model's expected code
  //   led[5:2] = low SEQ nibble (visibly ticking ~twice a second)
  assign led = ~{seq[3:0], (code_q == EXP_CODE), done_q};

endmodule
