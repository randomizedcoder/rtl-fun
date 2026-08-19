# Regenerate the Phase-7 toolchain artifacts and prove they haven't drifted.
#
# Body for the `parser-gen-check` writeShellApplication (nix/parser-gen.nix). Two
# checks: (1) re-running tools/parser-gen over isa/parser-opcodes.yaml reproduces
# the committed toolchain/generated/ byte-for-byte (regen is deterministic and the
# tree is up to date); (2) the generated encoders match the model's hand-written
# encoders + the golden constants (verif/gen/parser_gen_check.c) — the yaml↔C
# drift guard the round-trip tests can't provide.
#
# Run:  nix run .#parser-gen-check     (from the repo root)

set -euo pipefail

ROOT="${REPO_ROOT:-$PWD}"
GEN="$ROOT/tools/parser-gen/parser_gen.py"
YAML="$ROOT/isa/parser-opcodes.yaml"
COMMITTED="$ROOT/toolchain/generated"
MODEL="$ROOT/model/libparsermodel"
CHECK_SRC="$ROOT/verif/gen/parser_gen_check.c"
PY="${PARSER_GEN_PY:-python3}"
CC="${CC:-cc}"

if [ ! -f "$YAML" ]; then
  echo "parser-gen-check: $YAML not found — run from the repo root" >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== regenerate from isa/parser-opcodes.yaml =="
"$PY" "$GEN" "$YAML" "$TMP/generated"

echo "== check committed toolchain/generated is up to date (byte-stable) =="
if ! diff -ru "$COMMITTED" "$TMP/generated"; then
  echo "parser-gen-check: toolchain/generated is stale — re-run tools/parser-gen and commit the result" >&2
  exit 1
fi
echo "  ok: committed artifacts match a fresh regeneration"

echo "== drift guard: generated encoders == model encoders + goldens =="
"$CC" -std=c11 -O2 -Wall -Wextra -Werror \
  -I "$COMMITTED" -I "$MODEL" \
  "$CHECK_SRC" "$MODEL/encoding.c" \
  -o "$TMP/parser_gen_check"
"$TMP/parser_gen_check"

echo "parser-gen-check: PASS"
