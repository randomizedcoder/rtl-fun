# scripts/fpga-soc-vivado.sh
#
# Phase-A verify-before-buy: drive CVA6's *turnkey* full Vivado flow (synth ->
# impl -> routed bitstream -> timing) for the whole SoC + DDR3 + peripherals on
# the exact AX7325B / Genesys 2 die (xc7k325tffg900-2), with NO board. This is
# the single strongest pre-purchase datapoint: it proves our FHS-boxed Vivado
# drives the entire make (MIG IP gen, read_ip, place, route, write_bitstream)
# and that CVA6 + DDR3 *routes and closes timing* on the die at the target clock
# (we have only had out-of-context core fit before — see fpga-m3-vivado-fit).
#
# We run the *stock* pinned CVA6 tree (nix/cva6.nix), BOARD=genesys2, whose die
# is identical to the AX7325B. Running the known-good turnkey build first isolates
# "does the die/flow/license work" from "is our AX7325B port correct" (that port
# is a later phase). The tree is copied fresh from the pinned source each run, so
# the result is reproducible and independent of any writable build/cva6 checkout.
#
# The bootrom (corev_apu/fpga/src/bootrom) is compiled as part of `make fpga`, so
# a bare-metal RISC-V toolchain + dtc + python3 are needed alongside Vivado; the
# Nix wrapper puts them on PATH and points $RISCV at a merged gcc+binutils prefix.
#
#   nix run .#fpga-soc-vivado                 turnkey genesys2 build -> bit + timing
#   nix run .#fpga-soc-vivado -- genesys2     (explicit board; only genesys2 for now)
#   nix run .#fpga-soc-vivado -- clean        remove this target's build tree
#
# HOST-TOOL DEPENDENCY (documented impurity, like the other Vivado targets): Vivado
# is NOT in nixpkgs. Put `vivado` on PATH (source settings64.sh) or export $VIVADO;
# on NixOS use the FHS sandbox (nix run .#vivado-fhs). CVA6's IP sub-makes call a
# *bare* `vivado`, so this script prepends $VIVADO's dir to PATH. `nix run` passes
# the caller's env through, so this needs no --impure.
#
# NOTE for CPU-isolated hosts (isolcpus=): pin Vivado to the spare cores explicitly,
#   taskset -c 2-7 nix run .#fpga-soc-vivado
# else a normal process is confined to the non-isolated cores and Vivado crawls.
#
# Injected by the Nix wrapper: REPO_ROOT (common.sh), CVA6_SRC, RISCV_TOOLCHAIN.
set -euo pipefail

: "${REPO_ROOT:?REPO_ROOT not set — the Nix wrapper injects it via common.sh}"
: "${CVA6_SRC:?CVA6_SRC not set — the Nix wrapper injects the pinned CVA6 source}"
: "${RISCV_TOOLCHAIN:?RISCV_TOOLCHAIN not set — the Nix wrapper injects the merged toolchain prefix}"

BOARD="${1:-genesys2}"
case "$BOARD" in
  clean)
    rm -rf "${FPGA_SOC_VIVADO_OUT:-$REPO_ROOT/build/fpga-soc-vivado}"
    echo "cleaned ${FPGA_SOC_VIVADO_OUT:-$REPO_ROOT/build/fpga-soc-vivado}"
    exit 0 ;;
  genesys2) ;;
  *) echo "ERROR: board '$BOARD' not supported yet (only genesys2; the AX7325B port is a later phase)" >&2; exit 2 ;;
esac

VIVADO="${VIVADO:-vivado}"

