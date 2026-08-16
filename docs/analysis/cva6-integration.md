# CVA6 integration map — where the parser unit attaches

Signal-level reference for wiring the parser functional unit into CVA6, grounded
in the **pinned** core source (`nix/cva6.nix`: OpenHW Group `cva6`, tag **v5.3.0**,
commit `2ef1c1b1fca419354920c5487293bc605294904e`, target `cv64a6_imafdc_sv39`).
Every file/line reference below is from that tree; re-materialize it with
`nix build .#cva6-src`. This is the Phase-4 "exact stages, signals, redirect path"
deliverable — the map [Phase 5](../phase-5-rtl.md) wires against.

Companion to [phase-4-microarchitecture.md](../phase-4-microarchitecture.md) (the
decisions) and [patent-encodings-recovered.md](patent-encodings-recovered.md) (the
bits those decisions carry).

## 1. The three attachment surfaces CVA6 offers

CVA6 v5.3.0 exposes three distinct ways to add non-standard instructions. Naming
them explicitly settles the ADR-002 "tightly coupled" intent against what the core
actually provides:

| Surface | What it is (in this tree) | Fetch redirect? | Parser fit |
|--|--|--|--|
| **In-pipeline FU** | A new `fu_t` member decoded in `decoder.sv`, issued by `issue_stage`, executed in `ex_stage.sv` alongside ALU/LSU/branch | **Yes** — an EX FU can drive `resolved_branch_o` | **Hot path (custom-0)** |
| **CV-X-IF** (`cvxif_fu.sv`, `cvxif_types.svh`, `cvxif_example/`) | Standardized offload: compressed/issue/register/commit/result channels; result writes an integer `rd` | **No** — result channel has no PC-redirect field | **custom-3 moves** (+fallback) |
| **acc_dispatcher** (`acc_dispatcher.sv`) | Loosely-coupled accelerator port (used to bolt on the Ara vector unit) | Via its own path, coarse-grained | Rejected — RoCC-shaped, the wrong grain (ADR-002) |

**Decision.** custom-0 parser instructions ride the **in-pipeline FU** surface,
because end-of-node is a *computed control-flow transfer* (CAM target → next node)
that must redirect the core's fetch — only an EX FU can drive CVA6's branch
resolution. The custom-3 coprocessor moves (register/CAM/array programming) have no
redirect and read `rs`/write `rd`, so they map cleanly onto **CV-X-IF**; CVXIF is
also the documented fallback if the in-pipeline patch proves too invasive.

## 2. Opcode facts (they already match Phase 3)

`core/include/riscv_pkg.sv`:

```
localparam OpcodeCustom0 = 7'b00_010_11;  // 0x0b
localparam OpcodeCustom1 = 7'b01_010_11;  // 0x2b
localparam OpcodeCustom2 = 7'b10_110_11;  // 0x5b
localparam OpcodeCustom3 = 7'b11_110_11;  // 0x7b
```

`OpcodeCustom0 = 0x0b` and `OpcodeCustom3 = 0x7b` are **exactly** our Phase-3
`PRS_OP_C0` / `PRS_OP_C3` (`model/libparsermodel/encoding.h`,
`isa/parser-opcodes.yaml`). No opcode negotiation is needed — the encodings the
model already emits are the encodings the core will decode.

## 3. The new `fu_t::PARSER` — the decode→issue→EX→writeback chain

`core/include/ariane_pkg.sv` defines the functional-unit tag as a 4-bit enum with
11 members (0–10), so there is spare encoding space:

```systemverilog
typedef enum logic [3:0] {
  NONE, LOAD, STORE, ALU, CTRL_FLOW, MULT, CSR, FPU, FPU_VEC, CVXIF, ACCEL
} fu_t;                     // add PARSER (= 11); width already 4 bits
```

The instruction bundle handed to an FU is `fu_data_t` (operand_a, operand_b, imm,
`operation` (a `fu_op`), `trans_id`) — the parser reuses it: `operand_a/b` carry
integer operands for custom-3 moves; `operation` selects the parser micro-op
(class + qualifiers) decoded from `Fnc4`/discriminators; `trans_id` tags the
writeback.

