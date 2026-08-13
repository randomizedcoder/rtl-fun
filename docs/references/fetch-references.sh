#!/usr/bin/env bash
#
# Re-download the machine-fetchable reference materials into this directory.
#
# NOT handled here (manual, by design):
#   * herbert-parser-instructions.md  -- the live blog returns HTTP 403 to
#     fetchers; it is transcribed by hand from the article text.
#   * patent-us12461885.pdf           -- Google Patents reveals the PDF URL only
#     via JavaScript. Download it with the "Download PDF" button at
#     https://patents.google.com/patent/US12461885B2/en and save it here.
#
set -euo pipefail
cd "$(dirname "$0")"

# Pin the RISC-V ISA manual release we archived. Update the tag to bump it.
RISCV_TAG="riscv-isa-release-ba25a36-2026-08-04"
RISCV_URL="https://github.com/riscv/riscv-isa-manual/releases/download/${RISCV_TAG}/riscv-spec.pdf"
RISCV_OUT="riscv-isa-manual-2026-08-04.pdf"

FLOWDIS_URL="https://raw.githubusercontent.com/torvalds/linux/master/net/core/flow_dissector.c"
FLOWDIS_OUT="linux-flow_dissector.c"

echo "==> RISC-V ISA manual (${RISCV_TAG})"
curl -fL --retry 3 --max-time 120 -o "${RISCV_OUT}" "${RISCV_URL}"

echo "==> Linux flow_dissector.c (torvalds/linux master)"
curl -fL --retry 3 --max-time 60 -o "${FLOWDIS_OUT}" "${FLOWDIS_URL}"

# Regenerate plain-text companions if pdftotext (poppler) is available.
if command -v pdftotext >/dev/null 2>&1; then
  echo "==> Extracting text (pdftotext)"
  pdftotext -layout patent-us12461885.pdf patent-us12461885.txt 2>/dev/null || true
  pdftotext        "${RISCV_OUT}" "${RISCV_OUT%.pdf}.txt"
else
  echo "==> pdftotext not found; skipping .txt extraction"
  echo "    (try:  nix shell nixpkgs#poppler-utils --command $0 )"
fi

echo
echo "Done. Reminder to fetch manually:"
echo "  * patent-us12461885.pdf  <- https://patents.google.com/patent/US12461885B2/en"
