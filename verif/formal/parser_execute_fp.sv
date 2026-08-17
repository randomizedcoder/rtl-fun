// parser_execute_fp.sv — formal-property harness for parser_execute (Phase 5/6).
//
// parser_execute is purely combinational (next state from current state + one
// micro-op), so this harness lets SymbiYosys drive EVERY input symbolically —
// all 2^N machine states, ops, packet windows and CAM results at once — and
// proves the memory-safety and exit-consistency invariants hold for all of them.
// This is unbounded proof, not a directed test: if the property holds here it
// holds for inputs no test vector ever tries.
//
//   nix run .#parser-formal   (yosys read -sv -> sby prove, engine z3)
//
// The DUT's inputs are left as undriven nets: in the yosys formal flow an
// undriven net is a free (symbolic) input, so `parser_execute u_dut (.*)` wires
// each one to a fresh symbol. `assume` narrows that freedom to legal inputs the
// sequencer can actually present; `assert` states what must then always be true.

module parser_execute_fp
  import parser_pkg::*;
(
    input logic clk_i     // sby wants a clock; the DUT is combinational
);

  // ---- DUT ports (undriven == symbolic free inputs) ----
  pstate_t              st_i;
  micro_op_t            op_i;
  logic [PC_W-1:0]      pc_i;
  logic [15:0]          parse_len_i;
  logic [PKT_OFF_W-1:0] mem_off_o;
  logic [63:0]          mem_win_be_i;
  logic [3:0]           cam_share_o;
  logic [15:0]          cam_match_o;
  logic                 cam_hit_i;
  logic [31:0]          cam_target_i;
  logic                 meta_we_o;
  logic [META_OFF_W-1:0] meta_off_o;
  logic [63:0]          meta_wdata_o;
  logic [3:0]           meta_nbytes_o;
  pstate_t              st_o;

  parser_execute u_dut (.*);

  // ---- environment assumptions (what the sequencer guarantees) ----
  always_comb begin
    // the parser never steps a micro-op once it has already exited
    assume (!st_i.done);
    // op is a decoded, legal opcode (out-of-range hits the fail-safe default,
    // which we exclude so the proof reasons over real instructions)
    assume (op_i.op <= OP_STP);
  end

  // ---- safety properties (must hold for ALL legal inputs) ----
  always_comb begin
    // 1. a metadata write never escapes the flow_keys frame (memory safety)
    if (meta_we_o) begin
      a_meta_bound:   assert (({23'h0, meta_off_o} + {28'h0, meta_nbytes_o}) <= META_MAX);
      // 2. a write moves 1..8 bytes — never zero, never wider than a register
      a_meta_nbytes:  assert (meta_nbytes_o inside {4'd1, 4'd2, 4'd4, 4'd8});
    end
    // 3. a completed parse always carries a negative parser exit code
    if (st_o.done) a_exit_neg: assert (st_o.code < 0);
  end

endmodule : parser_execute_fp
