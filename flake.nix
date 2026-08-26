#
# flake.nix for rtl-fun — parser instructions for RISC-V
#
# Provides a reproducible development environment so everyone working in this
# repo has the same tools. Modeled on the modular ./nix/ layout used by the
# nearby xdp2 project.
#
# Enter the dev shell:
#   nix develop
#
# If flakes are not enabled system-wide:
#   nix --extra-experimental-features 'nix-command flakes' develop .
#
# Once inside, run `rtl-help` for the tool list.
#
# Extending: add packages in nix/packages.nix; add build derivations or script
# runners as new nix/<name>.nix modules and wire them into outputs below (see
# docs/nix.md).
#
{
  description = "rtl-fun — RISC-V parser-instruction ISA extension (docs, model, RTL)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # microvm.nix — used only by the Gowin EDA feasibility VM (nix/gowin-vm.nix),
    # which presents the license-locked MAC to a throwaway guest. See docs/gowin-microvm.md.
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  # Per-system outputs live inside eachDefaultSystem; the Gowin microVM is a single
  # x86_64-linux NixOS system merged in alongside them (recursiveUpdate, not //, so it
  # does not clobber the ~40 per-system packages). All VM logic is in nix/gowin-vm.nix.
  outputs = { self, nixpkgs, flake-utils, microvm }:
    let
      gowin = import ./nix/gowin-vm.nix { inherit nixpkgs microvm; };
    in
    nixpkgs.lib.recursiveUpdate
      (flake-utils.lib.eachDefaultSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = nixpkgs.lib;

          # Tool groups (docs / rtl / sim / toolchain / common).
          packages = import ./nix/packages.nix { inherit pkgs; };

          # Pinned CVA6 base-core source (fetched via Nix; built imperatively).
          cva6-src = import ./nix/cva6.nix { inherit pkgs; };

          # Parser-patched CVA6 source, as its own cacheable derivation (only
          # rebuilds when the source or the patch changes).
          cva6-parser-src = import ./nix/cva6-patched.nix {
            inherit pkgs cva6-src;
            parserRtl = ./rtl;
          };

          # Tandem-patched Spike (libriscv with the RVFI DPI + openhw Simulation/Params
          # model + commitlog), source-built from the vendored tree as its own cached
          # store path. Enables the Phase-7 RVFI-vs-Spike lock-step; uses the UNPATCHED
          # source (the vendored spike is identical in both trees). Stage 1b compiles the
          # parser customext extension (nix/spike-tandem/parser_ext.cc) + the reused
          # reference model into libcustomext.so so parser ops can be lock-stepped; Stage
          # 1c adds the parser MMIO packet device (parser_mmio.h) into libriscv so
          # packet-load ops + the flow_keys/status readback lock-step too.
          spike-tandem = import ./nix/spike-tandem.nix {
            inherit pkgs cva6-src;
            spikeExt = ./nix/spike-tandem; # parser_ext.cc + parser_shared.h + parser_mmio.h
            modelSrc = ./model/libparsermodel;
          };

          # Phase 7 Stage 2: the RUNNABLE, standalone parser Spike (install-exes) —
          # same customext + 0x5000_0000 MMIO injection as spike-tandem, but ships the
          # `spike` executable so `nix run .#parser-spike` runs a bare parser ELF.
          spike-parser = import ./nix/spike-parser.nix {
            inherit pkgs cva6-src;
            spikeExt = ./nix/spike-tandem; # reuse the same ext + MMIO sources
            modelSrc = ./model/libparsermodel;
          };
          parser-spike = import ./nix/parser-spike.nix { inherit pkgs spike-parser; };
          # Phase 7 Stage 3: the same runner with SLICE=1 — drives the standalone Spike
          # from the C-intrinsics slice (tests/cva6-parser/parser_slice.c), byte-parity
          # checked vs the model ROM: `nix run .#parser-spike-slice`.
          parser-spike-slice = import ./nix/parser-spike-slice.nix { inherit pkgs spike-parser; };

          # Phase 7 QEMU leg: nixpkgs qemu patched to teach qemu-system-riscv64 the
          # parser ISA + the 0x5000_0000 packet MMIO device, reusing the golden model.
          # `nix build .#qemu-parser`.
          qemu-parser = import ./nix/qemu-parser.nix {
            inherit pkgs;
            qemuExt = ./nix/qemu-parser; # our QEMU-native C (helper + device)
            modelSrc = ./model/libparsermodel; # the reused pure-C model
          };

          # Phase-7 QEMU leg: run the SAME self-checking ELFs on the patched
          # qemu-system-riscv64 == the golden model (the QEMU twin of parser-spike).
          # `nix run .#parser-qemu` (asm corpus) / `nix run .#parser-qemu-slice` (C slice).
          parser-qemu = import ./nix/parser-qemu.nix { inherit pkgs qemu-parser; };
          parser-qemu-slice = import ./nix/parser-qemu-slice.nix { inherit pkgs qemu-parser; };

          # Two Verilator builds from ONE builder, for easy unpatched-vs-patched
          # compare: cva6-baseline (stock) and cva6-parser (patched). Distinct work
          # dirs so they don't collide under build/.
          cva6-baseline = import ./nix/cva6-baseline.nix { inherit pkgs cva6-src; };
          cva6-parser = import ./nix/cva6-baseline.nix {
            inherit pkgs;
            cva6-src = cva6-parser-src;
            name = "cva6-parser";
            cva6Work = "$PWD/build/parser-core";
          };

          # Build the patched model + run the in-core directed test (custom-0 PARSER
          # ops issue/execute/retire; fesvr tohost PASS).
          cva6-parser-test = import ./nix/cva6-parser-test.nix {
            inherit pkgs;
            cva6-src = cva6-parser-src;
          };

          # Build the patched model + run the table-driven in-core co-simulation
          # (I5): packet -> flow_keys equivalence vs the golden model, over real MMIO.
          cva6-parser-cosim = import ./nix/cva6-parser-cosim.nix {
            inherit pkgs;
            cva6-src = cva6-parser-src;
          };

          # Phase 7, Stage 0 (G11): build the patched model WITH the RVFI-vs-Spike
          # lock-step (SPIKE_TANDEM=1) + run the base-ISA slice under per-instruction
          # tandem verification against the source-built tandem Spike.
          cva6-parser-tandem = import ./nix/cva6-parser-tandem.nix {
            inherit pkgs spike-tandem;
            cva6-src = cva6-parser-src;
          };

          # Phase 7, Stage 2: the random-packet tandem campaign — hundreds of seeded
          # constrained-random + real xdp2-corpus packets driven through the SAME
          # RVFI-vs-Spike lock-step (shares build/parser-tandem with the tandem app).
          cva6-parser-tandem-campaign = import ./nix/cva6-parser-tandem-campaign.nix {
            inherit pkgs spike-tandem xdp2-src;
            cva6-src = cva6-parser-src;
          };

          # Negative control (G11): build the STOCK model + assert the base core
          # REJECTS a custom-0 parser word (illegal-instruction trap). Uses the
          # unpatched source, so the parser ops are proven a genuine ISA extension.
          parser-negative-control = import ./nix/parser-negative-control.nix {
            inherit pkgs cva6-src;
          };

          # V7 (G7): build the patched model + assert a faulting instruction (an ecall)
          # that flushes an in-flight parser op does not corrupt its committed result.
          cva6-parser-trap-v7 = import ./nix/parser-trap-v7.nix {
            inherit pkgs;
            cva6-src = cva6-parser-src;
          };

          # V6 (G7): build the patched model + assert a machine software interrupt (msip)
          # that flushes an in-flight parser op mid-parse does not corrupt its committed
          # result — the asynchronous companion to V7's synchronous ecall.
          cva6-parser-trap-v6 = import ./nix/parser-trap-v6.nix {
            inherit pkgs;
            cva6-src = cva6-parser-src;
          };

          # V10 (G7 / §3.1 item 4; ratifies D7): build the patched model + assert a
          # between-parse context switch — spill/clobber/reload of the five writable parser
          # registers {p11,p13,p14,p15,p16} via the custom-3 move ABI — round-trips the
          # parser register context bit-for-bit through memory.
          cva6-parser-ctxsw-v10 = import ./nix/parser-ctxsw-v10.nix {
            inherit pkgs;
            cva6-src = cva6-parser-src;
          };

          # M1 mid-parse context switch (§3.1 item 4, register half; ratifies D7's
          # mid-parse follow-on): an interrupt preempts an in-flight parse, the ISR
          # saves/clobbers/restores the resumable position+data registers via the custom-3 ABI,
          # and the parse resumes to the model's byte-exact flow_keys.
          cva6-parser-ctxsw-mid = import ./nix/parser-ctxsw-mid.nix {
            inherit pkgs;
            cva6-src = cva6-parser-src;
          };

          # Base-ISA regression (G11): build the patched model + assert a directed slice
          # of RV64GC (integer/M/A/F/D/CSR/branches) still retires correctly on the
          # PATCHED core — the parser extension is transparent to the base ISA. Companion
          # to the negative control (N1).
          cva6-parser-baseisa = import ./nix/parser-baseisa.nix {
            inherit pkgs;
            cva6-src = cva6-parser-src;
          };

          # 2nd-config integration (G10): build the patched model under the RV64GC
          # write-back-cache config (cv64a6_imafdc_sv39_wb) + run the in-core parser test
          # — the FU integrates under a different config, not just the default.
          cva6-parser-config-wb = import ./nix/parser-config-wb.nix {
            inherit pkgs;
            cva6-src = cva6-parser-src;
          };

          # Pinned xdp2 source (for the proto_audit packet corpus, Phase 2).
          xdp2-src = import ./nix/xdp2.nix { inherit pkgs; };

          # Golden-model apps: `model-test` (unit + corpus tests) and `pm-trace`.
          model = import ./nix/model.nix { inherit pkgs xdp2-src; };

          # Parser-unit RTL apps (Phase 5): parser-sim{,-trace,-debug} + parser-lint.
          rtl = import ./nix/rtl.nix { inherit pkgs; };

          # Phase-7 codegen spine: regenerate toolchain/generated from the ISA yaml
          # and verify no yaml↔C drift (`nix run .#parser-gen-check`).
          parser-gen = import ./nix/parser-gen.nix { inherit pkgs; };

          # Phase-7 L2 (binutils): a parser-patched riscv64-none-elf binutils +
          # the assembler round-trip test (`nix run .#parser-asm-test`).
          parser-asm = import ./nix/parser-asm-test.nix { inherit pkgs; };

          # Phase-7 L3 (LLVM MC): a parser-patched llvm (RISCV-only) + the llvm-mc
          # assemble/disassemble round-trip test (`nix run .#parser-llvm-mc-test`).
          parser-llvm-mc = import ./nix/parser-llvm-mc-test.nix { inherit pkgs; };

          # Phase-7 C0 (Clang): a clang built against the parser-patched libLLVM + the
          # stand-up proof (`nix run .#parser-clang-check`). No builtins yet — C0 just
          # proves the build + that clang's integrated-as sees the parser MC layer.
          parser-clang = import ./nix/parser-clang.nix { inherit pkgs; };

          # Phase-7 C2 (Clang): the Phase-0 slice compiled through the parser-patched
          # Clang using the __builtin_riscv_prs_* builtins, run on the standalone Spike
          # over the 22-case corpus == the golden model (`nix run .#parser-clang-slice`).
          parser-clang-slice = import ./nix/parser-clang-slice.nix {
            inherit pkgs spike-parser;
            parser-clang = parser-clang.parser-clang;
          };

          # Phase-7 C3 (Clang): the custom-3 register-move builtins — a table-driven masked
          # encoding check + a builtins-only p-register round-trip on the standalone Spike
          # (`nix run .#parser-clang-moves`).
          parser-clang-moves = import ./nix/parser-clang-moves.nix {
            inherit pkgs spike-parser;
            parser-clang = parser-clang.parser-clang;
            parser-llvm = import ./nix/parser-llvm.nix { inherit pkgs; };
          };

          # The default development shell (exports CVA6_SRC -> the pinned source,
          # and puts the cva6-baseline app on PATH).
          devshell = import ./nix/devshell.nix {
            inherit pkgs lib packages cva6-src cva6-baseline;
          };
        in
        {
          devShells.default = devshell;

          packages = {
            # The pinned CVA6 source: `nix build .#cva6-src`.
            cva6-src = cva6-src;
            # The parser-patched CVA6 source: `nix build .#cva6-parser-src`.
            cva6-parser-src = cva6-parser-src;
            # The tandem-patched Spike: `nix build .#spike-tandem`.
            spike-tandem = spike-tandem;
            # The standalone RUNNABLE parser Spike: `nix build .#spike-parser`.
            spike-parser = spike-parser;
            parser-spike = parser-spike;
            parser-spike-slice = parser-spike-slice;
            qemu-parser = qemu-parser;
            parser-qemu = parser-qemu;
            parser-qemu-slice = parser-qemu-slice;
            # The two Verilator builders as packages too.
            cva6-baseline = cva6-baseline;
            cva6-parser = cva6-parser;
            cva6-parser-test = cva6-parser-test;
            cva6-parser-cosim = cva6-parser-cosim;
            cva6-parser-tandem = cva6-parser-tandem;
            cva6-parser-tandem-campaign = cva6-parser-tandem-campaign;
            parser-negative-control = parser-negative-control;
            cva6-parser-trap-v7 = cva6-parser-trap-v7;
            cva6-parser-trap-v6 = cva6-parser-trap-v6;
            cva6-parser-ctxsw-v10 = cva6-parser-ctxsw-v10;
            cva6-parser-ctxsw-mid = cva6-parser-ctxsw-mid;
            cva6-parser-baseisa = cva6-parser-baseisa;
            cva6-parser-config-wb = cva6-parser-config-wb;
            # The pinned xdp2 source (packet corpus): `nix build .#xdp2-src`.
            xdp2-src = xdp2-src;
            # Golden-model runners as packages too.
            model-test = model.model-test;
            model-analyze = model.model-analyze;
            model-fuzz = model.model-fuzz;
            pm-trace = model.pm-trace;
            # Parser-unit RTL sim/lint runners as packages too.
            parser-sim = rtl.parser-sim;
            parser-sim-suite = rtl.parser-sim-suite;
            parser-sim-decode = rtl.parser-sim-decode;
            parser-sim-trace = rtl.parser-sim-trace;
            parser-sim-debug = rtl.parser-sim-debug;
            parser-lint = rtl.parser-lint;
            parser-analyze = rtl.parser-analyze;
            parser-formal = rtl.parser-formal;
            parser-wrap-test = rtl.parser-wrap-test;
            parser-coverage = rtl.parser-coverage;
            # Phase-7 codegen spine check.
            parser-gen-check = parser-gen.parser-gen-check;
            # Phase-7 L2: the parser-patched binutils + the assembler test.
            parser-binutils = parser-asm.parser-binutils;
            parser-asm-test = parser-asm.parser-asm-test;
            # Phase-7 L3: the parser-patched llvm + the llvm-mc test.
            parser-llvm = parser-llvm-mc.parser-llvm;
            parser-llvm-mc-test = parser-llvm-mc.parser-llvm-mc-test;
            parser-clang = parser-clang.parser-clang;
            parser-clang-check = parser-clang.parser-clang-check;
            parser-clang-builtins-test = parser-clang.parser-clang-builtins-test;
            parser-clang-slice = parser-clang-slice;
            parser-clang-moves = parser-clang-moves;
          };

          # Build the stock CVA6 Verilator model: `nix run .#cva6-baseline`.
          apps.cva6-baseline = {
            type = "app";
            program = "${cva6-baseline}/bin/cva6-baseline";
          };

          # Build the parser-patched CVA6 Verilator model: `nix run .#cva6-parser`.
          # Same builder as the baseline, different source — run both to compare.
          apps.cva6-parser = {
            type = "app";
            program = "${cva6-parser}/bin/cva6-parser";
          };

          # Build the patched model and run the in-core directed test:
          # `nix run .#cva6-parser-test`.
          apps.cva6-parser-test = {
            type = "app";
            program = "${cva6-parser-test}/bin/cva6-parser-test";
          };

          # Build the patched model and run the table-driven in-core co-simulation:
          # `nix run .#cva6-parser-cosim`.
          apps.cva6-parser-cosim = {
            type = "app";
            program = "${cva6-parser-cosim}/bin/cva6-parser-cosim";
          };

          # Base-ISA RVFI-vs-Spike lock-step (Phase 7, Stage 0): every retired RV64GC
          # instruction is matched against Spike in tandem: `nix run .#cva6-parser-tandem`.
          apps.cva6-parser-tandem = {
            type = "app";
            program = "${cva6-parser-tandem}/bin/cva6-parser-tandem";
          };

          # Random-packet tandem campaign (Phase 7, Stage 2): hundreds of seeded
          # constrained-random + real-corpus packets under RVFI-vs-Spike lock-step:
          # `nix run .#cva6-parser-tandem-campaign`.
          apps.cva6-parser-tandem-campaign = {
            type = "app";
            program = "${cva6-parser-tandem-campaign}/bin/cva6-parser-tandem-campaign";
          };

          # Negative control (G11): the stock core must reject the parser ops:
          # `nix run .#parser-negative-control`.
          apps.parser-negative-control = {
            type = "app";
            program = "${parser-negative-control}/bin/parser-negative-control";
          };

          # V7 faulting-instruction squash (G7): the ecall-flushed parser op must
          # re-execute and commit the same result: `nix run .#cva6-parser-trap-v7`.
          apps.cva6-parser-trap-v7 = {
            type = "app";
            program = "${cva6-parser-trap-v7}/bin/cva6-parser-trap-v7";
          };

          # V6 interrupt-mid-parse squash (G7): a machine software interrupt (msip) must
          # flush an in-flight parser op which re-executes to the same committed result:
          # `nix run .#cva6-parser-trap-v6`.
          apps.cva6-parser-trap-v6 = {
            type = "app";
            program = "${cva6-parser-trap-v6}/bin/cva6-parser-trap-v6";
          };

          # V10 between-parse context switch (G7 / §3.1 item 4; ratifies D7): the custom-3
          # move ABI must round-trip the parser register context bit-for-bit through a
          # simulated context switch: `nix run .#cva6-parser-ctxsw-v10`.
          apps.cva6-parser-ctxsw-v10 = {
            type = "app";
            program = "${cva6-parser-ctxsw-v10}/bin/cva6-parser-ctxsw-v10";
          };

          # M1 mid-parse context switch (§3.1 item 4, register half; ratifies D7): an
          # interrupt-preempted parse saves/clobbers/restores its full parser register
          # context via the custom-3 ABI and resumes to the model's flow_keys:
          # `nix run .#cva6-parser-ctxsw-mid`.
          apps.cva6-parser-ctxsw-mid = {
            type = "app";
            program = "${cva6-parser-ctxsw-mid}/bin/cva6-parser-ctxsw-mid";
          };

          # Base-ISA regression (G11): RV64GC must still retire correctly on the patched
          # core — the parser extension is transparent to the base ISA:
          # `nix run .#cva6-parser-baseisa`.
          apps.cva6-parser-baseisa = {
            type = "app";
            program = "${cva6-parser-baseisa}/bin/cva6-parser-baseisa";
          };

          # 2nd-config FU integration (G10): the parser FU must issue/execute/retire
          # under the RV64GC write-back-cache config too: `nix run .#cva6-parser-config-wb`.
          apps.cva6-parser-config-wb = {
            type = "app";
            program = "${cva6-parser-config-wb}/bin/cva6-parser-config-wb";
          };

          # Run the golden-model tests: `nix run .#model-test`.
          apps.model-test = {
            type = "app";
            program = "${model.model-test}/bin/model-test";
          };

          # Phase-7 codegen spine: regenerate + drift check `nix run .#parser-gen-check`.
          apps.parser-gen-check = {
            type = "app";
            program = "${parser-gen.parser-gen-check}/bin/parser-gen-check";
          };

          # Phase-7 L2 (binutils): assemble every parser mnemonic with the patched
          # binutils + check words vs goldens and readable objdump: `nix run .#parser-asm-test`.
          apps.parser-asm-test = {
            type = "app";
            program = "${parser-asm.parser-asm-test}/bin/parser-asm-test";
          };

          # Phase-7 L3 (LLVM MC): assemble + disassemble the parser mnemonics with the
          # patched llvm-mc/llvm-objdump == the generated/model goldens (round-trip):
          # `nix run .#parser-llvm-mc-test`.
          apps.parser-llvm-mc-test = {
            type = "app";
            program = "${parser-llvm-mc.parser-llvm-mc-test}/bin/parser-llvm-mc-test";
          };

          # Phase-7 C0 (Clang): stand up the parser-patched clang + prove its integrated
          # assembler sees the parser MC layer and the C slice byte-parity holds under it:
          # `nix run .#parser-clang-check`.
          apps.parser-clang-check = {
            type = "app";
            program = "${parser-clang.parser-clang-check}/bin/parser-clang-check";
          };

          # Phase-7 C1 (Clang builtins): compile every __builtin_riscv_prs_* and check it
          # emits the exact parser encoding: `nix run .#parser-clang-builtins-test`.
          apps.parser-clang-builtins-test = {
            type = "app";
            program = "${parser-clang.parser-clang-builtins-test}/bin/parser-clang-builtins-test";
          };

          # Phase-7 Stage 2 (standalone Spike): run parser ELFs on the runnable parser
          # Spike + check they self-report SUCCESS: `nix run .#parser-spike`.
          apps.parser-spike = {
            type = "app";
            program = "${parser-spike}/bin/parser-spike";
          };

          # Phase-7 Stage 3 (C-intrinsics slice): run the slice authored in C on the
          # standalone Spike == the golden model: `nix run .#parser-spike-slice`.
          apps.parser-spike-slice = {
            type = "app";
            program = "${parser-spike-slice}/bin/parser-spike-slice";
          };

          # Phase-7 C2 (Clang builtins slice): run the slice compiled through the
          # parser-patched Clang via __builtin_riscv_prs_* on the standalone Spike ==
          # the golden model: `nix run .#parser-clang-slice`.
          apps.parser-clang-slice = {
            type = "app";
            program = "${parser-clang-slice}/bin/parser-clang-slice";
          };

          # Phase-7 C3 (Clang register-move builtins): masked encoding check + a p-register
          # round-trip through the builtins on the standalone Spike: `nix run .#parser-clang-moves`.
          apps.parser-clang-moves = {
            type = "app";
            program = "${parser-clang-moves}/bin/parser-clang-moves";
          };

          # Phase-7 QEMU leg: run the same parser ELFs / C slice on the patched
          # qemu-system-riscv64 == the golden model. `nix run .#parser-qemu` and
          # `nix run .#parser-qemu-slice` — closes the exit criterion (Spike AND QEMU).
          apps.parser-qemu = {
            type = "app";
            program = "${parser-qemu}/bin/parser-qemu";
          };
          apps.parser-qemu-slice = {
            type = "app";
            program = "${parser-qemu-slice}/bin/parser-qemu-slice";
          };

          # Static analysis + sanitizers for the C model: `nix run .#model-analyze`.
          apps.model-analyze = {
            type = "app";
            program = "${model.model-analyze}/bin/model-analyze";
          };

          # Fuzz the C model (libFuzzer + ASan/UBSan): `nix run .#model-fuzz`.
          apps.model-fuzz = {
            type = "app";
            program = "${model.model-fuzz}/bin/model-fuzz";
          };

          # Single-step a parse for debugging: `nix run .#pm-trace [-- x.pcap]`.
          apps.pm-trace = {
            type = "app";
            program = "${model.pm-trace}/bin/pm-trace";
          };

          # Parser-unit RTL smoke test (Phase 5), at four debug levels:
          #   nix run .#parser-sim         optimized, run the smoke test
          #   nix run .#parser-sim-trace   + FST waveform (--trace-structs)
          #   nix run .#parser-sim-debug   -O0 -ggdb + waveform (gdb)
          #   nix run .#parser-lint        --lint-only -Wall, no build
          apps.parser-sim = {
            type = "app";
            program = "${rtl.parser-sim}/bin/parser-sim";
          };
          apps.parser-sim-suite = {
            type = "app";
            program = "${rtl.parser-sim-suite}/bin/parser-sim-suite";
          };
          # Directed suite via the CVA6 decode path (32-bit words -> parser_decode).
          apps.parser-sim-decode = {
            type = "app";
            program = "${rtl.parser-sim-decode}/bin/parser-sim-decode";
          };
          apps.parser-sim-trace = {
            type = "app";
            program = "${rtl.parser-sim-trace}/bin/parser-sim-trace";
          };
          apps.parser-sim-debug = {
            type = "app";
            program = "${rtl.parser-sim-debug}/bin/parser-sim-debug";
          };
          apps.parser-lint = {
            type = "app";
            program = "${rtl.parser-lint}/bin/parser-lint";
          };
          # Extra SV static analysis (verible + svlint): `nix run .#parser-analyze`.
          apps.parser-analyze = {
            type = "app";
            program = "${rtl.parser-analyze}/bin/parser-analyze";
          };
          # Formal proof of parser_execute safety: `nix run .#parser-formal`.
          apps.parser-formal = {
            type = "app";
            program = "${rtl.parser-formal}/bin/parser-formal";
          };
          # I1 commit-visible parser-state testbench: `nix run .#parser-wrap-test`.
          apps.parser-wrap-test = {
            type = "app";
            program = "${rtl.parser-wrap-test}/bin/parser-wrap-test";
          };

          # Coverage (G12): line/toggle + functional cover points, merged report +
          # 100%-functional closure gate: `nix run .#parser-coverage`.
          apps.parser-coverage = {
            type = "app";
            program = "${rtl.parser-coverage}/bin/parser-coverage";
          };

          # `nix fmt` formats the .nix files.
          formatter = pkgs.nixpkgs-fmt;
        }))
      {
        # Gowin EDA feasibility VM (x86_64-linux only). Build/run:
        #   nix run .#gowin-vm
        nixosConfigurations.gowin-vm = gowin.nixos;
        packages.x86_64-linux.gowin-vm = gowin.runner;
      };
}
