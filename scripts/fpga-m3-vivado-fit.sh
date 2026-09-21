# scripts/fpga-m3-vivado-fit.sh
#
# M3a verify-before-buy, definitive LUT number: run Vivado synth-only on our ACTUAL
# CVA6 RTL and report a TRUSTWORTHY utilization + fit VERDICT vs the Genesys 2 budget.
# This closes the thread the openXC7 run (nix run .#fpga-m3-xilinx-fit) left open, where
# yosys/abc9 mapped stock CVA6 to ~628k LUTs. On our RTL the real story is:
#
#   native Vivado  48,217 LUT6 (24% of the 325T)   <- the truth (default MODE=native)
#   sv2v + Vivado  277,751 LUT6                     <- sv2v INPUT penalty, ~5.8x
#   sv2v + abc9    628,762 LUT6 (openXC7)           <- sv2v ~5.8x AND abc9 ~2.3x, ~13x
#
# Vivado is SystemVerilog-native, so the trustworthy number comes from feeding it CVA6's
# REAL .sv flist (MODE=native, top `cva6`). The sv2v path (MODE=sv2v) is kept only to
# reproduce the inflated contrast figure. See docs/phase-8-status.md §"Verify-before-buy".
#
# Host-tool dependency (documented impurity, like the Gowin path): Vivado is NOT in
# nixpkgs. Free Vivado 2026.1 "Basic" tier covers ALL 7-series (incl. the Genesys 2's
# xc7k325t) but is node-locked to a NIC MAC — generate a (free) license, then put
# `vivado` on PATH (source settings64.sh) or export VIVADO=/path/to/bin/vivado. On NixOS,
# run inside the FHS sandbox (nix run .#vivado-fhs) — see the error path below. `nix run`
# passes the caller's runtime env through, so this needs no --impure.
#
# Env knobs:
#   FPGA_M3_VIVADO_MODE     native (default) | sv2v
#   XILINX_PART             default xc7k325tffg900-2 (Genesys 2); LUT/FF/DSP/RAMB counts
#                           are package-independent and the 7-series LUT6 fabric is common
#                           across Artix/Kintex, so any 7-series part certifies the fit.
#   FPGA_M3_VIVADO_THREADS  synth worker threads (default 4; Vivado clamps to host cores)
#   VIVADO                  path to the vivado executable (else `vivado` on PATH)
#
# NOTE for CPU-isolated hosts (e.g. isolcpus=): a normal process is confined to the
# non-isolated cores, throttling Vivado. Pin it to spare cores explicitly, e.g.
#   taskset -c 2-7 nix run .#fpga-m3-vivado-fit
# (isolcpus removes cores from default scheduling but still allows explicit affinity).
#
# Stages (arg 1, default "all"):
#   synth    Vivado synth_design (out_of_context) -> util.rpt + util_hier.rpt
#   report   re-print the utilization + VERDICT from an existing util.rpt
#   all      synth, then report
#
# Inputs (MODE=native):
#   build/fpga-m3-core-rtl/files.txt      native CVA6 .sv flist (cv64a6_imafdc_sv39)
#   build/fpga-m3-core-rtl/incdirs.txt    include dirs
#   fpga/genesys2/m3-vivado-fit-native.tcl
# Inputs (MODE=sv2v):
#   build/fpga-m3-core-rtl/cva6_core_sv2v.v   sv2v'd core (inflated; contrast only)
#   fpga/genesys2/cva6_fit_top.v              register-ring harness (rvfi pruned)
#   fpga/genesys2/m3-vivado-fit.tcl
# Both modes need `nix run .#fpga-m3-core-rtl -- s0` to have produced their inputs.
#
# Output: build/fpga-m3-vivado/  (util.rpt, util_hier.rpt, logs — build artifacts)
#
# Injected by the Nix wrapper: REPO_ROOT (common.sh).
set -euo pipefail

