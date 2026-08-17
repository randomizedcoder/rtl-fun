// tb_check.svh — the one check primitive shared by the parser testbenches.
//
// `include this inside a module body; it declares the pass/fail tally and a
// `check(cond, msg)` task that increments the tally and $errors on failure. Both
// parser_smoke_tb and parser_wrap_tb use it, so the two testbenches report the
// same way (previously a `CHECK macro with checks/fails vs a check() task with
// errors). The including module drives its own exit: `if (tb_fails) $fatal(...)`.
`ifndef TB_CHECK_SVH
`define TB_CHECK_SVH

  int tb_checks = 0;
  int tb_fails  = 0;

  task automatic check(input bit cond, input string msg);
    tb_checks++;
    if (!cond) begin
      tb_fails++;
      $error("CHECK failed: %s", msg);
    end
  endtask

`endif
