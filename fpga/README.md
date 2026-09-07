# fpga/ — board build + block design (Phase 8)

Prototype bring-up: CVA6 + the parser unit + packet BRAM + Ethernet MAC, AXI
plumbing, vendor build flow, and on-board bring-up.

**Board: Sipeed Tang Mega 138K Pro** (Gowin `GW5AST-LV138FPG676AC1/I0`) — chosen in
[`docs/fpga-platform-assessment.md`](../docs/fpga-platform-assessment.md), on the desk
and running since 2026-09-07.

Start with the bring-up guide — it is the standing reference for how to use this
board, and the record of what does and does not work:
**[`docs/fpga-bringup-tang-mega-138k-pro.md`](../docs/fpga-bringup-tang-mega-138k-pro.md)**

| Path | What |
|---|---|
| [`tang-mega-138k-pro/`](tang-mega-138k-pro/) | Board designs + the Gowin build scripts |

Bitstreams are produced by Gowin EDA inside the licensed microVM
([`docs/gowin-microvm.md`](../docs/gowin-microvm.md)) and programmed over USB-JTAG
with openFPGALoader:

```
nix run .#fpga-detect                  # scan the JTAG chain
nix run .#fpga-build                   # our RTL -> .fs (Gowin, in the microVM)
nix run .#fpga-load  -- <design.fs>    # program SRAM  (volatile)
nix run .#fpga-flash -- <design.fs>    # program flash (persistent)
```
