# scripts/lib/suite.sh — the directed-suite driver shared by the standalone RTL
# suite (parser-sim.sh) and the in-core cosim (cva6-parser-cosim.sh).
#
# Both walk the generator's `cases.txt` manifest, run each case, tally pass/fail,
# print an aligned per-case verdict, and a summary. Only the per-case work differs
# (verilate-run vs gcc-link+model-run), so that is a callback; everything else
# lives here. Requires common.sh's conventions but no functions from it.

# run_suite <manifest> <cases_base_dir> <title> <summary_label> <case_cb>
#   For each row of <manifest> (fields: name category expect_ok exp_code len),
#   call:  <case_cb> <name> <category> <exp_code> <case_dir>
#   The callback returns 0 for PASS, non-zero for FAIL, and may append triage
#   lines (already indented) to the CASE_TRIAGE array; run_suite prints them under
#   a FAIL verdict, preserving the "verdict then triage" order. Returns non-zero
#   iff any case failed.
run_suite() {
  local manifest="$1" base="$2" title="$3" summary="$4" cb="$5"
  local name category _expect_ok exp_code _len cdir result fails=0 ncase=0
  echo "=================================================="
  echo "$title"
  echo "=================================================="
  while read -r name category _expect_ok exp_code _len; do
    [ -n "$name" ] || continue
    ncase=$((ncase + 1))
    cdir="$base/$name"
    CASE_TRIAGE=()
    if "$cb" "$name" "$category" "$exp_code" "$cdir"; then
      result="PASS"
    else
      result="FAIL"
      fails=$((fails + 1))
    fi
    printf '  %-22s %-9s exp_code=%-5s  %s\n' "$name" "$category" "$exp_code" "$result"
    if [ "$result" = "FAIL" ] && [ "${#CASE_TRIAGE[@]}" -gt 0 ]; then
      printf '%s\n' "${CASE_TRIAGE[@]}"
    fi
  done < "$manifest"
  echo "--------------------------------------------------"
  echo "$summary: $ncase cases, $fails failures"
  echo "=================================================="
  [ "$fails" -eq 0 ]
}
