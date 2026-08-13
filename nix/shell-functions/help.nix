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

    Meta
      rtl-help             show this message

  Extend the environment in nix/packages.nix; see docs/nix.md.
  EOF
  }
''
