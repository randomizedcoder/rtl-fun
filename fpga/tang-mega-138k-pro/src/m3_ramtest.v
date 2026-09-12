//
// fpga/tang-mega-138k-pro/src/m3_ramtest.v — minimal BSRAM-inference reproducer for M3a
// challenge #16. This is the ACTIVE CVA6 L1 cache RAM leaf, `tc_sram_wrapper`, reduced to
// a standalone module: exactly the sv2v output of the leaf CVA6's WT cache instantiates
// (cfg cv64a6_imafdc_sv39, TechnoCut=0 -> sram_cache -> sram.sv -> tc_sram_wrapper), with
// nothing else. Registered read, per-byte write-enable, no reset, no init — the textbook
// single-port block-RAM style.
//
// Why it exists. On the full 74k-line CVA6 netlist GowinSynthesis inferred ZERO BSRAM and
// demoted ~543 Kbit of cache/tag memory to flip-flops (558,788 DFF > 139,140 -> RP0001; a
// ~24 h run). This module reproduces that demotion in ~1 s, and lets the fix be proven the
// same way, so neither has to be chased through a full-CVA6 synth. Driven by
// `nix run .#fpga-m3-core-rtl -- diag` (the yosys side) and
// `nix run .#fpga-build -- m3-ramtest` (the Gowin side); full write-up in
// docs/gowin-bsram-inference-debug.md.
//
// The diag flow instantiates it as a 256x64 single-port RAM (NumPorts=1) — one D$ data
// bank — via -chparam, matching the geometry that yosys 0.68 maps to 2 gw5a SPX9 cells.
//
module tc_sram_wrapper (
	clk_i,
	rst_ni,
	req_i,
	we_i,
	addr_i,
	wdata_i,
	be_i,
	rdata_o
);
	parameter [31:0] NumWords = 32'd1024;
	parameter [31:0] DataWidth = 32'd128;
	parameter [31:0] ByteWidth = 32'd8;
	parameter [31:0] NumPorts = 32'd2;
	parameter [31:0] Latency = 32'd1;
	parameter SimInit = "none";
	parameter [0:0] PrintSimCfg = 1'b0;
	parameter [31:0] AddrWidth = (NumWords > 32'd1 ? $clog2(NumWords) : 32'd1);
	parameter [31:0] BeWidth = ((DataWidth + ByteWidth) - 32'd1) / ByteWidth;
	input wire clk_i;
	input wire rst_ni;
	input wire [NumPorts - 1:0] req_i;
	input wire [NumPorts - 1:0] we_i;
	input wire [(NumPorts * AddrWidth) - 1:0] addr_i;
	input wire [(NumPorts * DataWidth) - 1:0] wdata_i;
	input wire [(NumPorts * BeWidth) - 1:0] be_i;
	output wire [(NumPorts * DataWidth) - 1:0] rdata_o;
	reg [DataWidth - 1:0] mem [NumWords - 1:0];
	genvar _gv_p_1;
	function automatic signed [31:0] sv2v_cast_32_signed;
		input reg signed [31:0] inp;
		sv2v_cast_32_signed = inp;
	endfunction
	generate
		for (_gv_p_1 = 0; _gv_p_1 < sv2v_cast_32_signed(NumPorts); _gv_p_1 = _gv_p_1 + 1) begin : gen_port
			localparam p = _gv_p_1;
			reg [DataWidth - 1:0] rdata_q;
			always @(posedge clk_i)
				if (req_i[p]) begin
					if (we_i[p]) begin : sv2v_autoblock_1
						reg [31:0] b;
						for (b = 0; b < BeWidth; b = b + 1)
							if (be_i[(p * BeWidth) + b])
								mem[addr_i[p * AddrWidth+:AddrWidth]][b * ByteWidth+:ByteWidth] <= wdata_i[(p * DataWidth) + (b * ByteWidth)+:ByteWidth];
					end
					else
						rdata_q <= mem[addr_i[p * AddrWidth+:AddrWidth]];
				end
			assign rdata_o[p * DataWidth+:DataWidth] = rdata_q;
		end
	endgenerate
endmodule
