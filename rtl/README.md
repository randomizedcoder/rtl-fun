# rtl/ — SystemVerilog parser unit (Phase 5)

The parser execution unit and its integration into CVA6. Planned modules:

```
parser_pkg.sv       generated constants (Fnc4, Sz, parser codes, register ids)
parser_decode.sv    custom-0/custom-3 opcode decode
parser_execute.sv   the parser functional unit (extract / bounds / length / CAM / loop)
parser_*.sv         extract, bounds-check, TLV, CAM submodules, parser register file
```

Coding standards + lint (verible / svlint) are defined in
[`docs/phase-5-rtl.md`](../docs/phase-5-rtl.md). Constants in `parser_pkg.sv` are
generated from [`isa/`](../isa/README.md), not hand-written.

The signal-level contract these modules implement is fixed by Phase 4:
- **Unit interfaces** (ports/widths per leaf unit) —
  [`docs/phase-4-microarchitecture.md`](../docs/phase-4-microarchitecture.md) §4.6.
- **CVA6 seam** (exact files/signals to patch, `fu_t::PARSER`, the
  `resolved_branch_o` end-of-node redirect, CV-X-IF for custom-3, patch checklist)
  — [`docs/analysis/cva6-integration.md`](../docs/analysis/cva6-integration.md).

*Empty until Phase 5. See [`docs/phase-5-rtl.md`](../docs/phase-5-rtl.md).*
