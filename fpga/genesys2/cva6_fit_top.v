// fpga/genesys2/cva6_fit_top.v
//
// Register-ring harness around stock CVA6 (cv64a6_imafdc_sv39) for the
// open-source (openXC7) verify-before-buy fit check on Xilinx 7-series
// (xc7k325t / Digilent Genesys 2). See nix/fpga-m3-xilinx.nix and
// docs/phase-8-status.md §"M3a — fit verdict".
//
// Why a harness: the stock `cva6` core exposes 8347 IO bits (rvfi_probes_o
// 6905, noc_req_o 470, cvxif_req_o 449, ...), far more than the ~500 usable
// package pins, so the raw core cannot be placed & routed standalone. This
// harness collapses all functional IO down to 4 device pins:
//
//   * clk_i, rst_ni  -> real device pins
//   * din            -> single serial input, fanned through a shift ring into
//                       EVERY core input register, so nothing constant-folds away
//   * dout           -> single registered output, XOR-reduction of the real
//                       core outputs (cvxif_req_o, noc_req_o)
//
// rvfi_probes_o is left UNCONNECTED on purpose: it is a verification-only trace
// port that CVA6's real corev_apu/fpga SoC does not build, so letting DCE prune
// its logic cone yields the deployment-faithful LUT6/FF footprint, not an
// inflated one.
//
// This is a fit/route harness, NOT a functional SoC: the ring feedback is
// arbitrary; it exists solely to keep the core's logic live and observable so
// synth_xilinx + nextpnr-xilinx report a real utilization and Fmax.
//
// Port widths are the concrete widths of the elaborated cv64a6_imafdc_sv39
// core (build/fpga-m3-core-rtl/elab.il, module \cva6). If the CVA6 config
// changes, re-check them against that checkpoint.

module cva6_fit_top (
    input  wire clk_i,
    input  wire rst_ni,
    input  wire din,
    output reg  dout
);
    // ---- input-side registers (all core inputs), driven from din via a ring ----
    reg [63:0]  boot_addr_q;
    reg [63:0]  hart_id_q;
    reg [1:0]   irq_q;
    reg         ipi_q;
    reg         time_irq_q;
    reg         debug_req_q;
    reg [177:0] cvxif_resp_q;
    reg [209:0] noc_resp_q;

    wire [448:0] cvxif_req_o;
    wire [469:0] noc_req_o;
    // rvfi_probes_o intentionally left dangling (pruned).

    // Ring: shift din through every input bit so none are constant.
    // Feedback from the reduced outputs keeps the whole cone observable/live.
    wire fb = ^cvxif_req_o ^ (^noc_req_o);

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            boot_addr_q  <= 64'd0;
            hart_id_q    <= 64'd0;
            irq_q        <= 2'd0;
            ipi_q        <= 1'b0;
            time_irq_q   <= 1'b0;
            debug_req_q  <= 1'b0;
            cvxif_resp_q <= 178'd0;
            noc_resp_q   <= 210'd0;
            dout         <= 1'b0;
        end else begin
            boot_addr_q  <= {boot_addr_q[62:0], din};
            hart_id_q    <= {hart_id_q[62:0], boot_addr_q[63]};
            irq_q        <= {irq_q[0], hart_id_q[63]};
            ipi_q        <= irq_q[1];
            time_irq_q   <= ipi_q;
            debug_req_q  <= time_irq_q;
            cvxif_resp_q <= {cvxif_resp_q[176:0], debug_req_q ^ fb};
            noc_resp_q   <= {noc_resp_q[208:0], cvxif_resp_q[177]};
            dout         <= fb;
        end
    end

    cva6 u_cva6 (
        .clk_i        (clk_i),
        .rst_ni       (rst_ni),
        .boot_addr_i  (boot_addr_q),
        .hart_id_i    (hart_id_q),
        .irq_i        (irq_q),
        .ipi_i        (ipi_q),
        .time_irq_i   (time_irq_q),
        .debug_req_i  (debug_req_q),
        .rvfi_probes_o(/* unconnected: pruned */),
        .cvxif_req_o  (cvxif_req_o),
        .cvxif_resp_i (cvxif_resp_q),
        .noc_req_o    (noc_req_o),
        .noc_resp_i   (noc_resp_q)
    );
endmodule