Signal chain, file by file:

1. **`core/decoder.sv`** — the big `unique case (instr.rtype.opcode)` sets
   `instruction_o.fu` (default `NONE`; unknown opcodes raise `illegal_instr`). Add
   `OpcodeCustom0` / `OpcodeCustom3` cases that set `fu = PARSER`, map `Fnc4`
   (bits `[10:7]`) + discriminators to a `fu_op`, and mark register
   operands/immediate. The decode table is **generated from
   [`isa/parser-opcodes.yaml`](../../isa/parser-opcodes.yaml)** so bits never drift
   from the model/assembler (Phase 5 §5.1).
2. **`core/issue_read_operands.sv` / `issue_stage.sv`** — route `fu == PARSER` to a
   new `parser_valid_o` issue strobe and read any integer `rs` operands (custom-3
   writes). Because the parser is variable-latency (§5), it uses a ready/valid
   handshake, not the fixed-latency (FLU) fast path.
3. **`core/ex_stage.sv`** — instantiate `parser_execute` alongside the existing FUs.
   EX already groups writeback into **FLU** (fixed-latency: ALU + branch + CSR +
   mult share `flu_result_o`/`flu_valid_o`), **LSU**, **FPU**, and **CVXIF**
   (`x_result_o`). The parser is a *fourth variable-latency* group with its own
   writeback port (§5). Note `one_cycle_select = alu_valid | branch_valid |
   csr_valid` — the parser is deliberately **not** in that set.
4. **`core/scoreboard.sv` / `commit_stage.sv`** — the parser writeback retires like
   any other via `trans_id`; custom-0 instructions that touch only parser regs
   retire with **no integer `rd` write** (see §4).

## 4. Writeback + the two output roles

A parser instruction produces up to two effects, and they leave EX by different
ports:

- **Data writeback (optional).** custom-3 *reads* (`prs.mv.x.p`, `prs.cam.read`)
  write an integer `rd`; drive them onto a dedicated `parser_result_o` +
  `parser_trans_id_o` + `parser_valid_o` (a new variable-latency writeback group,
  mirroring how LSU/FPU/CVXIF each own a port). custom-0 instructions write only
  the **parser register file** (internal to the unit) and assert `parser_valid_o`
  with `we = 0` — no integer-RF hazard, so they need no scoreboard `rd`
  dependency.
- **Control-flow writeback (end-of-node).** On `.stp` / `camnext`, the unit
  redirects fetch via the **same path `branch_unit` uses**:
  `output bp_resolve_t resolved_branch_o` + `output logic resolve_branch_o`
  (`ex_stage.sv:73-75`). `bp_resolve_t` carries `{valid, target_address, is_taken,
  is_mispredict, cf_type}`; the frontend consumes it and `controller.sv` issues the
  flush. The parser computes `target_address` from the `Next`/`Loop` register (a
  computed, JALR-like target — see `branch_unit.sv` `jump_base` for the pattern),
  not from an immediate.

**Arbitration point (Phase-5 bring-up TBD).** `resolved_branch_o` is presently
driven by `branch_unit` inside the one-cycle FLU. The parser is multi-cycle, so its
redirect must be **muxed onto `resolved_branch_o` when the parser completes**, and
only one of {branch, parser} may resolve in a given cycle. In-order issue + a
single in-flight parser op (§ regfile hazard) makes this mutually exclusive by
construction; the mux/priority is pinned during bring-up.

## 5. Latency & handshake

The parser is **variable-latency**, like LSU/FPU/CVXIF — not fixed-latency (FLU).
Expected shape for the slice:

| Op | Datapath | Cycles (target) |
|--|--|--|
| `prs.load.*` | align → endian → shift/mask (+bounds, implicit length) | 1 |
| `prs.lensetmin` / `prs.cmpi.*` | field select → compare/clamp | 1 |
| `prs.cam.*` / `.stp` | (load) → CAM lookup → end-of-node redirect | 2–3 |
| custom-3 move / CAM write | coprocessor R-form → p-reg / CAM array | 1 |

