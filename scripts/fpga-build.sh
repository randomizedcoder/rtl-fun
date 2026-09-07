# scripts/fpga-build.sh — synthesize a board design with Gowin EDA in the microVM.
#
#   nix run .#fpga-build                     # default: the blinky design
#   FPGA_TCL=/work/fpga/.../other.tcl nix run .#fpga-build
#
# Gowin EDA cannot run on the host (node-locked license + a prebuilt Qt closure),
# so it runs inside the microVM from nix/gowin-vm.nix, which presents the licensed
# MAC on a QEMU user-mode NIC. This script drops a RUN_TCL marker in the shared
# /work tree, boots the VM headless, and the gowin-gate service runs gw_sh and
# powers off. See docs/gowin-microvm.md.
#
# The VM needs --impure because nix/gowin-vm.nix reads GOWIN_VM_LOCAL (machine-local
# paths + the licensed MAC, gitignored). That impurity stays here rather than
# leaking into the flake's pure outputs.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$PWD}"

# Paths as the GUEST sees them: the repo is 9p-mounted at /work.
FPGA_TCL="${FPGA_TCL:-/work/fpga/tang-mega-138k-pro/blinky.tcl}"
FPGA_OUTDIR="${FPGA_OUTDIR:-/work/build/fpga-blinky}"

# Same paths as the HOST sees them, for the marker + result reporting.
host_outdir="${FPGA_OUTDIR/#\/work/$REPO_ROOT}"
marker_dir="$REPO_ROOT/build/gowin"

local_nix="${GOWIN_VM_LOCAL:-$REPO_ROOT/nix/gowin/local.nix}"
if [ ! -r "$local_nix" ]; then
  cat >&2 <<EOF
ERROR: no machine-local Gowin config at $local_nix

It carries the license-locked MAC and host paths and is gitignored on purpose.
Copy the template and edit it:

    cp nix/gowin/local.example.nix nix/gowin/local.nix

  mac          must equal HOST_ID in ./gowin, in colon form
  gowinInstall the Gowin IDE tree — use a store path from nix/gowin-eda.nix:
                 nix build --no-link --print-out-paths .#gowin-eda-edu
  repoRoot     $REPO_ROOT
EOF
  exit 1
fi

if [ ! -r "$REPO_ROOT/gowin" ]; then
  echo "ERROR: no Gowin license at $REPO_ROOT/gowin (gitignored; node-locked)." >&2
  exit 1
fi

mkdir -p "$marker_dir" "$host_outdir"

# Leftover markers would make the VM run the wrong job and power off.
rm -f "$marker_dir/RUN_GATE" "$marker_dir/RUN_CVA6"
{
  echo "tcl=$FPGA_TCL"
  echo "outdir=$FPGA_OUTDIR"
} > "$marker_dir/RUN_TCL"

echo "=== Gowin synthesis in the microVM ==="
echo "  tcl    : $FPGA_TCL"
echo "  outdir : $host_outdir"
echo "  local  : $local_nix"
echo "The VM boots, runs gw_sh, tees to gowin.log, and powers itself off."
echo

GOWIN_VM_LOCAL="$local_nix" nix run --impure "$REPO_ROOT#gowin-vm" || true

# The VM powers off regardless of gw_sh's fate, so the log is the source of truth.
log="$host_outdir/gowin.log"
if [ ! -r "$log" ]; then
  echo "RESULT: FAIL — no $log; the VM did not reach the gowin-gate service." >&2
  rm -f "$marker_dir/RUN_TCL"
  exit 1
fi

echo
echo "=== tail of $log ==="
tail -25 "$log"
echo

mapfile -t bitstreams < <(find "$host_outdir" -name '*.fs' -type f | sort)
if [ "${#bitstreams[@]}" -eq 0 ]; then
  echo "RESULT: FAIL — no .fs produced. Full log: $log"
  exit 1
fi

echo "RESULT: PASS — bitstream(s):"
printf '  %s\n' "${bitstreams[@]}"
echo
echo "Load it with:  nix run .#fpga-load -- ${bitstreams[0]}"
