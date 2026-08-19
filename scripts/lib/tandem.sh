# scripts/lib/tandem.sh — the RVFI-vs-Spike lock-step gate, shared by the tandem
# runner (cva6-parser-tandem.sh) and the Stage-2 campaign (cva6-parser-tandem-
# campaign.sh). Kept here in ONE place so the two apps cannot drift on what
# "the tandem passed" means. Requires common.sh's model_success and these globals
# set by the caller BEFORE the first call: BIN, OUT, CORE_NAME, MAXCYC.

# gate_tandem <label> <elf> <min_instr> <check_isa 0|1>
# Run a PREBUILT ELF on the tandem model and gate on the scoreboard's YAML report
# (the authoritative verdict): exit_cause SUCCESS AND mismatches_count 0 (numeric —
# printed 0x%h, any width of leading zeros is clean) AND at least <min_instr>
# instructions lock-stepped (anti-vacuous) AND, if check_isa, the reference Spike is
# full RV64GC, AND the program's own fesvr self-check SUCCESS. Prints nothing; sets
#   GATE_SUMMARY  one-line "exit_cause=.. mismatches=.. instr=.." for the caller
#   GATE_TRIAGE   array of indented triage lines (populated only on FAIL)
# Returns 0 on PASS, 1 on FAIL.
gate_tandem() {
  local label="$1" elf="$2" min_instr="$3" check_isa="$4"
  local log="$OUT/$label.log" report="$OUT/$label.report.yaml"
  GATE_SUMMARY=""; GATE_TRIAGE=()
  rm -f "$report"
  # Spike's reference model needs +elf_file (it loads the ELF into its own memory),
  # +core_name (its default-params profile; must start with cv64a), and +report_file
  # (where the scoreboard writes its verdict). ulimit -s unlimited: the ~196 KB
  # st_rvfi is passed by value onto the Verilator NBA stack (default 8 MB SIGSEGVs).
  set +e
  ( ulimit -s unlimited
    "$BIN" "$elf" "+elf_file=$elf" "+core_name=$CORE_NAME" \
      "+report_file=$report" "+max-cycles=$MAXCYC" ) >"$log" 2>&1
  set -e

  local ok=1
  if [ -f "$report" ]; then
    local cause mmc icnt_hex icnt
    cause="$(grep -E '^exit_cause:' "$report" | awk '{print $2}')"
    mmc="$(grep -E '^mismatches_count:' "$report" | awk '{print $2}')"
    icnt_hex="$(grep -E '^instr_count:' "$report" | awk '{print $2}')"
    icnt=$(( icnt_hex + 0 ))
    GATE_SUMMARY="exit_cause=$cause mismatches=$mmc instr=$icnt"
    [ "$cause" = "SUCCESS" ] || { ok=0; GATE_TRIAGE+=("      FAIL: exit_cause=$cause (not SUCCESS)"); }
    [ "$(( mmc + 0 ))" -eq 0 ] || { ok=0; GATE_TRIAGE+=("      FAIL: mismatches_count=$mmc (nonzero)"); }
    [ "$icnt" -ge "$min_instr" ] || { ok=0; GATE_TRIAGE+=("      FAIL: only $icnt instructions lock-stepped (<$min_instr) — vacuous"); }
  else
    ok=0; GATE_SUMMARY="no report"; GATE_TRIAGE+=("      FAIL: no report at $report (lock-step never reached a verdict)")
  fi
  # Guard the config seam a prior bug lived in: the reference Spike must be the full
  # RV64GC ISA (I M A F D C) — a dropped extension letter silently weakens the oracle.
  if [ "$check_isa" -eq 1 ]; then
    if ! grep -qE "isa: 'RV64I.*M.*A.*F.*D.*C" "$log"; then
      ok=0; GATE_TRIAGE+=("      FAIL: tandem Spike ISA string missing an expected RV64GC extension")
    fi
  fi
  model_success "$log" || { ok=0; GATE_TRIAGE+=("      FAIL: program fesvr self-check did not SUCCEED"); }

  [ "$ok" -eq 1 ] && return 0
  GATE_TRIAGE+=("      -- last 20 log lines --")
  while IFS= read -r _ln; do GATE_TRIAGE+=("      $_ln"); done < <(tail -20 "$log")
  [ -f "$report" ] && { GATE_TRIAGE+=("      -- report --"); while IFS= read -r _ln; do GATE_TRIAGE+=("      $_ln"); done < "$report"; }
  return 1
}
