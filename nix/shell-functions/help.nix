# nix/shell-functions/help.nix
#
# Defines the `rtl-help` shell function shown in the dev shell.
# Returns a bash snippet to be sourced by nix/devshell.nix.
#
{}:
''
  rtl-help() {
    cat <<'EOF'
  rtl-fun dev shell — parser instructions for RISC-V

    Docs / references
      pdftotext / pdftoppm / pdfimages   patent PDF extraction (poppler)
      python3 tools/bitgen/bitgen.py     regenerate the ASCII bit diagrams
      ./docs/references/fetch-references.sh   re-download reference material

    RTL / simulation (Phase 5/6)
      verilator            SystemVerilog simulation
      verible-verilog-*    format / lint SystemVerilog (verible)
      svlint               SystemVerilog lint
      gtkwave              view waveforms
      cocotb / pytest      Python co-sim testbenches

    ISA sim / toolchain (Phase 7)
      spike                RISC-V ISA simulator
      qemu-system-riscv64  RISC-V emulation
      riscv64-none-elf-gcc bare-metal RISC-V cross compiler ($CV_SW_PREFIX)

    Base core (CVA6)
      $CVA6_SRC            pinned CVA6 source (read-only; copy out to build)
      nix run .#cva6-baseline     build the stock CVA6 Verilator model (unpatched)
      nix run .#cva6-parser       build the parser-patched CVA6 model (compare vs baseline)
      nix run .#cva6-parser-test  build patched model + run the in-core custom-0 test
      nix run .#cva6-parser-cosim build patched model + run the in-core packet->flow_keys cosim (I5)
      nix run .#cva6-parser-tandem build patched model w/ RVFI-vs-Spike lock-step + run base-ISA tandem (Phase 7)
      nix run .#cva6-parser-tandem-campaign  random + real-corpus packets under RVFI-vs-Spike lock-step (Phase 7 Stage 2)
      nix build .#spike-tandem     source-built tandem Spike (libriscv w/ RVFI DPI; cached derivation)
      nix build .#spike-parser     standalone runnable parser Spike (spike exe w/ parser ext + MMIO)
      nix build .#qemu-parser      patched qemu-system-riscv64 (parser ISA + 0x5000_0000 packet MMIO)
      nix build .#cva6-parser-src patched CVA6 source only (cached derivation)

    Toolchain codegen (Phase 7)
      nix run .#parser-gen-check  regenerate toolchain/generated from the ISA yaml + drift check
      nix run .#parser-asm-test   assemble every prs.* mnemonic w/ patched binutils, check words + objdump (L2)
      nix run .#parser-spike      run parser ELFs on the standalone parser Spike == golden model (Stage 2)
      nix run .#parser-spike-slice  run the C-intrinsics slice on the standalone Spike == golden model (Stage 3)
      nix run .#parser-qemu       run parser ELFs on the patched qemu-system-riscv64 == golden model (QEMU leg)
      nix run .#parser-qemu-slice   run the C-intrinsics slice on the patched QEMU == golden model (exit criterion)

    Golden model (Phase 2)
      nix run .#model-test        run the reference-model unit + corpus tests
      nix run .#model-analyze     cppcheck + gcc -fanalyzer + clang-tidy + ASan/UBSan
      nix run .#model-fuzz        libFuzzer + ASan/UBSan on random packets
      nix run .#pm-trace [-- pcap] single-step a parse (tools/pm-trace)

    Parser RTL (Phase 5/6)        — Verilator + directed suite + formal
      nix run .#parser-sim        optimized (-O3), run the smoke test
      nix run .#parser-sim-suite  directed suite (pos/neg/boundary/corner packets)
      nix run .#parser-sim-decode directed suite via parser_decode (32-bit words)
      nix run .#parser-sim-trace  + VCD waveform (--trace-structs; gtkwave)
      nix run .#parser-sim-debug  -O0 -ggdb + waveform, for stepping in gdb
      nix run .#parser-lint       --lint-only -Wall, no build (fast lint)
      nix run .#parser-analyze    extra SV lint (verible + svlint)
      nix run .#parser-formal     SymbiYosys: parser_execute safety + wrap G2 (k-induction)
      nix run .#parser-wrap-test  cva6_parser_wrap commit/flush state (I1/G2)

    FPGA board (Phase 8)          — Sipeed Tang Mega 138K Pro / Gowin GW5AST-138
      nix run .#fpga-detect       scan the JTAG chain (expect IDCODE 0x0001081b)
      nix run .#fpga-build [-- X] our RTL -> .fs via Gowin EDA (design X, default blinky)
      nix run .#fpga-uart         read the board UART (auto-detects baud)
      nix run .#fpga-load  -- X.fs   program SRAM  (volatile, the fast inner loop)
      nix run .#fpga-flash -- X.fs   program SPI flash (persists across power cycle)
      nix run .#gowin-vm          interactive Gowin microVM (needs --impure; see docs)
      M1 (parser unit alone on the FPGA) — run in order:
        nix run .#fpga-m1-roms    generate on-chip ROM images from the model (-- --check to drift-guard)
        nix run .#fpga-m1-rtl     sv2v-flatten the parser RTL for GowinSynthesis
        nix run .#fpga-build -- m1  synthesize the parser-on-ROM design
        nix run .#fpga-load -- build/fpga-m1/impl/pnr   program SRAM
        nix run .#fpga-m1-check   read the board UART, diff flow_keys vs libparsermodel
      M2 (host <-> FPGA over an external 3.3V USB-UART on PMOD2 — debug UART is TX-only):
        nix run .#fpga-build -- m2loop                    build the UART loopback bitstream
        nix run .#fpga-load -- build/fpga-m2loop/impl/pnr   program SRAM
        FPGA_UART=/dev/ttyUSB2 nix run .#fpga-m2-loopback-check   confirm the adapter round-trips
        nix run .#fpga-m2-rtl     sv2v-flatten m2_top for GowinSynthesis
        nix run .#fpga-build -- m2   synthesize the injection design
        nix run .#fpga-load -- build/fpga-m2/impl/pnr   program SRAM
        FPGA_UART=/dev/ttyUSB2 nix run .#fpga-m2-inject [-- --suite]   inject packets, diff vs model
      Guide: docs/fpga-bringup-tang-mega-138k-pro.md · status: docs/phase-8-status.md

    Meta
      rtl-help             show this message

  Extend the environment in nix/packages.nix; see docs/nix.md.
  EOF
  }
''
