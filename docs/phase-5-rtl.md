# Phase 5 — RTL implementation

← [Phase 4](phase-4-microarchitecture.md) · [Docs index](README.md) · [Phase 6 »](phase-6-verification.md)

## Objective

Implement the parser unit in synthesizable **SystemVerilog** and wire it into
CVA6 behind the `custom-0..3` opcodes, realizing the [Phase 4](phase-4-microarchitecture.md)
microarchitecture. Target: run the vertical slice in simulation.

## Inputs / prerequisites

- Phase 3 encoding table (`isa/parser-opcodes.*`) — drives decode.
- Phase 4 microarch (datapath stages, integration signals, register file).
- A CVA6 checkout building under Verilator.

## Design detail

### 5.1 Module breakdown

```
rtl/
  parser_pkg.sv        types, opcodes (generated from isa/ table), enums
  parser_decode.sv     custom-0..3 → parser micro-op + operands
  parser_execute.sv    top of the parser unit; sequences the sub-units
  parser_align.sv      byte aligner over the packet window
  parser_extract.sv    endian + shift/mask → paccum; bounds + implicit length
  parser_length.sv     lensetmin (mul, min, pktlen check)
  parser_compare.sv    cmpi.fail
  parser_cam.sv        CAM / sub-table lookup → pnext
  parser_eon.sv        end-of-node: advance cursor, redirect/exit
  parser_regfile.sv    pcurptr/pcurhdr/paccum/pnext/pktbase/pktlen
  parser_pktbuf.sv     packet window (128/256-bit read port)
  cva6_parser_wrap.sv  glue into CVA6 EX stage
```

`parser_pkg.sv` and the decode case-table are **generated** from the Phase-3
machine-readable table so bits never drift between model, assembler, and RTL.

### 5.2 Decode wiring

Extend CVA6 decode to recognize `custom-0..3` and emit a parser micro-op
(class, width, field selector, qualifiers `.stp/.fail`, immediate, register
operands). Route matching instructions to the parser functional unit at ISSUE.

```systemverilog
// sketch — real code follows CVA6 conventions
always_comb begin
  parser_valid = 1'b0;
  unique case (instr[6:0])
    OPCODE_CUSTOM_0, OPCODE_CUSTOM_1,
    OPCODE_CUSTOM_2, OPCODE_CUSTOM_3: begin
      parser_valid = 1'b1;
      parser_uop   = decode_parser(instr);   // from generated table
    end
    default: /* normal decode */;
  endcase
end
```

### 5.3 Execute & handshake

`parser_execute.sv` implements the ready/valid handshake with CVA6 issue
(latency per Phase 4). It sequences: align → extract (+bounds/implicit length) →
optional length/compare → optional CAM → optional end-of-node. Writeback updates
parser regs and, for `.stp`, drives the fetch-redirect / parse-exit signals.

### 5.4 Writeback, redirect & exceptions

- Normal: write `paccum`/`pcurhdr`/`pnext`/metadata; retire.
- End-of-node with valid `pnext`: request CVA6 PC redirect to the node address.
- End-of-node with no `pnext`, or any bounds/length/compare failure: raise
  **parse-exit** with a status code into the parser status register; return
  control to the caller. Reuse CVA6's exception/redirect plumbing, don't fork it.

### 5.5 Coding standards & lint

- SystemVerilog, synthesizable subset; follow CVA6 style (naming, `_q`/`_n`
  registers, `unique/priority case`).
- **Lint clean** under Verilator `-Wall` and (if available) a commercial linter —
  matters for the "manufacturer-appropriate" goal (ADR-001).
- No latches; reset strategy matches CVA6; parameterize widths
  (`PKT_WINDOW_W`, `CAM_DEPTH`) so Ibex-fallback and sizing sweeps are cheap.

## Step-by-step tasks

1. Generate `parser_pkg.sv` + decode table from `isa/parser-opcodes.*`.
2. Implement leaf units: `parser_align`, `parser_extract`, `parser_length`,
   `parser_compare`, `parser_cam`, `parser_eon`, `parser_regfile`, `parser_pktbuf`.
3. Implement `parser_decode` and `parser_execute` (sequencing + handshake).
4. Write `cva6_parser_wrap.sv`; patch CVA6 decode/issue/EX to route custom opcodes.
5. Bring up in Verilator; run a single hand-assembled Ethernet/IPv4 packet.
6. Extend to the full slice (VLAN, IPv6+ext, TCP/UDP); lint clean.

## Deliverables / artifacts

- `rtl/parser_*.sv` + `cva6_parser_wrap.sv` and the CVA6 integration patch.
- A minimal Verilator smoke test producing a `flow_keys` for one packet.

## Exit criteria

- Design elaborates and lints clean (no latches, no width warnings).
- The full vertical slice runs in Verilator and produces a `flow_keys`.
- Ready for systematic co-simulation ([Phase 6](phase-6-verification.md)).

## Open questions

- **TBD:** exact CVA6 hook points (scoreboard/issue signals) — pin during bring-up.
- **Decision:** CAM as behavioral (sim) first, synthesizable structure later, or
  synthesizable from the start? (Recommend behavioral → synthesizable.)
- **TBD:** how the packet buffer is filled in sim (preload vs DMA model).

## References

CVA6 source & coding style; Phase 3 table; Verilator. See [references.md](references.md).
