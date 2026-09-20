## ax7325b.xdc — CVA6 (ariane_xilinx) board constraints for the ALINX AX7325B
## =============================================================================
## Board:  ALINX AX7325B  ·  Kintex-7  XC7K325T-2FFG900I  (same die/package/speed
##         as the Digilent Genesys 2; fit verdict unchanged — see docs/phase-8-status.md).
## Source: pins transcribed from "KINTEX-7 FPGA Development Board AX7325B User Manual"
##         rev 1.1 (ALINX, 2022), extracted 2026-09-20. This mirrors CVA6's
##         corev_apu/fpga/constraints/genesys-2.xdc, remapped to AX7325B pins.
##
## STATUS: FIRST DRAFT — package pins are transcribed from the manual's pin tables
##         and are trustworthy; IOSTANDARD (bank VCCIO) values are the ambiguous part.
##         >>> VERIFY every `#VERIFY` line against the AX7325B *schematic* before use. <<<
##         The manual reuses template text across ALINX's Zynq+Kintex lines (e.g. it
##         labels the UART pins "PS_MIO12/13" on a chip with NO processor system), so
##         its bank-voltage prose is not reliable on its own.
##
## SCOPE (matches genesys-2.xdc): this file carries board I/O only. Two things are
## deliberately NOT here:
##   * DDR3 + the 200 MHz SYS_CLK (AE10/AF10) — owned by the MIG-generated .xdc /
##     mig project (as on Genesys 2). AX7325B DDR3 = 4x MT41K256M16 (2 GiB, 64-bit)
##     on the HP banks; build a MIG config from ALINX's DDR3 memtest demo.
##   * The 10G SFP+ / 40G QSFP+ GTX pins + their 156.25 MHz (SFP, BANK117) and
##     125 MHz (QSFP, BANK118) reference clocks — Phase 9 (10G MAC on GTX).
##
## TOP-LEVEL DELTAS vs the Genesys 2 ariane_xilinx variant (must be handled in RTL,
## not just here — an `AX7325B` board ifdef):
##   * NO onboard 1G RGMII PHY on the AX7325B — the whole `eth_*` block from
##     genesys-2.xdc does not apply. Ethernet is SFP+/GTX only (Phase 9). Remove or
##     stub the RGMII MAC/PHY in the top for the AX7325B build.
##   * NO DIP switches on the AX7325B (only 2 push buttons) — tie `sw[7:0]` off in
##     the top-level for this board (no constraints emitted below).
##   * Only 4 user LEDs (vs 8) — `led[7:4]` are unconstrained; leave them unconnected
##     or drop them in the AX7325B top. `fan_pwm` has no board equivalent — omit.
## =============================================================================

## ---------------------------------------------------------------------------
## Reset  — KEY1 push button (active-low, matches cpu_resetn polarity)
## ---------------------------------------------------------------------------
## KEY1/KEY2 are on BANK13 (VCCIO = VADJ). #VERIFY VADJ rail (ALINX default is
## commonly 3.3 V; could be 2.5 V) → set IOSTANDARD to match.
set_property -dict {PACKAGE_PIN AG27 IOSTANDARD LVCMOS33} [get_ports cpu_resetn] ;#VERIFY VADJ  KEY1

## ---------------------------------------------------------------------------
## UART  — CP2102 USB-UART (Part 7). Manual mislabels these "PS_MIO12/13" (Zynq
## template) — the package pins AK26/AJ26 are the real, FPGA-fabric pins.
## FPGA-side signals are level-shifted, so IOSTANDARD follows the FPGA bank rail.
## `tx` is an FPGA output (→ CP2102 RXD); `rx` is an FPGA input (← CP2102 TXD).
## ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN AK26 IOSTANDARD LVCMOS33} [get_ports tx] ;#VERIFY bank  UART_TX (FPGA out)
set_property -dict {PACKAGE_PIN AJ26 IOSTANDARD LVCMOS33} [get_ports rx] ;#VERIFY bank  UART_RX (FPGA in)