STAGE="${1:-all}"
case "$STAGE" in all|synth|report) ;; *) echo "ERROR: unknown stage '$STAGE' (want all|synth|report)" >&2; exit 2 ;; esac

: "${REPO_ROOT:?REPO_ROOT not set — the Nix wrapper injects it via common.sh}"

MODE="${FPGA_M3_VIVADO_MODE:-native}"
case "$MODE" in native|sv2v) ;; *) echo "ERROR: unknown FPGA_M3_VIVADO_MODE '$MODE' (want native|sv2v)" >&2; exit 2 ;; esac

# Default to the actual Genesys 2 part (Basic license covers it). Counts are
# package-independent, so any 7-series part gives the same LUT/FF/DSP/RAMB numbers.
PART="${XILINX_PART:-xc7k325tffg900-2}"
VIVADO="${VIVADO:-vivado}"
THREADS="${FPGA_M3_VIVADO_THREADS:-4}"

OUT_DIR="${FPGA_M3_VIVADO_OUT:-$REPO_ROOT/build/fpga-m3-vivado}"
CORE_RTL="$REPO_ROOT/build/fpga-m3-core-rtl"

# native inputs
FLIST="${FPGA_M3_FLIST:-$CORE_RTL/files.txt}"
INCDIRS="${FPGA_M3_INCDIRS:-$CORE_RTL/incdirs.txt}"
TCL_NATIVE="$REPO_ROOT/fpga/genesys2/m3-vivado-fit-native.tcl"
# sv2v inputs
SV2V="${FPGA_M3_SV2V:-$CORE_RTL/cva6_core_sv2v.v}"
HARNESS="$REPO_ROOT/fpga/genesys2/cva6_fit_top.v"
TCL_SV2V="$REPO_ROOT/fpga/genesys2/m3-vivado-fit.tcl"

UTIL="$OUT_DIR/util.rpt"                  # the tcl also writes util_hier.rpt alongside

# 325T (Genesys 2) resource budget, for the VERDICT.
BUDGET_LUT=203800
BUDGET_FF=407600
BUDGET_DSP=840
BUDGET_RAMB36=445

mkdir -p "$OUT_DIR"

# ---- shared: check Vivado is reachable, or print the install pointer -------------------
require_vivado() {
  if command -v "$VIVADO" >/dev/null 2>&1; then return 0; fi
  echo "ERROR: vivado not found (looked for '$VIVADO')" >&2
  echo "  install free Vivado (2026.1 'Basic' tier covers all 7-series incl. xc7k325t)," >&2
  echo "  generate its (free) node-locked license, then either:" >&2
  echo "    source /path/to/Xilinx/Vivado/<ver>/settings64.sh   # puts vivado on PATH" >&2
  echo "    export VIVADO=/path/to/Xilinx/Vivado/<ver>/bin/vivado" >&2
  echo "  on NixOS, Vivado's FHS binaries won't run natively (libX11.so.6 etc.) — use the" >&2
  echo "  FHS sandbox:" >&2
  echo "    nix run .#vivado-fhs                     # interactive: run the installer here" >&2
  echo "    export VIVADO_SETTINGS=/path/to/Xilinx/<ver>/Vivado/settings64.sh" >&2
  echo "    export VIVADO=\"\$(nix build --no-link --print-out-paths .#vivado-fhs-vivado)/bin/vivado\"" >&2
  exit 1
}

