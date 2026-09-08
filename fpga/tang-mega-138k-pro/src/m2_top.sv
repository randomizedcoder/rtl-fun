//
// m2_top.sv — Phase 8 milestone M2: host -> FPGA packet injection.
//
// M1 baked ONE packet into ROM. M2 receives an arbitrary packet from the host over
// an external 3.3 V USB-UART (PMOD2: uart_rx C21, uart_tx B20 — the USB debug UART's
// RX is CPU-locked, see docs), loads it into the parser's packet buffer, runs the
// SAME parse graph (program + CAM stay baked in ROM — they are identical across all
// 22 suite cases; only the packet differs), and streams the resulting flow_keys back.
// The host (nix run .#fpga-m2-inject) drives the whole 22-case suite this way and
// diffs each result against libparsermodel — the Phase-6 oracle over a real wire.
//
// Wire framing, host -> FPGA (little on the wire, robust to resync on 0x7E):
//   0x7E  plen_hi plen_lo  nbuf_hi nbuf_lo  <nbuf packet bytes>
//   plen = the true packet length -> parse_len_i (may exceed the buffer)
//   nbuf = number of buffer bytes that follow (<= PKT_MAX); byte i -> pktbuf[i]
//
// Reply, FPGA -> host (identical to M1's line so the oracle/parse is shared):
//   FK <96 hex = 48 flow_keys bytes> <8 hex exit code> <4 hex seq>\r\n
// exactly one line per injected packet (no free-running repeat — the seq counts
// packets so the host can tell replies apart).
//
// The parser core is held in reset while a packet loads (pktbuf's write port is
// independent of rst_ni), then released to run; on completion the metadata RAM holds
// flow_keys, which the emitter reads back. ROM paths are GUEST paths (/work, 9p).
//
import parser_pkg::*;

