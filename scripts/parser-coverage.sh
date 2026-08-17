# Build + run the parser unit under Verilator coverage, merge, and report (N7, G12).
#
# Body for the parser-coverage writeShellApplication (nix/rtl.nix). Produces
# STRUCTURAL coverage (line + toggle) on the synthesizable parser RTL and FUNCTIONAL
# coverage (SystemVerilog `cover property` points, +define+PARSER_COVER) over the
# V-table cross-product from §2.6.5:
#   - op-CLASS × exit-outcome  — sampled in tb/parser_top.sv, driven by the
#     model-generated 22-case smoke suite (every op class + OK/fail exits);
#   - pipeline-EVENT × op-category — sampled in rtl/cva6_parser_wrap.sv, driven by
#     the 13 tb/parser_wrap_tb.sv scenarios (accept/commit/flush/backpressure/
#     interlock/redirect/exit).
# Both builds emit coverage.dat; verilator_coverage merges them into one report.
#
#   nix run .#parser-coverage
#
# Closure gate: every enumerated FUNCTIONAL bin must be hit >= 1 (100% functional).
# Structural line/toggle % is reported for visibility (parser_execute etc. may hold
# legitimately-unreachable defaults, so it is informational, not a hard gate).
#
# Tools (verilator, verilator_coverage, cc) come from the wrapper's runtimeInputs.
# Run from the repo root; artifacts land in build/parser-coverage/ (gitignored).

set -euo pipefail

if ! declare -F gen_vectors >/dev/null 2>&1; then
  _lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
  # shellcheck source=/dev/null
  . "$_lib/common.sh"
  # shellcheck source=/dev/null
  . "$_lib/suite.sh"
fi

BUILD="${PARSER_BUILD:-$REPO_ROOT/build/parser-coverage}"
COV="$BUILD/cov"

if [ ! -d "$RTL" ]; then
  echo "parser-coverage: $RTL not found — run from the repo root" >&2
  exit 2
fi
rm -rf "$BUILD"
mkdir -p "$BUILD" "$COV"

# Coverage flags: line + toggle (structural) + user (our cover points), on top of the
# shared warning/assert set. +define+PARSER_COVER turns the PRS_COVER macros into real
# `cover property`. --coverage-underscore includes our leading-underscore-free names.
covflags=(--coverage-line --coverage-toggle --coverage-user +define+PARSER_COVER)

# 1. model-generated vectors (the whole directed suite).
gen_vectors "$BUILD" --suite

# ---- Build A: the smoke suite (op-class × exit-outcome coverage) ----------------
echo "== [A] verilating the smoke suite under coverage =="
smoke_srcs=(
  "$RTL/parser_pkg.sv" "$RTL/parser_pktbuf.sv" "$RTL/parser_cam.sv"
  "$RTL/parser_decode.sv" "$RTL/parser_execute.sv"
  "$TB/parser_top.sv" "$TB/parser_smoke_tb.sv"
)
( cd "$BUILD" && rm -rf obj_smoke && verilator --binary -O3 -o parser-cov-smoke \
    --Mdir obj_smoke "${covflags[@]}" "${PARSER_VFLAGS[@]}" \
    "-I$RTL" "-I$TB" "-I$BUILD" --top-module parser_smoke_tb "${smoke_srcs[@]}" )

echo "== [A] running the 22-case suite (each dumps coverage.dat) =="
smoke_case() {
  local cdir="$4"
  ln -sf ../../program.hex ../../cam.hex ../../enc.hex "$cdir"/
  if ( cd "$cdir" && "$BUILD/obj_smoke/parser-cov-smoke" ) > "$cdir/run.log" 2>&1; then
    # each case leaves coverage.dat in its own dir; stash it uniquely for the merge
    [ -f "$cdir/coverage.dat" ] && cp "$cdir/coverage.dat" "$COV/smoke-$(basename "$cdir").dat"
    return 0
  fi
  mapfile -t CASE_TRIAGE < <(sed 's/^/      /' "$cdir/run.log")
  return 1
}
run_suite "$BUILD/cases.txt" "$BUILD/cases" "parser coverage suite" "coverage suite" smoke_case

