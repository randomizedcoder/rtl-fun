# scripts/fpga-10g-fit.sh
#
# Phase-C verify-before-buy: does a 10G Ethernet MAC BUILD, FIT and meet Fmax on the
# AX7325B die (xc7k325tffg900-2), with NO board and NO transceiver IP? This is the
# datapath-feasibility complement to the CVA6 SoC proofs (A2/B4): combined with the SoC
# utilization it shows CVA6 + a 10G MAC co-reside on the 325T fabric.
#
# DUT: Alex Forencich verilog-ethernet `eth_mac_10g` (64-bit XGMII, AXI-Stream fabric
# side) — the 10G sibling of the 1G MAC this repo already vendors
# (corev_apu/fpga/src/ariane-ethernet/eth_mac_1g*.sv). Source is the pinned flake input
# `verilog-ethernet-src` (nix injects VERILOG_ETHERNET_SRC). The XGMII side is the seam
# to the GTX/10GBASE-R PCS-PMA transceiver, which is deliberately NOT built here — the
# refclk/serdes SI is the part that genuinely needs silicon (docs §"Out of scope").
#
# The MAC is synthesized DIRECTLY as an out_of_context top (no fit harness) — the same
# faithful idiom as fpga-m3-vivado-fit (OOC ports are primary I/O and are not folded).
# See fpga/ax7325b/10g-fit.tcl for the rationale.
#
# Host-tool dependency (documented impurity, like the other Vivado targets): Vivado is
# NOT in nixpkgs. Free 2026.1 "Basic" covers all 7-series incl. xc7k325t (A1 proved it
# does full impl+bitstream), so OOC synth+route is licensed. Put `vivado` on PATH
# (source settings64.sh) or export VIVADO=/path/to/bin/vivado; on NixOS use the FHS
# sandbox (nix run .#vivado-fhs). `nix run` passes the caller's env through — no --impure.
#
# Env knobs:
#   XILINX_PART        part to fit (default xc7k325tffg900-2 — the AX7325B / Genesys 2 die)
#   FPGA_10G_PERIOD_NS target clock period ns (default 6.400 = 156.25 MHz, 64-bit XGMII 10G)
#   FPGA_10G_THREADS   synth/impl worker threads (default 4; Vivado clamps to host cores)
#   VIVADO             path to the vivado executable (else `vivado` on PATH)
#   VERILOG_ETHERNET_SRC  verilog-ethernet checkout (injected by the Nix wrapper)
#
# NOTE for isolcpus hosts: pin to spare cores, e.g. taskset -c 2-7 nix run .#fpga-10g-fit
#
# Stages (arg 1, default "all"):
#   synth    Vivado OOC synth_design -> util.rpt (fit only, estimated timing)
#   route    Vivado OOC synth + place + route -> util.rpt + timing.rpt (real Fmax)
#   report   re-print utilization + fit/Fmax VERDICT from existing reports
#   all      route, then report
#
# Output: build/fpga-10g-fit/  (util.rpt, util_hier.rpt, timing.rpt, logs)
#
# Injected by the Nix wrapper: REPO_ROOT (common.sh), VERILOG_ETHERNET_SRC.
set -euo pipefail

STAGE="${1:-all}"
case "$STAGE" in all|synth|route|report) ;; *) echo "ERROR: unknown stage '$STAGE' (want all|synth|route|report)" >&2; exit 2 ;; esac

: "${REPO_ROOT:?REPO_ROOT not set — the Nix wrapper injects it via common.sh}"
: "${VERILOG_ETHERNET_SRC:?VERILOG_ETHERNET_SRC not set — the Nix wrapper injects the pinned source}"

PART="${XILINX_PART:-xc7k325tffg900-2}"
PERIOD_NS="${FPGA_10G_PERIOD_NS:-6.400}"
THREADS="${FPGA_10G_THREADS:-4}"
VIVADO="${VIVADO:-vivado}"

SRC_DIR="$VERILOG_ETHERNET_SRC/rtl"
TCL="$REPO_ROOT/fpga/ax7325b/10g-fit.tcl"
OUT_DIR="${FPGA_10G_FIT_OUT:-$REPO_ROOT/build/fpga-10g-fit}"
UTIL="$OUT_DIR/util.rpt"
TIMING="$OUT_DIR/timing.rpt"
LOG="$OUT_DIR/vivado.log"

# 325T (AX7325B / Genesys 2) resource budget, for the fit VERDICT.
BUDGET_LUT=203800
BUDGET_FF=407600
BUDGET_DSP=840
BUDGET_RAMB36=445

mkdir -p "$OUT_DIR"

require_vivado() {
  if command -v "$VIVADO" >/dev/null 2>&1; then return 0; fi
  echo "ERROR: vivado not found (looked for '$VIVADO')" >&2
  echo "  install free Vivado (2026.1 'Basic' tier covers all 7-series incl. xc7k325t)," >&2
  echo "  generate its (free) node-locked license, then either:" >&2
  echo "    source /path/to/Xilinx/<ver>/Vivado/settings64.sh   # puts vivado on PATH" >&2
  echo "    export VIVADO=/path/to/Xilinx/<ver>/Vivado/bin/vivado" >&2
  echo "  on NixOS, use the FHS sandbox:" >&2
  echo "    nix run .#vivado-fhs                     # interactive: run the installer here" >&2
  echo "    export VIVADO_SETTINGS=/path/to/Xilinx/<ver>/Vivado/settings64.sh" >&2
  echo "    export VIVADO=\"\$(nix build --no-link --print-out-paths .#vivado-fhs-vivado)/bin/vivado\"" >&2
  exit 1
}

