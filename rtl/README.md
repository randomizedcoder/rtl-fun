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

*Empty until Phase 5. See [`docs/phase-5-rtl.md`](../docs/phase-5-rtl.md).*
