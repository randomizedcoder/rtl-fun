# scripts/lib/common.sh — shared helpers for the parser runner scripts.
#
# Sourced in the dev shell, or `builtins.readFile`-prepended by the Nix wrappers
# (same concatenation model as cva6-baseline.sh) ahead of a runner body. It holds
# the pieces the runners used to copy-paste: the canonical repo paths + toolchain,
# the golden-model vector-generator build+invoke, the bare-metal RISC-V link, the
# model run+SUCCESS gate, and the shared Verilator flag set — each in ONE place so
# the targets cannot drift.
#
# It deliberately does NOT `set -euo pipefail`: the runner bodies own that, so
# sourcing this into an interactive dev shell can't turn on errexit there.

# --- canonical paths (overridable; default to a repo-root run) ---------------
REPO_ROOT="${REPO_ROOT:-$PWD}"
RTL="${RTL:-$REPO_ROOT/rtl}"
TB="${TB:-$REPO_ROOT/tb}"
VERIF="${VERIF:-$REPO_ROOT/verif}"
MODEL="${MODEL:-$REPO_ROOT/model/libparsermodel}"
GEN_SRC="${GEN_SRC:-$VERIF/gen/gen_parser_rom.c}"

# riscv cross-gcc for the in-core tests; CV_SW_PREFIX overrides the triple.
GCC="${GCC:-${CV_SW_PREFIX:-riscv64-none-elf-}gcc}"

# Shared Verilator flags: bug-class lints stay fatal; UNUSEDPARAM/UNUSEDSIGNAL
# are waived (the package defines the full ISA vocabulary and datapath
# temporaries are intentionally wider than one use); assertions on so
# parser_asserts.svh runs in every sim.
# shellcheck disable=SC2034  # used by the sim/wrap consumers, not the cosim ones
PARSER_VFLAGS=(
  -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET
  --assert +define+PARSER_ASSERT
)

# gen_vectors <out_dir> [gen_args...]
#   Compile the golden-model vector generator into <out_dir> and run it there.
#   With --suite it emits the whole directed suite (cases/, cases.txt); without,
#   the single baseline case. This is THE single source of truth feeding both the
#   standalone RTL suite and the in-core cosim.
gen_vectors() {
  local out="$1"; shift
  cc -std=c11 -O2 -Wall -Wextra -I "$MODEL" \
    "$GEN_SRC" "$MODEL/parser.c" "$MODEL/program.c" "$MODEL/encoding.c" "$MODEL/pcap.c" \
    -o "$out/gen_parser_rom"
  "$out/gen_parser_rom" "$out" "$@"
}

# Include dirs for rv_assemble (each becomes a -I). Callers override per-link.
RV_INCLUDES=()

# rv_assemble <out.elf> <ldscript> <src...>
#   Link bare-metal RV64GC sources into an ELF, adding a -I for each RV_INCLUDES.
rv_assemble() {
  local elf="$1" ld="$2"; shift 2
  local cmd=("$GCC" -march=rv64gc -mabi=lp64d -nostdlib -nostartfiles) d
  for d in "${RV_INCLUDES[@]}"; do cmd+=(-I "$d"); done
  cmd+=(-T "$ld" "$@" -o "$elf")
  "${cmd[@]}"
}

# run_model <elf> <log>
#   Run the patched CVA6 model on <elf>, capturing all output to <log>, bounded by
#   MAXCYC. Sets MODEL_RC to the model's exit code WITHOUT tripping errexit, so the
#   caller can inspect both rc and the log. Honors BIN (Variane_testharness).
run_model() {
  local elf="$1" log="$2"
  set +e
  "$BIN" "$elf" "+max-cycles=$MAXCYC" >"$log" 2>&1
  # shellcheck disable=SC2034  # read by the cosim/test consumers as MODEL_RC
  MODEL_RC=$?
  set -e
}

# model_success <log> — true iff the fesvr SUCCESS banner is present.
model_success() { grep -q '\*\*\* SUCCESS \*\*\*' "$1"; }