# ---- run Vivado for the requested tcl stage (synth | route) ---------------------------
do_vivado() {
  local tcl_stage="$1"   # synth | route
  require_vivado
  [ -d "$SRC_DIR" ] || { echo "ERROR: verilog-ethernet rtl dir not found: $SRC_DIR" >&2; exit 1; }
  # A stale timing.rpt from a prior 'route' would mask a synth-only run — clear it.
  [ "$tcl_stage" = synth ] && rm -f "$TIMING"
  echo "=== fpga-10g-fit [$tcl_stage]: eth_mac_10g OOC on $PART @ ${PERIOD_NS}ns (156.25 MHz target) ==="
  echo "    vivado:  $(command -v "$VIVADO")"
  echo "    src:     $SRC_DIR"
  echo "    threads: $THREADS (host may clamp)"
  ( cd "$OUT_DIR" && "$VIVADO" -mode batch -nojournal -nolog \
      -source "$TCL" \
      -tclargs "$SRC_DIR" "$PART" "$OUT_DIR" "$PERIOD_NS" "$tcl_stage" "$THREADS" ) 2>&1 | tee "$LOG"
  grep -q '^10G_FIT_TCL_OK$' "$LOG" || { echo "ERROR: Vivado did not finish cleanly — see $LOG" >&2; exit 1; }
  [ -s "$UTIL" ] || { echo "ERROR: Vivado produced no $UTIL — see $LOG" >&2; exit 1; }
  echo "=== fpga-10g-fit [$tcl_stage]: done -> $UTIL ==="
}

# Pull the first integer in the "Used" column of a report_utilization row whose name
# matches the given regex (same parser as fpga-m3-vivado-fit).
util_count() {
  local pat="$1"
  grep -iE "\| +$pat\*? +\|" "$UTIL" 2>/dev/null | head -n1 \
    | sed -E 's/^\| *[^|]*\| *([0-9]+).*/\1/' | tr -d ' '
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

# ---- report: utilization + fit + Fmax VERDICT ----------------------------------------
do_report() {
  [ -s "$UTIL" ] || { echo "ERROR: missing $UTIL — run '$0 synth' or '$0 route' first" >&2; exit 1; }

  local luts ff dsp ramb carry
  luts="$(util_count 'CLB LUTs|Slice LUTs')"
  ff="$(util_count 'CLB Registers|Slice Registers')"
  dsp="$(util_count 'DSPs|DSP48E1')"
  ramb="$(util_count 'Block RAM Tile|RAMB36')"
  carry="$(util_count 'CARRY4')"

  echo ""
  echo "=== C5 10G MAC verify-before-buy: VERDICT ==="
  echo "part:   $PART"
  echo "DUT:    verilog-ethernet eth_mac_10g (64-bit XGMII, AXI-Stream), OOC top"
  echo "target: ${PERIOD_NS} ns period = 156.25 MHz (10G 64-bit XGMII)"
  echo ""
  printf '  %-14s %10s   / %-8s (325T)   %s\n' "resource" "used" "budget" "fit?"
  fit_line "LUT6"      "$luts"  "$BUDGET_LUT"
  fit_line "FF"        "$ff"    "$BUDGET_FF"
  fit_line "DSP48E1"   "$dsp"   "$BUDGET_DSP"
  fit_line "RAMB36"    "$ramb"  "$BUDGET_RAMB36"
  [ -n "$carry" ] && printf '  %-14s %10s\n' "CARRY4" "$carry"
  echo ""

  # ---- Fmax verdict (only meaningful after 'route') ----
  local wns="" fmax_ok="n/a"
  if [ -s "$TIMING" ]; then
    # report_timing_summary prints a "WNS(ns)" column header then the value on a later row.
    wns="$(grep -A6 -iE 'WNS\(ns\)' "$TIMING" 2>/dev/null \
            | grep -oE '\-?[0-9]+\.[0-9]+' | head -n1)"
    if [ -n "$wns" ]; then
      # WNS >= 0 -> meets the target clock. bc keeps the fractional compare honest.
      if awk "BEGIN{exit !($wns >= 0)}"; then fmax_ok=yes; else fmax_ok=no; fi
    fi
  fi

  if [ -s "$TIMING" ]; then
    echo "  timing (post-route): WNS = ${wns:-n/a} ns  -> meets 156.25 MHz: $fmax_ok"
  else
    echo "  timing: (synth-only — run 'route' or 'all' for the real WNS/Fmax)"
  fi
  echo ""

  # ---- overall RESULT ----
  local fit_ok=no
  if [ -n "$luts" ] && [ "$luts" -lt "$BUDGET_LUT" ] 2>/dev/null; then fit_ok=yes; fi

  if [ "$fit_ok" = yes ] && [ "$fmax_ok" = yes ]; then
    echo "  RESULT: 10G MAC BUILDS + FITS + meets Fmax on the 325T (LUT6 ${luts}, WNS ${wns} ns)."
    echo "          The 10G datapath is feasible on xc7k325t; the GTX/PCS-PMA transceiver"
    echo "          leg is the board-in-hand residual (refclk + serdes SI)."
  elif [ "$fit_ok" = yes ] && [ -z "$wns" ]; then
    echo "  RESULT: 10G MAC BUILDS + FITS on the 325T (LUT6 ${luts}); timing not yet routed."
    echo "          Run 'nix run .#fpga-10g-fit -- route' (or 'all') for the WNS/Fmax verdict."
  else
    echo "  RESULT: fit/timing not satisfied — LUT6 ${luts:-n/a} (budget ${BUDGET_LUT}), WNS ${wns:-n/a}." >&2
    echo "          Inspect $UTIL and $TIMING." >&2
    exit 1
  fi
}

case "$STAGE" in
  synth)  do_vivado synth ;;
  route)  do_vivado route ;;
  report) do_report ;;
  all)
    do_vivado route
    do_report
    ;;
esac
