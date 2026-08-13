# Reference library (local copies)

Offline copies of the key sources, so the repo is self-contained and anyone can
read the background without hunting the web. See [`../references.md`](../references.md)
for the annotated list with context; this file records provenance and licensing.

## Contents

| File | Source | License / status | Retrieved |
|------|--------|------------------|-----------|
| [`herbert-parser-instructions.md`](herbert-parser-instructions.md) | Tom Herbert blog — the originating post | © Tom Herbert; text transcription, fair-use for research. Live page returns **HTTP 403** to fetchers. | 2026-08-12 |
| [`patent-us12461885.pdf`](patent-us12461885.pdf) · [`.txt`](patent-us12461885.txt) | US Patent 12,461,885 "Parser instructions for CPUs" ([Google Patents](https://patents.google.com/patent/US12461885B2/en)) | US patent text — public / free to reproduce | 2026-08-12 |
| [`riscv-isa-manual-2026-08-04.pdf`](riscv-isa-manual-2026-08-04.pdf) · [`.txt`](riscv-isa-manual-2026-08-04.txt) | RISC-V ISA Manual, release `ba25a36` (2026-08-04) | CC-BY-4.0 (RISC-V International) | 2026-08-12 |
| [`linux-flow_dissector.c`](linux-flow_dissector.c) | Linux `net/core/flow_dissector.c` (torvalds/linux `master`) | GPL-2.0-only (SPDX header retained) | 2026-08-12 |

> **Note on the blog copy:** it is a copyrighted Medium post reproduced here for
> study. If this repo is made public, confirm you're comfortable hosting the full
> text, or replace it with a summary + link.
>
> **Patent PDF:** download via the *Download PDF* button on the
> [Google Patents page](https://patents.google.com/patent/US12461885B2/en) and save
> it here as `patent-us12461885.pdf` (the direct asset URL is a JS-revealed hashed
> `patentimages` link, so it can't be curl'd headlessly).

## Text extractions (`.txt`)

The two PDFs also have plain-text companions (`*.txt`), extracted with
`pdftotext` (poppler) for easy reading, `grep`, and diffing:

```sh
nix shell nixpkgs#poppler-utils --command \
  pdftotext -layout patent-us12461885.pdf patent-us12461885.txt
nix shell nixpkgs#poppler-utils --command \
  pdftotext        riscv-isa-manual-2026-08-04.pdf riscv-isa-manual-2026-08-04.txt
```

> ⚠️ The patent PDF is an HTML-to-PDF export, so some `fi`/`fl` ligatures come
> through as `�` in the text (e.g. "�ag-�elds" = "flag-fields"). Fine for reading;
> keep it in mind for exact-word searches. The PDF remains the authoritative copy.

## Refreshing / re-downloading

Run [`fetch-references.sh`](fetch-references.sh) to (re)download the machine-fetchable
items. The blog is transcribed by hand (403) and the patent PDF is a manual click,
so those two are not scripted.

## Not vendored (kept as links)

Whole projects — CVA6, Ibex, Verilator, cocotb, Spike, QEMU, the RISC-V toolchain —
are referenced by URL in [`../references.md`](../references.md), not copied in.
