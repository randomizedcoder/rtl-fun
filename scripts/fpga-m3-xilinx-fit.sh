# scripts/fpga-m3-xilinx-fit.sh
#
# M3a verify-before-buy: prove stock CVA6 (cv64a6_imafdc_sv39) fits and ROUTES on
# Xilinx 7-series (xc7k325t / Digilent Genesys 2) using the fully open-source
# openXC7 flow — no Vivado, no license, no board. This is what settles the M3a
# pivot verdict (docs/phase-8-status.md §"M3a — fit verdict") with a real
# LUT6/FF/DSP/BRAM count and a routed place-and-route, before spending money.
#
# Toolchain (all pinned via nixpkgs, injected by nix/fpga-m3-xilinx.nix):
#   yosys 0.68           synth_xilinx -family xc7  -> LUT6/FF/DSP/BRAM + JSON
#   nextpnr-xilinx       place & route on the real xc7k325t chip database
#   pypy3 + bbaexport.py bbasm  -> the nextpnr chip database (from bundled prjxray-db)
#
# Stages (arg 1, default "all"):
#   chipdb   build the xc7k325tffg900 nextpnr chip database (cached, ~460 MB, ~10 min)
#   synth    synth_xilinx the cva6_fit_top harness -> utilization + nextpnr JSON
#   pnr      nextpnr-xilinx place & route -> routed fasm + Fmax
#   all      chipdb, then synth, then pnr, then a one-line verdict
#
# Inputs:
#   build/fpga-m3-core-rtl/elab.il   elaborated CVA6 checkpoint (module \cva6);
#                                    produced by `nix run .#fpga-m3-core-rtl -- s2`
#   fpga/genesys2/cva6_fit_top.v     the register-ring fit harness (committed)
#   fpga/genesys2/cva6_fit_top.xdc   pin constraints (committed)
#
# Output: build/fpga-m3-xilinx/  (JSON, stat, chipdb, fasm, logs — build artifacts)
#
# Injected by the Nix wrapper: REPO_ROOT (common.sh), NEXTPNR_XILINX (store path).
set -euo pipefail

STAGE="${1:-all}"
case "$STAGE" in all|chipdb|synth|pnr) ;; *) echo "ERROR: unknown stage '$STAGE' (want all|chipdb|synth|pnr)" >&2; exit 2 ;; esac

: "${REPO_ROOT:?REPO_ROOT not set — the Nix wrapper injects it via common.sh}"
: "${NEXTPNR_XILINX:?NEXTPNR_XILINX not set — the Nix wrapper injects the nextpnr-xilinx store path}"

PART="${XILINX_PART:-xc7k325tffg900-2}"
DBPART="${PART%-*}"                       # strip speedgrade: xc7k325tffg900
FREQ_MHZ="${FREQ_MHZ:-50}"

OUT_DIR="${FPGA_M3_XILINX_OUT:-$REPO_ROOT/build/fpga-m3-xilinx}"
ELAB="${FPGA_M3_ELAB:-$REPO_ROOT/build/fpga-m3-core-rtl/elab.il}"
HARNESS="$REPO_ROOT/fpga/genesys2/cva6_fit_top.v"
XDC="$REPO_ROOT/fpga/genesys2/cva6_fit_top.xdc"

BBAEXPORT="$NEXTPNR_XILINX/share/nextpnr/python/bbaexport.py"
CHIPDB="$OUT_DIR/chipdb/$DBPART.bin"
JSON="$OUT_DIR/cva6_fit_top.json"
STAT="$OUT_DIR/cva6_fit_top.stat.txt"
FASM="$OUT_DIR/cva6_fit_top.fasm"

mkdir -p "$OUT_DIR/chipdb"

