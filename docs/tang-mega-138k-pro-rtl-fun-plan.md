# Tang Mega 138K Pro FPGA Bring-Up Plan for `rtl-fun`

## Purpose

This document describes a practical path for using the **Sipeed Tang
Mega 138K Pro** as an FPGA target for the `rtl-fun` RISC-V packet-parser
instruction project.

The immediate goal is **not** to build the complete networking system on
the FPGA. The first goal is to establish that:

1.  the Tang Mega 138K Pro development environment works reliably on
    NixOS;
2.  the selected CVA6 RTL can be synthesized for the GW5AST FPGA;
3.  the proposed parser execution unit and packet-window memory
    architecture fit comfortably;
4.  a single custom instruction can be taken end-to-end through CVA6 and
    executed correctly on hardware.

Once those questions are answered, the board's DDR3, SFP+, PCIe, and
other high-speed interfaces can be integrated incrementally.

## References

### Project

-   `rtl-fun`: https://github.com/randomizedcoder/rtl-fun/

### Tang Mega 138K Pro

-   Board documentation:
    https://wiki.sipeed.com/hardware/en/tang/tang-mega-138k/mega-138k-pro.html
-   Gowin IDE installation:
    https://wiki.sipeed.com/hardware/en/tang/common-doc/get_started/install-the-ide.html
-   Sipeed Tang Mega 138K Pro examples:
    https://github.com/sipeed/TangMega-138KPro-example

The board uses a **Gowin GW5AST-LV138FPG676A** FPGA. Sipeed lists:

-   138,240 LUT4s
-   138,240 flip-flops
-   6,120 Kbit block SRAM
-   340 block SRAMs
-   298 18×18 multipliers
-   1 GB DDR3
-   eight high-speed transceivers, up to 12.5 Gbit/s
-   PCIe hard core
-   two SFP+ ports
-   JTAG and UART

Sipeed currently states that the 138K Pro requires **Gowin commercial
IDE 1.9.9 or newer**, rather than the Education edition.

## Proposed NixOS Development Environment

Most development should use open-source tools, with Gowin EDA used
primarily for FPGA synthesis, place-and-route, timing analysis, and
bitstream generation.

A starting Nix shell is:

``` nix
{
  pkgs ? import <nixpkgs> {}
}:

pkgs.mkShell {
  packages = with pkgs; [
    # RTL simulation and synthesis
    yosys
    verilator
    iverilog
    gtkwave

    # FPGA place-and-route / programming
    nextpnr
    openFPGALoader

    # Gowin open-source tooling
    python3
    python3Packages.apycula

    # RISC-V software toolchain
    riscv64-elf-gcc

    # General build tooling
    gnumake
    git
  ];
}
```

The exact nixpkgs attribute names should be checked against the version
of nixpkgs used by the project, since package names can change.

For the project itself, this should eventually become a `flake.nix` so
that:

``` console
$ nix develop
```

provides the complete reproducible development environment.

## Toolchain Architecture

The desired development flow is:

``` text
                         RISC-V / parser RTL
                                 |
                +----------------+----------------+
                |                                 |
                v                                 v
           Verilator                         FPGA synthesis
           simulation                              |
                |                         +--------+--------+
                |                         |                 |
                |                       Yosys          Gowin EDA
                |                         |                 |
                |                   nextpnr-gowin      synthesis
                |                         |           place & route
                |                      Apicula          timing
                |                         |                 |
                +-------------------------+--------+--------+
                                                   |
                                                   v
                                             FPGA bitstream
                                                   |
                                                   v
                                           openFPGALoader
                                                   |
                                                   v
                                         Tang Mega 138K Pro
```

The **open-source path should be treated as desirable but not initially
mandatory**. GW5AST support is newer than support for older Gowin
families, and advanced resources such as DDR3 controllers, SerDes, PCIe,
and vendor IP may require Gowin EDA.

The important architectural principle is that the RTL and verification
environment should not depend on Gowin.

## Recommended Development Loop

Most custom-instruction development should happen in simulation:

``` text
edit RTL
   |
   v
Verilator
   |
   v
instruction tests
   |
   v
golden-model comparison
   |
   v
parser benchmark
```

Only after the tests pass should the slower FPGA flow be run:

``` text
Gowin synthesis
   |
   v
place and route
   |
   v
timing analysis
   |
   v
bitstream
   |
   v
program FPGA
   |
   v
hardware test
```

This keeps the normal edit/test cycle fast and reproducible.

# Required Experiments

## Experiment 1 --- NixOS Toolchain Smoke Test

**Objective:** prove that the basic FPGA development tools run correctly
on NixOS.

Install and test:

-   Verilator
-   Yosys
-   nextpnr
-   Apicula
-   openFPGALoader
-   RISC-V GCC/binutils
-   Gowin EDA

Verify basic commands and versions.

For Gowin EDA, determine whether the GUI runs directly under the desktop
environment or needs XWayland/XCB, for example:

``` console
$ QT_QPA_PLATFORM=xcb gw_ide
```

