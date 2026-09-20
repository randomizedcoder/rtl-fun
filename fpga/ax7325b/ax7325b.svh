// ax7325b.svh — global FPGA defines for the ALINX AX7325B (Kintex-7 XC7K325T-2FFG900I)
//
// Board-defines header for CVA6's ariane_xilinx top, modeled on
// corev_apu/fpga/src/genesysii.svh. Selects the AX7325B board branch and pulls in
// the shared Kintex-7 code path (DDR3 MIG / clocking) that GENESYSII and KC705 use.
//
// NB: `AX7325B` is a NEW board macro — the matching `\`elsif AX7325B` branches must be
// added to corev_apu/fpga/src/ariane_xilinx.sv (port list + peripheral instantiation)
// as a CVA6 patch before this compiles. See docs/phase-8-status.md
// §"ariane_xilinx AX7325B variant" for the exact change-list. This file on its own is
// the anchor for that port, not a complete board port.

`define AX7325B
// include KINTEX7-specific code (shared with KC705, GENESYSII, ...) — DDR3 MIG,
// clock generation, and the Kintex-7 peripheral map all live under `ifdef KINTEX7`.
`define KINTEX7

`define ARIANE_DATA_WIDTH 64

// Instantiate protocol checker
// `define PROTOCOL_CHECKER