# ---- chipdb: the nextpnr chip database for our exact part (cached) --------------------
do_chipdb() {
  if [ -s "$CHIPDB" ]; then
    echo "=== chipdb: $CHIPDB exists ($(du -h "$CHIPDB" | cut -f1)) — skipping (rm to rebuild) ==="
    return 0
  fi
  local bba="$OUT_DIR/$DBPART.bba"
  echo "=== chipdb: bbaexport $PART (pypy3; ~10 min, ~7 GB RAM) ==="
  pypy3 "$BBAEXPORT" --device "$PART" --bba "$bba"
  echo "=== chipdb: bbasm -> $CHIPDB ==="
  bbasm -l "$bba" "$CHIPDB"
  rm -f "$bba"
  echo "=== chipdb: done ($(du -h "$CHIPDB" | cut -f1)) ==="
}

# ---- synth: synth_xilinx the fit harness -> utilization + nextpnr JSON ----------------
do_synth() {
  if [ ! -s "$ELAB" ]; then
    echo "ERROR: missing $ELAB" >&2
    echo "  produce the elaborated CVA6 checkpoint first:" >&2
    echo "    nix run .#fpga-m3-core-rtl -- s2" >&2
    exit 1
  fi
  echo "=== synth: synth_xilinx -family xc7 (cva6_fit_top; rvfi pruned) -> $JSON ==="
  # read_rtlil brings in the elaborated \cva6; read_verilog adds the harness that
  # instantiates it; hierarchy links them; synth_xilinx maps to LUT6/FDRE/DSP48/RAMB.
  yosys -l "$OUT_DIR/synth.log" -p "
    read_rtlil $ELAB;
    read_verilog $HARNESS;
    hierarchy -top cva6_fit_top;
    synth_xilinx -family xc7 -flatten -abc9 -top cva6_fit_top;
    write_json $JSON;
    tee -o $STAT stat -top cva6_fit_top
  "
  echo "=== synth: utilization ==="
  grep -iE "Number of cells|LUT[0-9]?|FD[CPRSE]+|CARRY4|DSP48|RAMB(18|36)|MUXF[78]|IBUF|OBUF|BUFG" "$STAT" || true
}

# ---- pnr: nextpnr-xilinx place & route -> routed fasm + Fmax --------------------------
do_pnr() {
  [ -s "$JSON" ]   || { echo "ERROR: missing $JSON — run '$0 synth' first" >&2; exit 1; }
  [ -s "$CHIPDB" ] || { echo "ERROR: missing $CHIPDB — run '$0 chipdb' first" >&2; exit 1; }
  echo "=== pnr: nextpnr-xilinx place & route on $PART (target ${FREQ_MHZ} MHz) ==="
  nextpnr-xilinx \
    --chipdb "$CHIPDB" \
    --xdc "$XDC" \
    --json "$JSON" \
    --fasm "$FASM" \
    --freq "$FREQ_MHZ" \
    --timing-allow-fail \
    --log "$OUT_DIR/pnr.log"
  echo "=== pnr: utilization + timing ==="
  grep -iE "Info: Device utilisation|SLICE_L|SLICE_M|SLICE_[XL]|[0-9]+/[0-9]+ +[0-9]+%|Max frequency|Max delay|Critical path" "$OUT_DIR/pnr.log" || true
  echo "=== pnr: routed fasm -> $FASM ($(du -h "$FASM" 2>/dev/null | cut -f1)) ==="
}

case "$STAGE" in
  chipdb) do_chipdb ;;
  synth)  do_synth  ;;
  pnr)    do_pnr    ;;
  all)
    do_chipdb
    do_synth
    do_pnr
    echo ""
    echo "=== M3a Xilinx verify-before-buy: VERDICT ==="
    echo "part: $PART   harness: cva6_fit_top (stock cv64a6_imafdc_sv39, rvfi pruned)"
    grep -iE "Number of cells|LUT|FD[CPRSE]|DSP48|RAMB(18|36)" "$STAT" 2>/dev/null | sed 's/^/  util: /' || true
    grep -iE "Max frequency" "$OUT_DIR/pnr.log" 2>/dev/null | sed 's/^/  /' || true
    if [ -s "$FASM" ]; then
      echo "  RESULT: ROUTES on $PART (fasm written) — CVA6 fits & place-and-routes on Kintex-7."
    else
      echo "  RESULT: PnR did not produce a fasm — see $OUT_DIR/pnr.log" >&2
      exit 1
    fi
    ;;
esac