## ---------------------------------------------------------------------------
## User LEDs — LED1..LED4 on BANK17 (Part 15). Only 4 available (led[0..3]).
## The manual states BANK16..18 sit at 1.5 V (DDR-adjacent) → LVCMOS15 is the
## best guess, but this bank voltage is exactly what must be schematic-checked.
## ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN A22 IOSTANDARD LVCMOS15} [get_ports {led[0]}] ;#VERIFY 1.5V?  LED1
set_property -dict {PACKAGE_PIN C19 IOSTANDARD LVCMOS15} [get_ports {led[1]}] ;#VERIFY 1.5V?  LED2
set_property -dict {PACKAGE_PIN B19 IOSTANDARD LVCMOS15} [get_ports {led[2]}] ;#VERIFY 1.5V?  LED3
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS15} [get_ports {led[3]}] ;#VERIFY 1.5V?  LED4
## led[7:4]: no board LEDs — leave unconnected / drop in the AX7325B top.

## ---------------------------------------------------------------------------
## SD card (SPI mode) — Part 12, BANK12 (VCCIO = VADJ). Standard SD-over-SPI map:
##   spi_clk_o <- SD_CLK, spi_mosi <- SD_CMD, spi_miso <- SD_D0, spi_ss <- SD_D3(/CS)
## #VERIFY VADJ rail for BANK12/13.
## ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN AH21 IOSTANDARD LVCMOS33} [get_ports spi_clk_o] ;#VERIFY VADJ  SD_CLK
set_property -dict {PACKAGE_PIN AJ21 IOSTANDARD LVCMOS33} [get_ports spi_mosi]  ;#VERIFY VADJ  SD_CMD
set_property -dict {PACKAGE_PIN AJ22 IOSTANDARD LVCMOS33} [get_ports spi_miso]  ;#VERIFY VADJ  SD_D0
set_property -dict {PACKAGE_PIN AH20 IOSTANDARD LVCMOS33} [get_ports spi_ss]    ;#VERIFY VADJ  SD_D3/CS

## ---------------------------------------------------------------------------
## RISC-V soft debug JTAG (FTDI-driven, separate from the config JTAG) —
## ariane_xilinx exposes trst_n/tck/tdi/tdo/tms as top-level ports. The AX7325B
## has no dedicated header for these, so route them to free IO on the 40-pin
## expansion header J16 (3.3 V — pins 39/40 are +3.3 V out). Pins chosen below are
## a proposal; #VERIFY they are free in the final top and reachable on your harness.
## ---------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN J24 IOSTANDARD LVCMOS33} [get_ports trst_n] ;#VERIFY J16 pin3
set_property -dict {PACKAGE_PIN J23 IOSTANDARD LVCMOS33} [get_ports tck]    ;#VERIFY J16 pin4
set_property -dict {PACKAGE_PIN J22 IOSTANDARD LVCMOS33} [get_ports tms]    ;#VERIFY J16 pin5
set_property -dict {PACKAGE_PIN J21 IOSTANDARD LVCMOS33} [get_ports tdi]    ;#VERIFY J16 pin6
set_property -dict {PACKAGE_PIN J26 IOSTANDARD LVCMOS33} [get_ports tdo]    ;#VERIFY J16 pin7

## ---------------------------------------------------------------------------
## Configuration flash — N25Q128 quad-SPI (Part 5), same as Genesys 2.
## ---------------------------------------------------------------------------
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]

## ---------------------------------------------------------------------------
## Soft-JTAG timing (copied from genesys-2.xdc; keep once pins are confirmed).
## ---------------------------------------------------------------------------
set_max_delay -to   [get_ports {tdo}]    20
set_max_delay -from [get_ports {tms}]    20
set_max_delay -from [get_ports {tdi}]    20
set_max_delay -from [get_ports {trst_n}] 20
set_false_path -from [get_ports {trst_n}]
## NB: genesys-2.xdc also false-paths the MIG reset:
##   set_false_path -from [get_pins i_ddr/u_xlnx_mig_7_ddr3_mig/.../rstdiv0_sync_r1_reg_rep/C]
## Re-add that once the AX7325B MIG instance path is known.
