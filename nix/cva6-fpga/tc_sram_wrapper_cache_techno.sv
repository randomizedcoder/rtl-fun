// Copyright 2022 Thales DIS design services SAS
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
//
// Original Author: Jean-Roch COULON - Thales
//
// Copy of tc_sram_wrapper_cache
// To be replaced by the wrapper of the technology used to avoid having black box at synthesis
//
// PHASE-8 M3a EDIT (rtl-fun): filled from its upstream empty stub with the same
// SYNCHRONOUS-READ, byte-write-enable block-RAM template as tc_sram_wrapper.sv (registered
// read -> stays a $mem cell -> GowinSynthesis infers BSRAM; an async-read array would be
// demoted to flip-flops, challenge #16). BYTE_ACCESS is a cache-techno hint with no effect
// on this generic RAM, so it is accepted and unused. See tc_sram_wrapper.sv for details.

module tc_sram_wrapper_cache_techno #(
  parameter int unsigned NumWords     = 32'd1024,
  parameter int unsigned DataWidth    = 32'd128,
  parameter int unsigned ByteWidth    = 32'd8,
  parameter int unsigned NumPorts     = 32'd2,
  parameter int unsigned Latency      = 32'd1,
  parameter              SimInit      = "none",
  parameter              BYTE_ACCESS  = 1,
  parameter bit          PrintSimCfg  = 1'b0,
  // DEPENDENT PARAMETERS, DO NOT OVERWRITE!
  parameter int unsigned AddrWidth = (NumWords > 32'd1) ? $clog2(NumWords) : 32'd1,
  parameter int unsigned BeWidth   = (DataWidth + ByteWidth - 32'd1) / ByteWidth,
  parameter type         addr_t    = logic [AddrWidth-1:0],
  parameter type         data_t    = logic [DataWidth-1:0],
  parameter type         be_t      = logic [BeWidth-1:0]
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic  [NumPorts-1:0] req_i,
  input  logic  [NumPorts-1:0] we_i,
  input  addr_t [NumPorts-1:0] addr_i,
  input  data_t [NumPorts-1:0] wdata_i,
  input  be_t   [NumPorts-1:0] be_i,
  output data_t [NumPorts-1:0] rdata_o
);

  logic [DataWidth-1:0] mem [NumWords-1:0];

  for (genvar p = 0; p < int'(NumPorts); p++) begin : gen_port
    data_t rdata_q;
    always_ff @(posedge clk_i) begin
      if (req_i[p]) begin
        if (we_i[p]) begin
          for (int unsigned b = 0; b < BeWidth; b++)
            if (be_i[p][b])
              mem[addr_i[p]][b*ByteWidth +: ByteWidth] <= wdata_i[p][b*ByteWidth +: ByteWidth];
        end else begin
          rdata_q <= mem[addr_i[p]];   // registered (synchronous) read -> BSRAM
        end
      end
    end
    assign rdata_o[p] = rdata_q;
  end
  // rst_ni/Latency/SimInit/BYTE_ACCESS/PrintSimCfg intentionally unused in this model.

endmodule
