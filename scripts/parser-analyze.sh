# Static analysis for the parser RTL (Phase 5/6).
#
# Body for the `parser-analyze` writeShellApplication (nix/rtl.nix). Runs two
# independent SystemVerilog linters over the parser modules, complementing the
# Verilator -Wall pass (nix run .#parser-lint):
#
#   1. verible-verilog-lint   Google's SV style/correctness linter, with the
#                             project rule config rtl/.rules.verible_lint
#   2. svlint                 rule-based SV linter, with the correctness-focused
#                             config rtl/.svlint.toml
#
# Between them and Verilator, three independent front ends check the RTL. Tools
# (verible, svlint) come from the wrapper's runtimeInputs. Run from the repo root.

set -euo pipefail

REPO="${REPO:-$PWD}"
RTL="$REPO/rtl"
TB="$REPO/tb"

if [ ! -d "$RTL" ]; then
  echo "parser-analyze: $RTL not found — run from the repo root" >&2
  exit 2
fi

srcs=(
  "$RTL/parser_pkg.sv"
  "$RTL/parser_pktbuf.sv"
  "$RTL/parser_cam.sv"
  "$RTL/parser_decode.sv"
  "$RTL/parser_execute.sv"
  "$TB/parser_top.sv"
  "$RTL/cva6_parser_wrap.sv"
)

echo "== 1/2 verible-verilog-lint =="
verible-verilog-lint --rules_config "$RTL/.rules.verible_lint" "${srcs[@]}"
echo "verible: clean"

echo "== 2/2 svlint =="
# svlint checks one file at a time; -I resolves the shared assert header include.
for f in "${srcs[@]}"; do
  svlint -c "$RTL/.svlint.toml" -I "$RTL" "$f"
done
echo "svlint: clean"

echo "parser-analyze: verible + svlint clean"
