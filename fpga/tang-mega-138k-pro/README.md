# Tang Mega 138K Pro — board designs

Gowin **`GW5AST-LV138FPG676AC1/I0`** (Arora V, LUT4), 138,240 LUT4 / 138,240 FF,
6,120 Kbit BSRAM, 1 GB DDR3, 2x SFP+, PCIe hard core, hardened Andes A25.

Read [`docs/fpga-bringup-tang-mega-138k-pro.md`](../../docs/fpga-bringup-tang-mega-138k-pro.md)
first — pin map, the programming ladder, and the Gowin gotchas.

## Contents

| File | What |
|---|---|
| `blinky.tcl` | `gw_sh` build script: `set_device` candidate loop, sources, syn + pnr |
| `src/blinky_top.v` | 6-pattern LED sequencer. **Verilog-2001** — see below |
| `src/blinky_top.cst` | Pin constraints (clock + 6 active-low LEDs) |
| `src/blinky_top.sdc` | 50 MHz clock constraint, so every build reports timing |

## Build and run

```
nix run .#fpga-build                                  # -> build/fpga-blinky/impl/pnr/blinky_top.fs
nix run .#fpga-load -- build/fpga-blinky/impl/pnr     # program SRAM
```

**Six patterns, ~3.75 s each, cycling forever:** all-flash → walk up → ping-pong →
filling bar → odd/even → two dots converging.

A *changing sequence* is the point. The board's factory flash image ping-pongs a
dot forever and Sipeed's `led.fs` fills a bar forever — but neither ever switches
to something else, so a design that visibly cycles can't be confused with either.
See the header of `src/blinky_top.v` for the three single-pattern attempts that
were ambiguous on real hardware first.

Change `TICK_DIV` in `src/blinky_top.v`, rebuild, reload — the speed must change.
That round trip is the point of this design.

## Two rules for anything added here

1. **Verilog-2001, not SystemVerilog.** `gw_sh`'s `add_file -type verilog` parses
   Verilog mode and rejects `logic` / `always_ff`. This is why `blinky_top.v` and
   `nix/gowin/blinky.v` look the way they do. The project's *parser* RTL is
   SystemVerilog and reaches Gowin by a different route (sv2v flatten).
2. **`set_device` wants the order code.** The marketing name
   `GW5AST-LV138FPG676A` is rejected; the device DB keys the grade-suffixed
   `GW5AST-LV138FPG676AC1/I0`. Reuse the candidate loop in `blinky.tcl`.