# ---- Vivado reachable? else print the install pointer --------------------------------
require_vivado() {
  if command -v "$VIVADO" >/dev/null 2>&1; then return 0; fi
  echo "ERROR: vivado not found (looked for '$VIVADO')" >&2
  echo "  install free Vivado (2026.1 'Basic' tier covers the xc7k325t through bitstream)," >&2
  echo "  generate its (free) node-locked license, then either:" >&2
  echo "    source /path/to/Xilinx/Vivado/<ver>/settings64.sh   # puts vivado on PATH" >&2
  echo "    export VIVADO=/path/to/Xilinx/Vivado/<ver>/bin/vivado" >&2
  echo "  on NixOS use the FHS sandbox:" >&2
  echo "    export VIVADO_SETTINGS=/path/to/Xilinx/<ver>/Vivado/settings64.sh" >&2
  echo "    export VIVADO=\"\$(nix build --no-link --print-out-paths .#vivado-fhs-vivado)/bin/vivado\"" >&2
  exit 1
}
require_vivado

# CVA6's xilinx/common.mk IP sub-makes invoke a *bare* `vivado`; put $VIVADO's dir
# on PATH so those resolve to the same (boxed) Vivado as $(VIVADO).
VIVADO_BIN="$(command -v "$VIVADO")"
VIVADO_DIR="$(dirname "$VIVADO_BIN")"
export PATH="$VIVADO_DIR:$PATH"
export VIVADO="$VIVADO_BIN"

# ---- RISC-V toolchain for the bootrom compile ---------------------------------------
# The bootrom Makefile builds CC as $(RISCV)/bin/$(CROSSCOMPILE)gcc; RISCV_TOOLCHAIN is
# a merged gcc+binutils prefix (bin/riscv64-none-elf-{gcc,objcopy,...}). Its default
# CROSSCOMPILE is riscv-none-elf-, so override it to our riscv64-none-elf- toolchain.
export RISCV="$RISCV_TOOLCHAIN"
export CROSSCOMPILE="riscv64-none-elf-"
export CV_SW_PREFIX="riscv64-none-elf-"

OUT_DIR="${FPGA_SOC_VIVADO_OUT:-$REPO_ROOT/build/fpga-soc-vivado}"
WORK="$OUT_DIR/$BOARD"
TREE="$WORK/cva6"
LOG="$WORK/make-fpga.log"

# ---- materialize a fresh, writable copy of the pinned CVA6 tree ----------------------
mkdir -p "$WORK"
if [ -e "$TREE" ]; then chmod -R u+w "$TREE" 2>/dev/null || true; fi
rm -rf "$TREE"
echo "=== fpga-soc-vivado: copy pinned CVA6 tree -> $TREE ==="
# Preserve MODE (the bootrom's gen_rom.py is run via its +x shebang), drop ownership,
# then add write so `make` can drop generated files (bootrom_64.sv, dtb, work-fpga/…)
# into the otherwise read-only store copy.
cp -r --no-preserve=ownership "$CVA6_SRC" "$TREE"
chmod -R u+w "$TREE"

# Source-prep: make the flow BOARD-FILE-FREE (part-only). CVA6's prologue.tcl and every
# IP run.tcl do `set_property board_part $XILINX_BOARD`, which hard-errors unless the
# vendor's Vivado board_files are installed (Digilent's aren't here — [Board 49-71]).
# board_part is only a convenience: MIG uses an explicit XML_INPUT_FILE (.prj), clocks
# use explicit CONFIG, and pins come from the .xdc — none need the board preset. The
# part itself is set by `create_project -part $XILINX_PART`, so commenting out the
# board_part lines is loss-free. Crucially this matches the ACTUAL target: the ALINX
# AX7325B is not in Vivado's board store either, so a part-only flow is what its port
# needs. Applied to the throwaway copy each run — reproducible, no upstream edit.
find "$TREE/corev_apu/fpga/scripts" "$TREE/corev_apu/fpga/xilinx" \
  -name '*.tcl' -print0 2>/dev/null \
  | xargs -0 -r sed -i -E 's/^([[:space:]]*)set_property board_part/\1# board_part disabled (board-file-free, part-only flow): set_property board_part/'

# CVA6_REPO_DIR defaults to the tree with a warning; set it explicitly. TARGET_CFG /
# HPDCACHE_DIR / PLATFORM / part all self-default from BOARD in CVA6's Makefile.
export CVA6_REPO_DIR="$TREE"

