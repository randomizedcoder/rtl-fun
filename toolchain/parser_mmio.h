/*
 * parser_mmio.h — MMIO map for the parser FU's SoC peripheral (I5).
 *
 * The parser packet buffer and flow_keys frame live INSIDE the EX-stage FU (the
 * read window is combinational, one cycle), so they are not directly on the AXI
 * fabric. Instead a small SoC slave at PARSER_BASE bridges bus stores/loads into
 * the FU's write/read ports (see nix/cva6-parser/mmio.patch: axi2mem + a decode in
 * corev_apu/tb/ariane_testharness.sv; ports threaded ariane -> cva6 -> ex_stage ->
 * parser_pktbuf / cva6_parser_wrap). This closes the deferred packet-feed /
 * flow_keys-readback escalation the I2 sim-only backdoor stood in for.
 *
 * A bare-metal program (e.g. the cva6-parser-cosim generated .S) therefore:
 *   1. `sd`s the packet bytes, 8 at a time, into [PKT, PKT+PKT_MAX)      (write)
 *   2. `sd`s the byte length into PARSELEN                               (write)
 *   3. runs the parser slice program (custom-0/custom-3)
 *   4. `ld`s the committed flow_keys, 8 at a time, from [META, META+META_MAX) (read)
 *
 * The peripheral window is 4 KiB at PARSER_BASE (ariane_soc::ParserBase /
 * ParserLength in corev_apu/tb/ariane_soc_pkg.sv). Offsets match the decode there.
 * Widths (PKT_MAX/META_MAX) mirror rtl/parser_pkg.sv.
 */
#ifndef PARSER_MMIO_H
#define PARSER_MMIO_H

#define PARSER_BASE      0x50000000UL   /* ariane_soc::ParserBase */

#define PARSER_PKT       (PARSER_BASE + 0x000UL)  /* packet buffer   : write, 8-aligned sd */
#define PARSER_PKT_MAX   256UL                     /* rtl/parser_pkg.sv PKT_MAX             */

#define PARSER_PARSELEN  (PARSER_BASE + 0x100UL)  /* PktLen.ParseLen : write, low 16 bits  */
#define PARSER_STATUS    (PARSER_BASE + 0x100UL)  /* exit status     : read, [32]=seen [31:0]=code */
#define PARSER_EXIT_PC   (PARSER_BASE + 0x108UL)  /* exit landing PC : write, 64-bit       */

#define PARSER_META      (PARSER_BASE + 0x200UL)  /* flow_keys frame : read, 8-aligned ld  */
#define PARSER_META_MAX  64UL                      /* rtl/parser_pkg.sv META_MAX            */

#endif /* PARSER_MMIO_H */
