# Build and run pm-trace: single-step tracer for the golden parser model.
#
# Body for the `pm-trace` writeShellApplication (nix/model.nix). Compiles the
# tracer against libparsermodel and forwards any args (an optional pcap path).
#
# Run:  nix run .#pm-trace              # canned eth+ipv4+tcp frame
#       nix run .#pm-trace -- x.pcap    # first packet of a classic pcap

MODEL_ROOT="${MODEL_ROOT:-$PWD}"
SRC="$MODEL_ROOT/model"

if [ ! -d "$SRC/libparsermodel" ]; then
  echo "pm-trace: $SRC/libparsermodel not found — run from the repo root" >&2
  exit 2
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

cc -std=c11 -O2 -Wall -Wextra \
  -I "$SRC/libparsermodel" \
  "$MODEL_ROOT/tools/pm-trace/pm-trace.c" \
  "$SRC/libparsermodel/parser.c" \
  "$SRC/libparsermodel/program.c" \
  "$SRC/libparsermodel/pcap.c" \
  -o "$OUT/pm-trace"

"$OUT/pm-trace" "$@"