echo "=== fpga-soc-vivado: turnkey Vivado build (BOARD=$BOARD) ==="
echo "    vivado:  $VIVADO"
echo "    riscv:   $RISCV/bin/${CROSSCOMPILE}gcc"
echo "    tree:    $TREE"
echo "    log:     $LOG"
echo "    (full synth+impl+bitstream — expect ~1-2 h; pin with taskset on isolcpus hosts)"

# `make fpga` runs: bootrom compile -> flist -> IP gen (bare vivado) -> run.tcl
# (synth, impl, write_bitstream) -> write_cfgmem (mcs). VIVADO is exported so the
# inner corev_apu/fpga Makefile's `VIVADO ?= vivado` picks up the boxed binary.
#
# CC override: CVA6 v5.3.0's bootrom src/main.c calls init_uart(freq, baud) but
# uart.h declares `void init_uart()`. Modern GCC (C23 default) reads `()` as
# `(void)` and errors; -std=gnu17 restores the K&R "unspecified args" semantics the
# code was written against. Command-line vars propagate as overrides to the bootrom
# sub-make, and the fpga path's ONLY C compile is that bootrom, so this is scoped.
set +e
( cd "$TREE" && make fpga BOARD="$BOARD" VIVADO="$VIVADO" \
    CC="$RISCV/bin/${CROSSCOMPILE}gcc -std=gnu17" ) 2>&1 | tee "$LOG"
rc="${PIPESTATUS[0]}"
set -e

# ---- collect artifacts + verdict ----------------------------------------------------
FPGA_DIR="$TREE/corev_apu/fpga"
BIT="$FPGA_DIR/work-fpga/ariane_xilinx.bit"
REPORTS="$FPGA_DIR/reports"
ART="$WORK/out"
mkdir -p "$ART"

# Preserve the bit + reports out of the throwaway tree.
[ -f "$BIT" ] && cp -f "$BIT" "$ART/" 2>/dev/null || true
[ -d "$REPORTS" ] && cp -f "$REPORTS"/*.rpt "$ART/" 2>/dev/null || true
find "$FPGA_DIR" -maxdepth 4 -name 'ariane_xilinx*.bit' -exec cp -f {} "$ART/" \; 2>/dev/null || true

echo ""
echo "=== fpga-soc-vivado: VERDICT (BOARD=$BOARD, part xc7k325tffg900-2) ==="
if [ -f "$ART/ariane_xilinx.bit" ] || [ -f "$BIT" ]; then
  echo "  BITSTREAM: OK -> $ART/ariane_xilinx.bit"
else
  echo "  BITSTREAM: NOT produced (make rc=$rc) — inspect $LOG" >&2
fi

# Surface worst-case slack (WNS) from the post-impl timing report.
TIMING="$ART/ariane.timing.rpt"
[ -f "$TIMING" ] || TIMING="$(find "$REPORTS" -name '*.timing.rpt' 2>/dev/null | head -n1 || true)"
if [ -n "${TIMING:-}" ] && [ -f "$TIMING" ]; then
  slack="$(grep -m1 -iE 'Slack \(' "$TIMING" | sed -E 's/.*Slack[^-0-9]*(-?[0-9.]+).*/\1/' || true)"
  if [ -n "$slack" ]; then
    echo "  TIMING:    worst-path slack = ${slack} ns  ($TIMING)"
    case "$slack" in
      -*) echo "  RESULT:    NEGATIVE slack — timing NOT met at the target clock; inspect $TIMING" >&2 ;;
      *)  echo "  RESULT:    positive slack — CVA6 + DDR3 routes and MEETS timing on the die." ;;
    esac
  else
    echo "  TIMING:    report at $TIMING (could not parse slack)"
  fi
else
  echo "  TIMING:    no timing report found under $REPORTS" >&2
fi

exit "$rc"
