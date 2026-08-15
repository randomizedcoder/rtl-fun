# Build and run the golden parser-model test suite (Phase 2).
#
# Body for the `model-test` writeShellApplication (nix/model.nix). Compiles
# libparsermodel + the dependency-free test harness and runs it. CORPUS_DIR is
# injected by the Nix wrapper to the pinned xdp2 proto_audit pcap_templates, so
# the corpus smoke tests are reproducible; override CORPUS_DIR to point elsewhere.
#
# Run:  nix run .#model-test        (from the repo root)

MODEL_ROOT="${MODEL_ROOT:-$PWD}"
SRC="$MODEL_ROOT/model"

if [ ! -d "$SRC/libparsermodel" ]; then
  echo "model-test: $SRC/libparsermodel not found — run from the repo root" >&2
  exit 2
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

cc -std=c11 -O2 -Wall -Wextra -Werror \
  -I "$SRC/libparsermodel" \
  "$SRC/test/test_main.c" \
  "$SRC/libparsermodel/parser.c" \
  "$SRC/libparsermodel/program.c" \
  "$SRC/libparsermodel/pcap.c" \
  -o "$OUT/pm-test"

echo "CORPUS_DIR=${CORPUS_DIR:-<unset>}"
"$OUT/pm-test"
