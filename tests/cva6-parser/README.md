# In-core directed test — CVA6 PARSER FU

`parser_insn.S` is a bare-metal RISC-V program that exercises the **in-core**
parser functional unit added by `nix/cva6-parser/{decode,issue-ex}.patch`. It is
run on the parser-patched `Variane_testharness` by:

```
nix run .#cva6-parser-test
```

which builds the patched model (same path as `nix run .#cva6-parser`) and then
assembles + runs this ELF, asserting the fesvr `tohost` PASS.

## What it proves

The program places a run of **custom-0** words (`.word 0x1000000b`, a `prs.load`)
at the DRAM entry point, then signals PASS by writing `1` to the `tohost` symbol.
A green run means the whole in-core chain worked:

fetch → `decoder.sv` routes `OpcodeCustom0` to `fu = PARSER` → issue hands it to
the FU over the `parser_valid`/`parser_ready` handshake → `ex_stage.sv`'s
`cva6_parser_wrap` decodes (`parser_decode`) and executes the micro-op → it
retires via the parser writeback port (custom-0 writes no integer `rd`) → the
pipeline advances to the `tohost` store.

On the **stock** core the same words hit the decoder's illegal-instruction
fallback and trap, so the run never reaches `tohost`; the PASS is specific to the
patch.

## Scope (honest)

The in-core packet window (`parser_pktbuf`) and CAM (`parser_cam`) are instantiated
but empty-backed — the packet-data feed (DMA) and CAM programming (custom-3) are
Phase 8. So this test covers the decode/issue/EX/writeback/retire path and the
handshake; it does not yet drive a real packet through the FU or exercise an
end-of-node fetch redirect (that path is wired and elaborates). See
[`docs/analysis/cva6-integration.md`](../../docs/analysis/cva6-integration.md) §3–§8.

## Files

- `parser_insn.S` — the test program (custom-0 words + tohost PASS handshake).
- `link.ld` — riscv-tests-style layout: code at `0x80000000`, writable `.tohost`.
