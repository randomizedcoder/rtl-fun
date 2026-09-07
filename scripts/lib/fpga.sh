# scripts/lib/fpga.sh — shared helpers for the Tang Mega 138K Pro runners (Phase 8).
#
# Sourced in the dev shell, or `builtins.readFile`-prepended by the Nix wrappers in
# nix/fpga.nix (same concatenation model as scripts/lib/common.sh). Like common.sh
# it deliberately does NOT `set -euo pipefail` — the runner bodies own that.
#
# Board: Sipeed Tang Mega 138K Pro, Gowin GW5AST-LV138FPG676AC1/I0.
# Debugger: one FTDI 0403:6010 exposing TWO interfaces —
#   interface A -> /dev/ttyUSB0 -> JTAG  (openFPGALoader claims this via libftdi)
#   interface B -> /dev/ttyUSB1 -> UART
# It is a BL616 emulating an FT2232D, so MPSSE is firmware emulation; if JTAG is
# flaky, lower FPGA_FREQ before suspecting the board.

# --- board constants ---------------------------------------------------------

# openFPGALoader's board profile: src/board.hpp has
#   JTAG_BOARD("tangmega138k", "", "ft2232", SPI_FLASH, 0, 0, CABLE_DEFAULT)
# There is no separate "pro" entry; the Pro uses the same FT2232 cable definition.
FPGA_BOARD="${FPGA_BOARD:-tangmega138k}"

# Expected JTAG IDCODE. src/part.hpp:448 maps this to Gowin GW5AST GW5AST-138.
FPGA_IDCODE="${FPGA_IDCODE:-0x0001081b}"

# Optional MPSSE clock override, e.g. FPGA_FREQ=1M. Empty = openFPGALoader default.
FPGA_FREQ="${FPGA_FREQ:-}"

# The UART side of the same debugger (interface B). Not used by these runners yet
# — recorded here so the hello-world step has one place to look.
FPGA_UART="${FPGA_UART:-/dev/ttyUSB1}"

# --- openFPGALoader wrapper --------------------------------------------------

# The binary. Defaults to whatever is on PATH (nixpkgs 1.1.1 via nix/packages.nix).
# Override to test the fork without editing the flake:
#   OPENFPGALOADER=$(nix build --no-link --print-out-paths .#openfpgaloader-fork)/bin/openFPGALoader
OPENFPGALOADER="${OPENFPGALOADER:-openFPGALoader}"

# ofl <args...> — invoke openFPGALoader for this board, with --freq if requested.
ofl() {
  local args=(-b "$FPGA_BOARD")
  [ -n "$FPGA_FREQ" ] && args+=(--freq "$FPGA_FREQ")
  echo "+ $OPENFPGALOADER ${args[*]} $*" >&2
  "$OPENFPGALOADER" "${args[@]}" "$@"
}

# fpga_preflight — fail early and legibly on the two things that actually go wrong.
fpga_preflight() {
  if ! command -v "$OPENFPGALOADER" >/dev/null 2>&1 && [ ! -x "$OPENFPGALOADER" ]; then
    echo "ERROR: openFPGALoader not found ($OPENFPGALOADER)." >&2
    echo "  Enter the dev shell (nix develop) or set OPENFPGALOADER=/path/to/openFPGALoader." >&2
    return 1
  fi

  # The board is one FTDI device; if it is not on the bus nothing else matters.
  if command -v lsusb >/dev/null 2>&1 && ! lsusb -d 0403:6010 >/dev/null 2>&1; then
    echo "ERROR: no FTDI 0403:6010 on the USB bus." >&2
    echo "  Check the 12 V supply, the power switch, and the USB cable in the" >&2
    echo "  'USB JTAG&UART' port (NOT the SOFT-USB port, which stays dark until a" >&2
    echo "  design implementing USB is loaded)." >&2
    return 1
  fi
  return 0
}

# fpga_resolve_fs <path> — echo an absolute path to a .fs bitstream, or fail.
# Accepts either the .fs itself or a directory containing exactly one.
fpga_resolve_fs() {
  local arg="$1"
  local -a matches
  if [ -z "$arg" ]; then
    echo "ERROR: no bitstream given." >&2
    echo "  usage: <runner> <path-to.fs>" >&2
    return 1
  fi
  if [ -d "$arg" ]; then
    mapfile -t matches < <(find "$arg" -maxdepth 1 -name '*.fs' -type f | sort)
    if [ "${#matches[@]}" -ne 1 ]; then
      echo "ERROR: expected exactly one .fs in $arg, found ${#matches[@]}." >&2
      printf '  %s\n' "${matches[@]}" >&2
      return 1
    fi
    arg="${matches[0]}"
  fi
  if [ ! -r "$arg" ]; then
    echo "ERROR: bitstream not readable: $arg" >&2
    return 1
  fi
  readlink -f "$arg"
}

# fpga_perm_hint — printed on failure; permissions are the #1 cause.
fpga_perm_hint() {
  cat >&2 <<'HINT'

If this failed with a permission/claim error, check host access first:
  - `id` should list BOTH `dialout` and `plugdev`
  - /dev/bus/usb/001/<dev> must be group-writable by plugdev
On hp5 that is configured by ~/nixos/hp/hp5/fpga.nix; after a
`sudo nixos-rebuild switch` you must REPLUG the board (udev only applies
its rules on the next add event) and re-login for the new groups.

If instead it enumerated but JTAG did not respond, the debugger is a BL616
emulating an FT2232D, so try a slower MPSSE clock:
  FPGA_FREQ=1M <runner> ...
HINT
}
