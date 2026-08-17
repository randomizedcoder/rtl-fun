// parser_asserts.svh — toggleable assertion macros for the parser unit (Phase 5).
//
// Best practice: ONE source, assertions guarded, enabled by a build flag — no
// separate assert-heavy copy. These macros expand to real SystemVerilog
// assertions only when `PARSER_ASSERT` (simulation) or `FORMAL` (SymbiYosys) is
// defined; otherwise they vanish, so the same RTL is synthesizable and the
// no-assert build pays nothing.
//
//   nix run .#parser-sim        (+define+PARSER_ASSERT — assertions on)
//   nix run .#parser-formal     (+define+FORMAL — proved by SymbiYosys)
//   (a plain synth/elaborate has neither defined — assertions compiled out)
//
// Concurrent assertions are clocked and reset-gated (disable iff !rst) so they
// never fire on X during power-up. Immediate assertions are for the formal
// harness (combinational parser_execute).

`ifndef PARSER_ASSERTS_SVH
`define PARSER_ASSERTS_SVH

`ifdef PARSER_ASSERT
  `define PARSER_CHECKS_ON
`endif
`ifdef FORMAL
  `define PARSER_CHECKS_ON
`endif

`ifdef PARSER_CHECKS_ON
  // Concurrent (clocked, reset-gated) property.
  `define PRS_ASSERT(NAME, CLK, RSTN, PROP)                       \
    NAME: assert property (@(posedge (CLK)) disable iff (!(RSTN)) \
      (PROP)) else $error("[parser-assert] %s", `"NAME`");

  // Immediate assertion / assumption (for the combinational formal harness).
  `define PRS_ASSERT_I(NAME, COND) \
    NAME: assert (COND) else $error("[parser-assert] %s", `"NAME`");
  `define PRS_ASSUME_I(COND) assume (COND);
`else
  `define PRS_ASSERT(NAME, CLK, RSTN, PROP)
  `define PRS_ASSERT_I(NAME, COND)
  `define PRS_ASSUME_I(COND)
`endif

// Functional coverage points (N7, gap G12). Independent of the assertion flag:
// enabled by `PARSER_COVER` (set by the coverage build) so the normal sim/synth
// builds pay nothing. Expands to a concurrent `cover property`, which Verilator's
// `--coverage-user` collects and `verilator_coverage` aggregates into the report.
// Reset-gated like the assertions so it never samples X out of reset.
`ifdef PARSER_COVER
  `define PRS_COVER(NAME, CLK, RSTN, PROP)                        \
    NAME: cover property (@(posedge (CLK)) disable iff (!(RSTN)) \
      (PROP));
`else
  `define PRS_COVER(NAME, CLK, RSTN, PROP)
`endif

`endif // PARSER_ASSERTS_SVH
