// Copyright 2022 Thales DIS design services SAS
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
//
// Original Author: Jean-Roch COULON - Thales
//
// PHASE-8 M3a EDIT (rtl-fun). The upstream common/local/util/tc_sram_wrapper.sv is an
// EMPTY stub — Thales documents it as "to be replaced by the wrapper of the technology
// used to avoid having black box at synthesis". Left empty it is a blackbox (GowinSynthesis
// EX3937). We fill it with a SYNCHRONOUS-READ, byte-write-enable RAM in the textbook
// block-RAM inference template: a single write/read port per NumPorts, the read data
// REGISTERED (rdata_q <= mem[addr]). This is the key M3a requirement — an ASYNC-read array
// (as in pulp's generic tc_sram, `assign rdata = mem[addr]`) is demoted by yosys to a "list
// of registers" and never maps to BSRAM (challenge #16); a registered-read array stays a
// $mem cell and GowinSynthesis infers it as BSRAM. Latency is 1 read cycle (matches the
// callers, which instantiate NumPorts=1/DataWidth=64/Latency=1). No reset on the array
// (BSRAM has none). This is a FIT-oriented model (M3a proves the core fits with BSRAM); it
// is a standard 1-cycle SP-RAM and behaves correctly for M3b's bring-up too.

module tc_sram_wrapper #(
  parameter int unsigned NumWords     = 32'd1024,
  parameter int unsigned DataWidth    = 32'd128,
  parameter int unsigned ByteWidth    = 32'd8,
  parameter int unsigned NumPorts     = 32'd2,
  parameter int unsigned Latency      = 32'd1,
  parameter              SimInit      = "none",
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

  // Shared memory array. No initial/reset content (keeps it BSRAM-inferrable).
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
  // rst_ni/Latency/SimInit/PrintSimCfg intentionally unused in this technology model.

endmodule