**Success criterion:** all required tools launch and can be invoked
reproducibly from the project environment.

------------------------------------------------------------------------

## Experiment 2 --- Sipeed LED Example

**Objective:** prove the complete Gowin FPGA build/programming path
before introducing CVA6.

Use Sipeed's supplied LED example:

https://github.com/sipeed/TangMega-138KPro-example

Perform:

``` text
example RTL
    |
    v
Gowin synthesis
    |
    v
place & route
    |
    v
bitstream
    |
    v
openFPGALoader
    |
    v
blinking LED
```

**Success criterion:** build and program the board entirely from the
NixOS workstation.

This establishes that USB/JTAG permissions, programming, device
selection, constraints, clocks, and the basic Gowin installation are
correct.

------------------------------------------------------------------------

## Experiment 3 --- Command-Line Gowin Build

**Objective:** eliminate dependence on GUI-driven builds.

Take the working LED project and determine the Gowin command-line
invocation needed to reproduce it.

The eventual target should be something like:

``` console
$ make bitstream
$ make program
```

or:

``` console
$ nix develop
$ just fpga
$ just program
```

**Success criterion:** a clean checkout can produce and program the
bitstream without manually operating the Gowin GUI.

------------------------------------------------------------------------

## Experiment 4 --- CVA6 Baseline Synthesis

**Objective:** determine whether unmodified CVA6 can be synthesized
successfully by Gowin for the GW5AST-138K.

Do **not** add parser instructions yet.

Measure:

-   LUT utilization
-   FF utilization
-   BRAM utilization
-   DSP utilization
-   maximum achievable clock frequency
-   critical paths
-   synthesis time
-   place-and-route time

The key questions are:

``` text
Does CVA6 elaborate?
        |
        v
Does it synthesize?
        |
        v
Does it fit?
        |
        v
Does it route?
        |
        v
What Fmax is achievable?
```

**Success criterion:** CVA6 successfully completes synthesis and
place-and-route with sufficient resources remaining for the parser unit.

This is the most important early feasibility experiment.

------------------------------------------------------------------------

## Experiment 5 --- Minimal CVA6 FPGA System

**Objective:** prove that CVA6 actually executes software on the FPGA.

Build the smallest useful SoC around CVA6:

``` text
              +----------------+
              |     CVA6       |
              +-------+--------+
                      |
             +--------+--------+
             |                 |
             v                 v
           BRAM              UART
             |
          program
          memory
```

Initially avoid DDR3, Ethernet, PCIe, and SFP+.

Run a tiny bare-metal RISC-V program that:

1.  boots;
2.  writes a known string to UART;
3.  performs a small computation;
4.  reports success.

For example:

``` text
rtl-fun CVA6 FPGA test
2 + 2 = 4
PASS
```

**Success criterion:** deterministic execution of a bare-metal program
on CVA6 with UART output.

------------------------------------------------------------------------

## Experiment 6 --- Packet-Window BRAM

**Objective:** validate the proposed wide packet-memory architecture
independently of the parser ISA.

Implement a small packet buffer using FPGA block RAM.

Initial target:

``` text
                packet test data
                       |
                       v
             +-------------------+
             |    packet BRAM    |
             |                   |
             | 128-bit read port |
             +---------+---------+
                       |
                       v
                 parser window
```

Test:

-   aligned 128-bit reads;
-   unaligned field extraction;
-   accesses crossing a 128-bit boundary;
-   bounds checking;
-   byte ordering;
-   packets shorter than the requested field;
-   back-to-back accesses.

Compare every result against the existing software golden model.

**Success criterion:** packet-window reads exactly match the reference
model for the full test corpus.

------------------------------------------------------------------------

## Experiment 7 --- One Custom Instruction End-to-End

**Objective:** establish the complete CVA6 custom-instruction path
before implementing the full parser ISA.

Choose one simple, representative parser instruction.

Implement:

``` text
instruction encoding
        |
        v
CVA6 decoder
        |
        v
issue / scoreboard
        |
        v
parser execution unit
        |
        v
packet-window read
        |
        v
result
        |
        v
CVA6 commit
```

Expose it to software initially using `.insn` or inline assembly rather
than modifying GCC/LLVM.

Conceptually:

``` c
static inline uint64_t parser_op(uint64_t arg)
{
    uint64_t result;

    __asm__ volatile (
        ".insn ..."
        : "=r" (result)
        : "r" (arg)
    );

    return result;
}
```

Test the instruction in:

1.  RTL simulation;
2.  CVA6 simulation;
3.  FPGA hardware.

**Success criterion:** the same test vector produces the same
architectural result in the C golden model, RTL simulation, CVA6
simulation, and physical FPGA.

------------------------------------------------------------------------

## Experiment 8 --- Pipeline and Hazard Behaviour

**Objective:** verify that the parser extension behaves correctly as
part of a pipelined CPU rather than only in isolated tests.

Test interactions with:

