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
      python3 docs/analysis/bitgen.py    regenerate the ASCII bit diagrams
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
      nix build .#cva6-parser-src patched CVA6 source only (cached derivation)

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
      nix run .#parser-formal     SymbiYosys proof of parser_execute safety

    Meta
      rtl-help             show this message

  Extend the environment in nix/packages.nix; see docs/nix.md.
  EOF
  }
''