# ---- synth: Vivado synth_design (out_of_context) -> utilization -----------------------
do_synth() {
  require_vivado
  if [ "$MODE" = native ]; then
    for f in "$FLIST" "$INCDIRS"; do
      if [ ! -s "$f" ]; then
        echo "ERROR: missing $f" >&2
        echo "  produce the native CVA6 flist first:" >&2
        echo "    nix run .#fpga-m3-core-rtl -- s0" >&2
        exit 1
      fi
    done
    echo "=== synth [native]: Vivado synth_design (top cva6; native .sv) on $PART -> $UTIL ==="
    echo "    vivado:  $(command -v "$VIVADO")"
    echo "    flist:   $FLIST ($(wc -l < "$FLIST") files)"
    echo "    threads: $THREADS (host may clamp)"
    ( cd "$OUT_DIR" && "$VIVADO" -mode batch -nojournal -nolog \
        -source "$TCL_NATIVE" \
        -tclargs "$FLIST" "$INCDIRS" "$PART" "$OUT_DIR" "$THREADS" )
  else
    if [ ! -s "$SV2V" ]; then
      echo "ERROR: missing $SV2V" >&2
      echo "  produce the sv2v'd CVA6 core first:" >&2
      echo "    nix run .#fpga-m3-core-rtl -- s0" >&2
      exit 1
    fi
    echo "=== synth [sv2v, INFLATED contrast]: Vivado synth_design (cva6_fit_top) on $PART -> $UTIL ==="
    echo "    vivado: $(command -v "$VIVADO")"
    echo "    input:  $SV2V ($(du -h "$SV2V" | cut -f1))"
    ( cd "$OUT_DIR" && "$VIVADO" -mode batch -nojournal -nolog \
        -source "$TCL_SV2V" \
        -tclargs "$SV2V" "$HARNESS" "$PART" "$OUT_DIR" )
  fi
  [ -s "$UTIL" ] || { echo "ERROR: Vivado produced no $UTIL — see $OUT_DIR/vivado.log" >&2; exit 1; }
  echo "=== synth: done -> $UTIL ==="
}

# Pull the first integer in the "Used" column of a Vivado report_utilization row whose
# name matches the given regex. report_utilization rows look like:
#   | Slice LUTs*                 |  48217 |     0 | ... | 203800 | 23.66 |
util_count() {
  local pat="$1"
  grep -iE "\| +$pat\*? +\|" "$UTIL" 2>/dev/null | head -n1 \
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
  echo "=== M3a Vivado verify-before-buy: VERDICT (mode=$MODE) ==="
  echo "part: $PART"
  if [ "$MODE" = native ]; then
    echo "source: native CVA6 SystemVerilog flist (cv64a6_imafdc_sv39), top cva6,"
    echo "        -flatten_hierarchy none (rvfi kept + hierarchy unflattened = conservative)"
  else
    echo "source: build/fpga-m3-core-rtl/cva6_core_sv2v.v (sv2v — INFLATED ~5.8x, contrast only)"
  fi
  echo ""
  printf '  %-14s %10s   / %-8s (325T)   %s\n' "resource" "used" "budget" "fit?"
  fit_line "LUT6"      "$luts"  "$BUDGET_LUT"
  fit_line "FF"        "$ff"    "$BUDGET_FF"
  fit_line "DSP48E1"   "$dsp"   "$BUDGET_DSP"
  fit_line "RAMB36"    "$ramb"  "$BUDGET_RAMB36"
  [ -n "$carry" ] && printf '  %-14s %10s\n' "CARRY4" "$carry"
  echo ""
  if [ "$MODE" = native ]; then
    echo "  cross-check: same RTL gave 277,751 LUTs via sv2v+Vivado and 628,762 via"
    echo "  sv2v+abc9 (openXC7) — both INPUT/mapper artifacts. Native Vivado is the truth."
  else
    echo "  NOTE: this is the sv2v-inflated figure. The trustworthy count is MODE=native"
    echo "  (~48k LUT6); openXC7/abc9 gave 628,762 on this same sv2v input."
  fi

  if [ -n "$luts" ] && [ "$luts" -lt "$BUDGET_LUT" ] 2>/dev/null; then
    echo "  RESULT: FITS on the Genesys 2 (XC7K325T) — LUT6 ${luts} of ${BUDGET_LUT}."
  else
    echo "  RESULT: LUT6 ${luts:-n/a} not under ${BUDGET_LUT} — inspect $UTIL" >&2
    [ "$MODE" = sv2v ] && echo "  (expected for MODE=sv2v; use MODE=native for the real fit)" >&2
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