-   dependent instructions;
-   independent instructions;
-   pipeline stalls;
-   branches;
-   branch misprediction/flush;
-   exceptions;
-   interrupts;
-   repeated parser operations;
-   back-to-back parser instructions.

Particular attention should be paid to any parser-specific architectural
state.

**Success criterion:** no parser state from squashed or faulting
instructions becomes architecturally visible.

------------------------------------------------------------------------

## Experiment 9 --- Parser Performance Counters

Add counters before attempting full parser benchmarking.

Suggested counters:

``` text
parser_instr_retired
parser_cycles_busy
parser_stall_cycles
packet_window_reads
packet_window_stalls
bytes_parsed
bounds_failures
parse_complete
```

Also collect the relevant CVA6 counters:

``` text
cycles
instructions retired
loads
stores
branches
branch misses
```

**Success criterion:** counters are accessible to the benchmark harness
and give repeatable results.

------------------------------------------------------------------------

## Experiment 10 --- Baseline vs Custom-ISA Parser

**Objective:** measure whether the ISA extension actually helps.

Run the same packet corpus through:

### Baseline

Normal RV64 instructions.

### Accelerated

The new parser instructions.

Compare:

  Metric                   Baseline   Custom ISA
  ---------------------- ---------- ------------
  Cycles/packet                     
  Instructions/packet               
  Loads/packet                      
  Branches/packet                   
  Branch misses/packet              
  Packet-window reads           N/A 
  Code size                         

The most important early measurements are **cycles per packet** and
**instructions per packet**.

Absolute FPGA clock speed is secondary.

------------------------------------------------------------------------

## Experiment 11 --- DDR3

Only after the BRAM implementation works should the external 1 GB DDR3
be introduced.

Use Sipeed's verified DDR examples as the starting point.

Test:

``` text
CVA6
 |
 +---- instruction/data memory
 |
 +---- packet DMA/buffer
             |
             v
            DDR3
```

Questions to answer:

-   What latency does the Gowin DDR controller expose?
-   What sustained bandwidth is achievable?
-   How should packet data be prefetched into the 128-bit parser window?
-   Is a BRAM packet cache necessary?

**Success criterion:** packet parsing from DDR-backed data remains
functionally correct and its performance is understood.

------------------------------------------------------------------------

## Experiment 12 --- 10GbE SFP+

The Tang Mega 138K Pro becomes particularly interesting once the
CPU/parser design is stable because the board has two SFP+ interfaces
and Sipeed provides a verified 10GbE example.

Start from:

https://github.com/sipeed/TangMega-138KPro-example

The eventual datapath can be:

``` text
                    10GbE SFP+
                        |
                        v
                    PCS / MAC
                        |
                        v
                    RX FIFO
                        |
                        v
                 packet buffer
                        |
                        v
                128-bit window
                        |
                        v
              +----------------+
              |      CVA6      |
              |                |
              | parser ISA     |
              +-------+--------+
                      |
                      v
                  flow_keys
```

This should be treated as a later-stage experiment, not part of initial
CVA6 bring-up.

**Success criterion:** real Ethernet/IP/TCP/UDP packets received from
SFP+ can be passed through the parser and classified correctly.

# Recommended Order

The experiments should be performed in this order:

``` text
1. NixOS environment
       |
2. LED example
       |
3. CLI build
       |
4. CVA6 synthesis
       |
5. CVA6 + BRAM + UART
       |
6. 128-bit packet window
       |
7. ONE custom instruction
       |
8. pipeline/hazard tests
       |
9. performance counters
       |
10. baseline vs custom ISA benchmark
       |
11. DDR3
       |
12. 10GbE SFP+
```

The important milestone is **Experiment 7**.

At that point the project will have demonstrated an end-to-end custom
RISC-V instruction on real hardware:

``` text
C model
   |
ISA encoding
   |
CVA6 decoder
   |
custom RTL
   |
packet data
   |
architectural result
   |
FPGA
```

Everything after that is principally about scaling the design and making
the benchmark increasingly realistic.

# Initial Go / No-Go Criteria for the Tang Mega 138K Pro

Before investing significant effort in board-specific development,
answer these questions:

-   [ ] Can Gowin EDA run reliably on NixOS?
-   [ ] Can builds be driven from the command line?
-   [ ] Can `openFPGALoader` program the board?
-   [ ] Can Gowin synthesize the unmodified CVA6 RTL?
-   [ ] Does CVA6 fit with useful FPGA resources remaining?
-   [ ] Is the achieved Fmax sufficient for architectural benchmarking?
-   [ ] Can block RAM efficiently implement the 128-bit packet window?
-   [ ] Can the custom execution unit be integrated without unacceptable
    timing impact?

If these answers are yes, the Tang Mega 138K Pro is a strong platform
for the `rtl-fun` prototype.

If CVA6 fails because of Gowin SystemVerilog compatibility rather than
FPGA capacity, that should be treated as a **toolchain/platform issue**,
not as a reason to compromise the RISC-V architecture. In that case the
same RTL and verification environment should be retained and an
AMD/Xilinx or Intel FPGA target considered.
