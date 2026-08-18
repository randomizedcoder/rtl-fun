#!/usr/bin/env bash
#
# scripts/cva6-baseline.sh — Phase 0 baseline: build the stock CVA6 Verilator model.
#
# This is the *body* of the `cva6-baseline` app. It is packaged as a Nix
# writeShellApplication (nix/cva6-baseline.nix), which puts the tools on PATH and
# runs shellcheck at build time. Preferred entry point:
#
#   nix run .#cva6-baseline
#
# It also runs standalone inside `nix develop` (it falls back to discovering the
# store paths itself).
#
# Proves the toolchain integration end-to-end: the pinned CVA6 source ($CVA6_SRC,
# fetched via Nix), our Verilator, the bare-metal RISC-V toolchain, and Spike's
# DPI libraries all compose into a working `Variane_testharness` simulator.
#
# Inputs (set by the Nix wrapper; auto-discovered otherwise):
#   CVA6_SRC       pinned CVA6 source tree (read-only nix store path)
#   SPIKE_PREFIX   Spike install prefix (include/, lib/ with libfesvr/libriscv/…)
#   YAMLCPP        yaml-cpp install prefix (include/, lib/)
# Optional:
#   CVA6_WORK (default ./build/cva6), CVA6_TARGET (default cv64a6_imafdc_sv39),
#   NUM_JOBS (default nproc)
#
# Output: $CVA6_WORK/cva6/work-ver/Variane_testharness
#
set -euo pipefail

# --- inputs (wrapper-provided, with dev-shell fallbacks) --------------------
# Build under $PWD (run from the repo root); when packaged as a Nix app the
# script lives read-only in the store, so we must not build relative to it.
# $WORK holds the assembled prefix + a writable source copy; the source lands at
# $WORK/cva6, so keep $WORK at build/ (not build/cva6) to avoid build/cva6/cva6.
WORK="${CVA6_WORK:-$PWD/build}"
TARGET="${CVA6_TARGET:-cv64a6_imafdc_sv39}" # RV64GC-class (matches ADR-001)
NUM_JOBS="${NUM_JOBS:-$(nproc)}"

: "${CVA6_SRC:?CVA6_SRC not set — run 'nix run .#cva6-baseline' or set it in the dev shell}"
SPIKE_PREFIX="${SPIKE_PREFIX:-$(dirname "$(dirname "$(command -v spike)")")}"
if [ -z "${YAMLCPP:-}" ]; then
  YAMLCPP="$(nix eval --raw nixpkgs#yaml-cpp)"
fi

echo "== CVA6 baseline =="
echo "  source : $CVA6_SRC"
echo "  work   : $WORK"
echo "  target : $TARGET"
echo "  jobs   : $NUM_JOBS"
echo "  spike  : $SPIKE_PREFIX"
echo "  yaml   : $YAMLCPP"

# --- assemble a unified $RISCV / $SPIKE_INSTALL_DIR prefix -------------------
# CVA6's build wants a single install prefix; nixpkgs scatters the toolchain,
# Spike, and yaml-cpp across store paths, so merge them via a symlink tree.
PREFIX="$WORK/riscv-prefix"
# cp -rs below inherits the read-only store dir perms, so make a prior prefix
# writable before removing it.
if [ -e "$PREFIX" ]; then chmod -R u+w "$PREFIX" 2>/dev/null || true; fi
rm -rf "$PREFIX"
mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/include"

# toolchain binaries (riscv64-none-elf-*), resolved from PATH. Explicit list
# (compgen isn't available in the non-interactive packaged shell); covers what
# CVA6's sim uses (nm for tohost, objcopy/objdump, gcc/as/ld for test programs).
for tool in gcc g++ cpp as ld nm objcopy objdump ar ranlib strip size readelf gcov; do
  src="$(command -v "riscv64-none-elf-$tool" || true)"
  [ -n "$src" ] && ln -sf "$src" "$PREFIX/bin/riscv64-none-elf-$tool"
done

# Spike + yaml-cpp headers/libs (cp -rs = symlink tree)
cp -rsf "$SPIKE_PREFIX/include/." "$PREFIX/include/"
cp -rsf "$SPIKE_PREFIX/lib/." "$PREFIX/lib/" 2>/dev/null || true
cp -rsf "$YAMLCPP/include/." "$PREFIX/include/"
for so in "$YAMLCPP"/lib/libyaml-cpp*; do
  ln -sf "$so" "$PREFIX/lib/$(basename "$so")"
