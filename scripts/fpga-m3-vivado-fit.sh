# scripts/fpga-m3-vivado-fit.sh
#
# M3a verify-before-buy, definitive LUT number: run Vivado synth-only on our ACTUAL
# CVA6 RTL and report a TRUSTWORTHY utilization. This closes the one open thread from
# the openXC7 run (nix run .#fpga-m3-xilinx-fit), which mapped stock CVA6 to ~628k
# LUTs — a ~12x abc9 mapper-quality artifact, not the design's real size. Vivado is
# the only tool that gives a reliable LUT count for this arithmetic-heavy core, and
# free WebPACK/ML Standard covers XC7A200T, whose 7-series LUT6 fabric is IDENTICAL to
# the Genesys 2's XC7K325T — so an A200T synth certifies the fit with no board and no
# license cost. Same cva6_core_sv2v.v input as the openXC7 flow -> apples-to-apples.
# See docs/phase-8-status.md §"Verify-before-buy".
#
# Host-tool dependency (documented impurity, like the Gowin path): Vivado is NOT in
# nixpkgs. Install free Vivado WebPACK/ML Standard (covers XC7A200T), then put `vivado`
# on PATH (source settings64.sh) or export VIVADO=/path/to/bin/vivado. No license file
# and no MAC lock are needed for the free-tier A200T part. `nix run` passes the caller's
# runtime env through, so this needs no --impure — $VIVADO/$PATH are read at run time.
#
# Stages (arg 1, default "all"):
#   synth    Vivado synth_design (out_of_context) -> util.rpt + util_hier.rpt
#   report   re-print the utilization + VERDICT from an existing util.rpt
#   all      synth, then report
#
# Inputs:
#   build/fpga-m3-core-rtl/cva6_core_sv2v.v   CVA6 flist resolved + sv2v'd, Xilinx-
#                                             flavored, config-folded (same input the
#                                             openXC7 flow used); produced by
#                                             `nix run .#fpga-m3-core-rtl -- s0`
#   fpga/genesys2/cva6_fit_top.v              register-ring fit harness (committed)
#   fpga/genesys2/m3-vivado-fit.tcl           the synth-only utilization script
#
# Output: build/fpga-m3-vivado/  (util.rpt, util_hier.rpt, logs — build artifacts)
#
# Injected by the Nix wrapper: REPO_ROOT (common.sh).
set -euo pipefail

STAGE="${1:-all}"
case "$STAGE" in all|synth|report) ;; *) echo "ERROR: unknown stage '$STAGE' (want all|synth|report)" >&2; exit 2 ;; esac

: "${REPO_ROOT:?REPO_ROOT not set — the Nix wrapper injects it via common.sh}"

# Free-tier A200T by default: LUT/FF/DSP/RAMB counts are package-independent, and its
# 7-series LUT6 fabric is identical to the Genesys 2's 325T, so an A200T count certifies
# the Kintex. Override to xc7k325tffg900-2 with an edu/paid license for the exact part.
PART="${XILINX_PART:-xc7a200tsbg484-1}"
VIVADO="${VIVADO:-vivado}"

OUT_DIR="${FPGA_M3_VIVADO_OUT:-$REPO_ROOT/build/fpga-m3-vivado}"
SV2V="${FPGA_M3_SV2V:-$REPO_ROOT/build/fpga-m3-core-rtl/cva6_core_sv2v.v}"
HARNESS="$REPO_ROOT/fpga/genesys2/cva6_fit_top.v"
TCL="$REPO_ROOT/fpga/genesys2/m3-vivado-fit.tcl"

UTIL="$OUT_DIR/util.rpt"                  # the tcl also writes util_hier.rpt alongside

# 325T (Genesys 2) resource budget, for the VERDICT.
BUDGET_LUT=203800
BUDGET_FF=407600
BUDGET_DSP=840
BUDGET_RAMB36=445

mkdir -p "$OUT_DIR"