The unit exposes `parser_ready_o` to issue and `parser_valid_o` on completion
(ready/valid). Multi-cycle ops stall issue of the *next* parser op (single in-flight
op, §6); other FUs are unaffected. Semantics are latency-independent — the ISA
spec (Phase 1) never encodes cycle counts (layer discipline).

## 6. Register file & hazards

- **32 × 64-bit parser registers** live *inside* the parser unit (`parser_regfile`),
  not in CVA6's integer RF. Layouts + packed sub-fields (`CurHdr`, `DataBndLoop`,
  `Counters`, …) are in [patent-encodings-recovered.md](patent-encodings-recovered.md)
  §"registers"; the file exposes sub-register read/write keyed by `(Pos, Sz)` per the
  MSB-first sub-register convention.
- **Hazards: one in-flight parser op.** A single "parser busy" interlock at issue
  (a parser op cannot issue while one is executing) removes every parser-reg
  RAW/WAW/WAR hazard for free — correct and cheap for the slice, given in-order
  issue and a single parser unit. No rename, no per-p-reg scoreboarding.
- **Integer-side hazards** for custom-3 moves are the ordinary scoreboard `rs`/`rd`
  dependencies CVA6 already tracks.

## 7. Exceptions / parser exit

The patent defines **no CPU traps** for the parser — exits are explicit jumps
(Phase 1 §1.8). A bounds/length/compare failure or a `.stp` with no valid `Next`
sets the parser status (`ParserExitCode`: error code + address) and redirects to
`OkayTarget`/`FailTarget` via the **same `resolved_branch_o` path** as end-of-node
(§4) — *not* CVA6's `exception_t` trap path. This keeps the parser out of the
machine-mode trap/`mcause` machinery entirely.

## 8. Files to touch (Phase-5 checklist)

Add (new, in `rtl/`): `parser_pkg.sv`, `parser_decode.sv`, `parser_execute.sv`,
the leaf units (`parser_align/extract/length/compare/cam/eon/regfile/pktbuf/meta`),
and `cva6_parser_wrap.sv`.

Patch (in the pinned CVA6 tree, as a tracked diff — mirrors the one-patch approach
already used by `scripts/cva6-baseline.sh`):

| File | Change | Status |
|--|--|--|
| `core/include/ariane_pkg.sv` | add `PARSER` to `fu_t`; parser `fu_op`s (`PARSER_C0`/`PARSER_C3`) | ✅ |
| `core/decoder.sv` | `OpcodeCustom0`/`Custom3` → `fu = PARSER` + `fu_op` | ✅ |
| `core/issue_read_operands.sv`, `issue_stage.sv` | route/handshake `parser_valid`/`parser_ready` | ⏭ |
| `core/ex_stage.sv` | instantiate `parser_execute`; new WB group; mux `resolved_branch_o` | ⏭ |
| `core/scoreboard.sv`, `commit_stage.sv` | retire parser WB by `trans_id` (no `rd` for custom-0) | ⏭ |
| `core/cva6.sv` | thread parser ports + packet-buffer interface | ⏭ |

The ✅ rows land as `nix/cva6-parser/decode.patch`, applied to the pinned source
by the cached `cva6-parser-src` derivation; `nix run .#cva6-parser` builds the
patched Verilator model (vs `nix run .#cva6-baseline` for the stock core), so the
decode integration is verified to elaborate with no baseline regression. The
patch stays a plain unified diff so it reviews on its own. The parser micro-op is
decoded **inside** the FU by `rtl/parser_decode.sv` (proven by
`nix run .#parser-sim-decode`), so the ⏭ issue/EX rows thread the raw instruction
word to the FU rather than pre-decoding a wide `fu_op` in the core decoder.

CVXIF path (alternative for custom-3, or fallback): implement a coprocessor behind
`cvxif_fu.sv` using the `X_ISSUE`/`X_REGISTER`/`X_COMMIT`/`X_RESULT` channels in
`core/include/cvxif_types.svh` — no core patch required, but no fetch redirect
either (§1).

## References

CVA6 v5.3.0 source (pinned, `nix/cva6.nix`); CV-X-IF spec (OpenHW); Phase 3 table
([`isa/parser-opcodes.yaml`](../../isa/parser-opcodes.yaml)). See
[references.md](../references.md).