module m2_top (
    input        clk,
    input        uart_rx_pin,
    output       uart_tx_pin,
    output [5:0] led
);

  localparam int unsigned CLK_HZ  = 50_000_000;
  localparam int unsigned BAUD    = 115_200;
  localparam int unsigned META_LEN  = 48;                // sizeof(struct flow_keys)
  localparam [5:0]        META_LAST = 6'(META_LEN - 1);
  localparam logic signed [31:0] EXP_CODE = -32'sd4;     // P_STOP_OKAY (baseline)
  localparam byte unsigned SYNC = 8'h7E;

  // Program + CAM are the shared parse graph (same file M1 bakes); no packet ROM.
  localparam string ROM = "/work/fpga/tang-mega-138k-pro/roms/m1";

  // ---- power-on reset for this module's own logic ----
  reg [3:0] por = 4'd0;
  wire      por_done = &por;
  always @(posedge clk) if (!por_done) por <= por + 4'd1;

  // ---- UART receiver + transmitter ----
  wire [7:0] rx_data;
  wire       rx_valid;
  uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
      .clk(clk), .rx(uart_rx_pin), .data(rx_data), .valid(rx_valid));

  reg  [7:0] ch;
  reg        send;
  wire       tx_busy;
  uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
      .clk(clk), .data(ch), .send(send), .busy(tx_busy), .tx(uart_tx_pin));

  // ---- packet load registers (drive parser_top's injection write port) ----
  reg                   pkt_wr_en;
  reg [PKT_OFF_W-1:0]   pkt_wr_addr;
  reg [7:0]             pkt_wr_be;
  reg [63:0]            pkt_wr_data;
  reg [15:0]            plen;          // -> parse_len_i
  reg [15:0]            nbuf;          // buffer bytes to load
  reg [15:0]            widx;          // load / running index

  // ---- the parser datapath; held in reset until a packet is loaded ----
  wire               done;
  wire signed [31:0] code;
  wire [7:0]         meta_rdata;
  reg  [META_OFF_W-1:0] meta_raddr;
  reg                parser_run;       // 1 => release parser reset and run/stream
  wire               parser_rst_ni = por_done & parser_run;

  parser_top #(
      .PROG_FILE ({ROM, "/program.hex"}),
      .CAM_FILE  ({ROM, "/cam.hex"}),
      .PKT_FILE  (""),                 // no ROM packet: injected over UART
      .ENC_FILE  (""),
      .USE_DECODE(1'b0)
  ) u_parser (
      .clk_i       (clk),
      .rst_ni      (parser_rst_ni),
      .parse_len_i (plen),
      .meta_raddr_i(meta_raddr),
      .meta_rdata_o(meta_rdata),
      .done_o      (done),
      .code_o      (code),
      .busy_o      (/* unused */),
      .pkt_wr_en_i  (pkt_wr_en),
      .pkt_wr_addr_i(pkt_wr_addr),
      .pkt_wr_be_i  (pkt_wr_be),
      .pkt_wr_data_i(pkt_wr_data)
  );

  reg signed [31:0] code_q = '0;

  function automatic [7:0] hexchar(input [3:0] n);
    hexchar = (n < 4'd10) ? (8'd48 + {4'd0, n}) : (8'd87 + {4'd0, n});
  endfunction

  // ---- one flat FSM: receive frame -> run -> emit one FK line -> re-arm ----
  localparam [4:0]
    S_SYNC = 5'd0,  S_PLENH = 5'd1, S_PLENL = 5'd2, S_NBUFH = 5'd3, S_NBUFL = 5'd4,
    S_DATA = 5'd5,  S_FLUSH = 5'd6, S_RUN   = 5'd7,
    // emitter (mirrors m1_top): F K SP0 <data> SP1 <code> SP2 <seq> CR LF
    E_F    = 5'd8,  E_K = 5'd9,  E_SP0 = 5'd10, E_DATA = 5'd11, E_SP1 = 5'd12,
    E_CODE = 5'd13, E_SP2 = 5'd14, E_SEQ = 5'd15, E_CR = 5'd16, E_LF = 5'd17;

  reg [4:0]  st   = S_SYNC;
  reg [1:0]  ss   = 2'd0;          // TX handshake sub-state
  reg [5:0]  bidx = 6'd0;          // flow_keys byte index
  reg        nib  = 1'b0;
  reg [2:0]  cnib = 3'd0;
  reg [1:0]  snib = 2'd0;
  reg [15:0] seq  = 16'd0;

  wire emitting = (st >= E_F);     // in a character-emitting phase

  always @(*) meta_raddr = {{(META_OFF_W-6){1'b0}}, bidx};

  // combinational char select for the current emitter phase
  always @(*) begin
    case (st)
      E_F:    ch = "F";
      E_K:    ch = "K";
      E_SP0:  ch = " ";
      E_DATA: ch = nib ? hexchar(meta_rdata[3:0]) : hexchar(meta_rdata[7:4]);
      E_SP1:  ch = " ";
      E_CODE: ch = hexchar(code_q[(3'd7 - cnib)*4 +: 4]);
      E_SP2:  ch = " ";
      E_SEQ:  ch = hexchar(seq[(2'd3 - snib)*4 +: 4]);
      E_CR:   ch = 8'd13;
      default:ch = 8'd10;          // E_LF
    endcase
  end

  task automatic emit_next;        // advance emitter phase after a char is accepted
    case (st)
      E_F:    st <= E_K;
      E_K:    st <= E_SP0;
      E_SP0:  st <= E_DATA;
      E_DATA: begin
        if (!nib) nib <= 1'b1;
        else begin
          nib <= 1'b0;
          if (bidx == META_LAST) begin bidx <= 6'd0; st <= E_SP1; end
          else bidx <= bidx + 6'd1;
        end
      end
      E_SP1:  st <= E_CODE;
      E_CODE: begin
        if (cnib == 3'd7) begin cnib <= 3'd0; st <= E_SP2; end
        else cnib <= cnib + 3'd1;
      end
      E_SP2:  st <= E_SEQ;
      E_SEQ:  begin
        if (snib == 2'd3) begin snib <= 2'd0; st <= E_CR; end
        else snib <= snib + 2'd1;
      end
      E_CR:   st <= E_LF;
      E_LF:   begin seq <= seq + 16'd1; st <= S_SYNC; end   // one line, then re-arm
      default: ;
    endcase
  endtask

  always @(posedge clk) begin
    send      <= 1'b0;
    pkt_wr_en <= 1'b0;
    if (!por_done) begin
      st <= S_SYNC; ss <= 2'd0; parser_run <= 1'b0; widx <= 16'd0;
    end else if (done && (st == S_RUN)) begin
      code_q <= code; st <= E_F;               // parse finished: start the reply line
    end else begin
      case (st)
        // ---- receive the framed packet (parser held in reset) ----
        S_SYNC:  begin parser_run <= 1'b0;
                       if (rx_valid && rx_data == SYNC) st <= S_PLENH; end
        S_PLENH: if (rx_valid) begin plen[15:8] <= rx_data; st <= S_PLENL; end
        S_PLENL: if (rx_valid) begin plen[7:0]  <= rx_data; st <= S_NBUFH; end
        S_NBUFH: if (rx_valid) begin nbuf[15:8] <= rx_data; st <= S_NBUFL; end
        S_NBUFL: if (rx_valid) begin
                   nbuf[7:0] <= rx_data;
                   widx <= 16'd0;
                   st <= ({nbuf[15:8], rx_data} == 16'd0) ? S_FLUSH : S_DATA;
                 end
        S_DATA:  if (rx_valid) begin
                   // write byte i -> pktbuf[i]; ignore anything past the buffer but
                   // still consume it to stay frame-aligned.
                   if (widx < PKT_MAX[15:0]) begin
                     pkt_wr_en   <= 1'b1;
                     pkt_wr_addr <= widx[PKT_OFF_W-1:0];
                     pkt_wr_be   <= 8'h01;
                     pkt_wr_data <= {56'h0, rx_data};
                   end
                   widx <= widx + 16'd1;
                   if (widx + 16'd1 == nbuf) st <= S_FLUSH;
                 end
        S_FLUSH: st <= S_RUN;                   // let the last write commit
        S_RUN:   parser_run <= 1'b1;            // release reset; wait for done (above)

        // ---- emit exactly one FK line, then re-arm ----
        default: begin
          if (ss == 2'd0) begin
            if (!tx_busy) begin send <= 1'b1; ss <= 2'd1; end
          end else begin
            if (tx_busy) begin ss <= 2'd0; emit_next(); end
          end
        end
      endcase
    end
  end

  // Active-low status LEDs:
  //   led[0] = last parse done (a reply was produced)
  //   led[1] = last parse code matched the baseline expected code
  //   led[5:2] = low seq nibble (ticks once per injected packet)
  assign led = ~{seq[3:0], (code_q == EXP_CODE), (st >= E_F) || (seq != 0)};

endmodule