# ---- synth: Vivado synth_design (out_of_context) -> utilization -----------------------
do_synth() {
  if ! command -v "$VIVADO" >/dev/null 2>&1; then
    echo "ERROR: vivado not found (looked for '$VIVADO')" >&2
    echo "  install free Vivado WebPACK/ML Standard (covers XC7A200T), then either:" >&2
    echo "    source /path/to/Xilinx/Vivado/<ver>/settings64.sh   # puts vivado on PATH" >&2
    echo "    export VIVADO=/path/to/Xilinx/Vivado/<ver>/bin/vivado" >&2
    exit 1
  fi
  if [ ! -s "$SV2V" ]; then
    echo "ERROR: missing $SV2V" >&2
    echo "  produce the sv2v'd CVA6 core first:" >&2
    echo "    nix run .#fpga-m3-core-rtl -- s0" >&2
    exit 1
  fi
  echo "=== synth: Vivado synth_design (cva6_fit_top; rvfi pruned) on $PART -> $UTIL ==="
  echo "    vivado: $(command -v "$VIVADO")"
  echo "    input:  $SV2V ($(du -h "$SV2V" | cut -f1))"
  # -mode out_of_context: no top-level I/O buffers, so the harness's 4 pins need no .xdc.
  # Synth only (no place/route) — a utilization sizing, so minutes-to-an-hour, not days.
  ( cd "$OUT_DIR" && "$VIVADO" -mode batch -nojournal -nolog \
      -source "$TCL" \
      -tclargs "$SV2V" "$HARNESS" "$PART" "$OUT_DIR" )
  [ -s "$UTIL" ] || { echo "ERROR: Vivado produced no $UTIL — see $OUT_DIR/vivado.log" >&2; exit 1; }
  echo "=== synth: done -> $UTIL ==="
}

# Pull the first integer in the "Used" column of a Vivado report_utilization row whose
# name matches the given regex. report_utilization rows look like:
#   | CLB LUTs                    |  48213 |     0 | ... | 133800 | 36.03 |
util_count() {
  local pat="$1"
  grep -iE "\| +$pat +\|" "$UTIL" 2>/dev/null | head -n1 \
    | sed -E 's/^\| *[^|]*\| *([0-9]+).*/\1/' | tr -d ' '
}

# ---- report: print utilization + fit VERDICT vs the 325T budget -----------------------
do_report() {
  [ -s "$UTIL" ] || { echo "ERROR: missing $UTIL — run '$0 synth' first" >&2; exit 1; }

  # 7-series report_utilization names: "CLB LUTs" (Kintex) / "Slice LUTs" (Artix),
  # "CLB Registers"/"Slice Registers", "CARRY4", "DSPs", "Block RAM Tile"/"RAMB36/FIFO".
  local luts ff dsp ramb carry
  luts="$(util_count 'CLB LUTs|Slice LUTs')"
  ff="$(util_count 'CLB Registers|Slice Registers')"
  dsp="$(util_count 'DSPs|DSP48E1')"
  ramb="$(util_count 'Block RAM Tile|RAMB36')"
  carry="$(util_count 'CARRY4')"

  echo ""
  echo "=== M3a Vivado verify-before-buy: VERDICT ==="
  echo "part: $PART   harness: cva6_fit_top (stock cv64a6_imafdc_sv39, rvfi pruned)"
  echo "source: build/fpga-m3-core-rtl/cva6_core_sv2v.v (same input the openXC7 flow used)"
  echo ""
  printf '  %-14s %10s   / %-8s (325T)   %s\n' "resource" "used" "budget" "fit?"
  fit_line "LUT6"      "$luts"  "$BUDGET_LUT"
  fit_line "FF"        "$ff"    "$BUDGET_FF"
  fit_line "DSP48E1"   "$dsp"   "$BUDGET_DSP"
  fit_line "RAMB36"    "$ramb"  "$BUDGET_RAMB36"
  [ -n "$carry" ] && printf '  %-14s %10s\n' "CARRY4" "$carry"
  echo ""
  echo "  cross-check: openXC7/abc9 gave 628,762 LUTs on the SAME input — a ~12x mapper"
  echo "  artifact. Vivado is the trustworthy oracle; contrast makes the delta explicit."

  if [ -n "$luts" ] && [ "$luts" -lt "$BUDGET_LUT" ] 2>/dev/null; then
    echo "  RESULT: FITS on the Genesys 2 (XC7K325T) — LUT6 ${luts} of ${BUDGET_LUT}."
  else
    echo "  RESULT: could not confirm a LUT fit — inspect $UTIL" >&2
    exit 1
  fi
}

# print one "used / budget  fit?" row; blank counts render as "n/a"
fit_line() {
  local name="$1" used="$2" budget="$3" verdict="?"
  if [ -z "$used" ]; then
    printf '  %-14s %10s   / %-8s          n/a\n' "$name" "n/a" "$budget"
    return
  fi
  if [ "$used" -lt "$budget" ] 2>/dev/null; then verdict="FITS"; else verdict="OVER"; fi
  printf '  %-14s %10s   / %-8s          %s\n' "$name" "$used" "$budget" "$verdict"
}

case "$STAGE" in
  synth)  do_synth  ;;
  report) do_report ;;
  all)
    do_synth
    do_report
    ;;
esac
