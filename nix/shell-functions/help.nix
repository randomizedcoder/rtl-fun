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
      cva6-baseline        build the stock CVA6 Verilator model (Phase 0 baseline)

    Golden model (Phase 2)
      nix run .#model-test        run the reference-model unit + corpus tests
      nix run .#pm-trace [-- pcap] single-step a parse (tools/pm-trace)

    Meta
      rtl-help             show this message

  Extend the environment in nix/packages.nix; see docs/nix.md.
  EOF
  }
''
