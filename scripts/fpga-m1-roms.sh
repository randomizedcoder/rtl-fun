# scripts/fpga-m1-roms.sh — generate the M1 on-chip ROM images from the golden model.
#
#   nix run .#fpga-m1-roms            regenerate roms/m1/*.hex from libparsermodel
#   nix run .#fpga-m1-roms -- --check verify the committed roms/m1 has not drifted
#
# M1 (docs/phase-8-fpga.md §8.4) bakes ONE packet + its parse program + CAM into
# on-chip ROM and streams the resulting flow_keys over UART. Those ROM images are
# the SAME vectors the Verilator suite runs, produced by verif/gen/gen_parser_rom.c
# via the shared gen_vectors helper — one source of truth, the model. Committing the
# generated files (rather than hand-copying build/parser/) makes the bitstream
# reproducible AND recorded; --check is the drift guard, mirroring parser-gen-check.
#
# common.sh (REPO_ROOT / MODEL / VERIF / gen_vectors) is prepended by the Nix wrapper.
set -euo pipefail

ROMS="$REPO_ROOT/fpga/tang-mega-138k-pro/roms/m1"
# The five files parser_top / the host oracle need. gen_parser_rom emits more
# (enc.hex, camprog.hex, packet.hex); M1 uses only these.
FILES=(program.hex cam.hex pktbuf.hex params.hex expected.hex)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Baseline case only (no --suite): eth/ipv4/tcp, the M1 packet.
gen_vectors "$tmp" >/dev/null

for f in "${FILES[@]}"; do
  [ -r "$tmp/$f" ] || { echo "fpga-m1-roms: generator did not emit $f" >&2; exit 1; }
done

# Human-readable summary of what this ROM set is (params.hex = 3 x 32-bit hex words).
pkt_len=$((16#$(sed -n 1p "$tmp/params.hex")))
meta_len=$((16#$(sed -n 2p "$tmp/params.hex")))
exp_raw=$(sed -n 3p "$tmp/params.hex")
echo "fpga-m1-roms: baseline eth/ipv4/tcp — PKT_LEN=$pkt_len META_LEN=$meta_len EXP_CODE=0x$exp_raw"

if [ "${1:-}" = "--check" ] || [ "${1:-}" = "check" ]; then
  fail=0
  for f in "${FILES[@]}"; do
    if ! diff -q "$ROMS/$f" "$tmp/$f" >/dev/null 2>&1; then
      echo "  DRIFT: roms/m1/$f differs from a fresh model regeneration"
      fail=1
    fi
  done
  if [ "$fail" -ne 0 ]; then
    echo "fpga-m1-roms: FAIL — committed ROM drifted from the model."
    echo "  Refresh with:  nix run .#fpga-m1-roms"
    exit 1
  fi
  echo "fpga-m1-roms: OK — committed roms/m1 matches the model byte-for-byte."
else
  mkdir -p "$ROMS"
  for f in "${FILES[@]}"; do cp -f "$tmp/$f" "$ROMS/$f"; done
  echo "fpga-m1-roms: wrote ${#FILES[@]} files to fpga/tang-mega-138k-pro/roms/m1/"
  echo "  build with:  nix run .#fpga-build -- m1"
fi