# ---- Build B: the wrap-TB (pipeline-event × op-category coverage) ---------------
echo "== [B] verilating the cva6_parser_wrap testbench under coverage =="
wrap_srcs=(
  "$RTL/parser_pkg.sv" "$RTL/parser_execute.sv" "$RTL/cva6_parser_wrap.sv"
  "$TB/parser_wrap_tb.sv"
)
( cd "$BUILD" && rm -rf obj_wrap && verilator --binary -O3 -o parser-cov-wrap \
    --Mdir obj_wrap "${covflags[@]}" "${PARSER_VFLAGS[@]}" \
    "-I$RTL" "-I$TB" --top-module parser_wrap_tb "${wrap_srcs[@]}" )

echo "== [B] running the wrap-TB =="
( cd "$BUILD/obj_wrap" && ./parser-cov-wrap ) > "$BUILD/wrap-run.log" 2>&1
cp "$BUILD/obj_wrap/coverage.dat" "$COV/wrap.dat"

# ---- merge + annotate -----------------------------------------------------------
echo "== merging coverage =="
mapfile -t dats < <(find "$COV" -maxdepth 1 -name '*.dat' ! -name 'merged.dat')
verilator_coverage --write "$COV/merged.dat" "${dats[@]}"
verilator_coverage --annotate "$COV/annotated" --annotate-min 1 "$COV/merged.dat" >/dev/null 2>&1 || true

# ---- functional closure gate ----------------------------------------------------
# Every enumerated cover point (rtl/cva6_parser_wrap.sv c_*, tb/parser_top.sv c_*)
# must have a nonzero hit count in the merged data. cover_count sums the trailing
# count across every merged line mentioning the point name (bounded so c_op_cam does
# not match c_op_camnext).
COVER_BINS=(
  # -- FU pipeline events (cva6_parser_wrap) --
  c_accept_parse c_accept_wrpreg c_accept_wrpregimm c_accept_wrcam
  c_accept_rdpreg c_accept_rdcam c_commit c_commit_cam c_wb_rd
  c_flush c_flush_pending c_parse_then_flush c_bp_full c_interlock
  c_redirect_jump c_redirect_exit c_camnext_hit c_parse_exit
  # -- op class × exit outcome (parser_top) --
  c_op_load c_op_lencur c_op_cmpib c_op_cmpineb c_op_cmpord c_op_cam
  c_op_camnext c_op_store c_op_storeimm c_op_nextnode c_op_setcode c_op_stp
  c_exit_okay c_exit_fail
)

# Sum the hit count for a named cover point across the merged .dat. Verilator encodes
# each point as  C '<..packed fields..>' <count>  and appends the SVA label to the
# hierarchy as  .<name>  just before the closing quote, so ".<name>'" is a unique,
# prefix-safe match (c_op_cam won't alias c_op_camnext); the count is the last field.
cover_count() {
  awk -v p=".$1'" 'index($0, p){s+=$NF} END{print s+0}' "$COV/merged.dat"
}

echo ""
echo "== functional coverage (§2.6.5 V-table cross-product) =="
hit=0; miss=0; misslist=""
for b in "${COVER_BINS[@]}"; do
  c=$(cover_count "$b")
  if [ "$c" -gt 0 ]; then
    hit=$((hit+1)); printf "  %-20s %6d\n" "$b" "$c"
  else
    miss=$((miss+1)); misslist="$misslist $b"; printf "  %-20s %6s  <== NOT HIT\n" "$b" 0
  fi
done
total=$((hit+miss))

# structural summary (informational): verilator_coverage prints per-file % to stderr
echo ""
echo "== structural coverage (line + toggle, informational) =="
verilator_coverage --annotate "$COV/annotated" "$COV/merged.dat" 2>&1 | grep -iE "Total coverage|%" | tail -20 || true

echo ""
echo "== functional closure: $hit/$total bins hit =="
if [ "$miss" -eq 0 ]; then
  echo "== PASS: 100% functional coverage — every V-table cross-product bin hit (G12) =="
  echo "   report: $COV/merged.dat ; annotated sources: $COV/annotated/"
  exit 0
else
  echo "== FAIL: functional coverage gap — bins never hit:$misslist ==" >&2
  echo "   (add directed stimulus to the smoke suite / wrap-TB to close these)" >&2
  exit 1
fi