done
# cp -rs inherited store dir perms (read-only); make writable so a later run
# can clean it.
chmod -R u+w "$PREFIX" 2>/dev/null || true

export RISCV="$PREFIX"
export SPIKE_INSTALL_DIR="$PREFIX"
export CV_SW_PREFIX="riscv64-none-elf-"

# --- copy source to a writable tree and build -------------------------------
rm -rf "$WORK/cva6"
mkdir -p "$WORK"
cp -r --no-preserve=mode,ownership "$CVA6_SRC" "$WORK/cva6"
cd "$WORK/cva6"

# CVA6 v5.3.0's root `make verilate` links none of the DPI elf-loader sources, so
# the testharness fails with undefined references. The DPI shims (read_elf /
# get_section / read_section_void / read_symbol) live in the vendored spike
# fesvr_dpi.cc, which in turn calls load_elf() from the vendored fesvr
# elfloader.cc. Add both (same vendored tree = self-consistent signatures); other
# fesvr symbols like memif_t resolve fine against the nixpkgs libfesvr we link.
# They resolve their own #include "elf.h"/"htif.h"/… from their sibling headers.
# (Upstream builds the sim via its core-v-verif flow; the bare root target is
# under-maintained here.)
#
# SKIP this entirely under SPIKE_TANDEM: the tandem Spike (nix/spike-tandem.nix)
# builds fesvr_dpi.cc + elfloader.cc INTO its own libfesvr, and the verilate
# LDFLAGS already link -lfesvr against that tandem prefix. Re-adding the same
# sources to the --exe list would double-define read_elf/get_section/load_elf at
# link (R2). Under tandem the DPI shims resolve straight out of libfesvr.so.
if [ -z "${SPIKE_TANDEM:-}" ]; then
  FESVR_DIR="verif/core-v-verif/vendor/riscv/riscv-isa-sim/fesvr"
  FESVR_SRCS="$FESVR_DIR/fesvr_dpi.cc $FESVR_DIR/elfloader.cc"
  if ! grep -q 'fesvr_dpi.cc' Makefile; then
    sed -i "s#corev_apu/tb/dpi/msim_helper.cc#corev_apu/tb/dpi/msim_helper.cc $FESVR_SRCS#" Makefile
    echo "== patched Makefile: added fesvr_dpi.cc + elfloader.cc to verilate --exe list =="
  fi
  # fesvr_dpi.cc does #include "config.h"/"elf.h"/"htif.h"/… ; nixpkgs keeps the
  # fesvr headers under include/fesvr/, which isn't on the active CFLAGS block
  # (Makefile lines ~143-148, ending "corev_apu/tb/dpi -O3"). Append the resolved
  # include path there — a real path, so no literal Makefile $(...) in the sed.
  if ! grep -q "$PREFIX/include/fesvr" Makefile; then
    sed -i "s#corev_apu/tb/dpi -O3#corev_apu/tb/dpi -O3 -I$PREFIX/include/fesvr#" Makefile
    echo "== patched Makefile: added $PREFIX/include/fesvr to CFLAGS =="
  fi
fi

echo "== verilator: $(verilator --version) =="
echo "== running 'make verilate' (this is the long step)${SPIKE_TANDEM:+ — SPIKE_TANDEM} =="
# ${SPIKE_TANDEM:+SPIKE_TANDEM=1} is empty (byte-identical to the stock command)
# unless SPIKE_TANDEM is set; when set it flips the Makefile's tandem gate
# (spike-tandem ?= $(SPIKE_TANDEM)), pulling in the RVFI-vs-Spike lock-step SV.
make verilate target="$TARGET" NUM_JOBS="$NUM_JOBS" ${SPIKE_TANDEM:+SPIKE_TANDEM=1}

BIN="$WORK/cva6/work-ver/Variane_testharness"
if [ -x "$BIN" ]; then
  echo "== SUCCESS =="
  echo "model: $BIN"
  ls -la "$BIN"
else
  echo "== verilate finished but model not found at $BIN ==" >&2
  find "$WORK/cva6" -name "Variane_testharness" -type f 2>/dev/null || true
  exit 1
fi
