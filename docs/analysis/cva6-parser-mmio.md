# CVA6 parser MMIO peripheral (I5)

> **Status:** design + implementation (increment I5). Closes the deferred
> packet-feed / flow_keys-readback escalation the I2 sim-only backdoor stood in for
> (see [`cva6-implementation-status.md`](cva6-implementation-status.md),
> memory *I2 backdoor, defer MMIO*). Written retroactively against the landed code
> to review the design as a whole — read it as the contract the
> `cva6-parser-cosim` app depends on.

## 1. Why this exists

The in-core parser FU (I1–I4b) could **execute** custom-0/custom-3 ops in the CVA6
pipeline, but nothing could get a **packet** into it or read the resulting
**flow_keys** out: `parser_pktbuf` was instantiated read-only and empty-backed
(reads returned zero), `parse_len_i` was tied to `PKT_MAX`, and the metadata frame
was observable only through a simulation-only hierarchical-XMR backdoor in the
testharness (`tb-backdoor.patch`). That backdoor is a *deliberate shorter path*: it
proves side-effects land, but it is not a real I/O path and cannot drive a
table-driven, packet-by-packet co-simulation against the golden model.

I5 makes the packet buffer and flow_keys frame **software-visible over real MMIO**,
so a bare-metal program can `sd` a packet in, set `ParseLen`, run the parser slice
program in-core, and `ld` the committed flow_keys back out to compare against the
model. This is the substrate the `cva6-parser-cosim` app needs.

## 2. Address map

A new AXI slave, `ariane_soc::Parser`, at a free gap between GPIO
(`…0x4000_1000`) and DRAM (`0x8000_0000`):

| Symbol            | Value          | Notes |
|-------------------|----------------|-------|
| `ParserBase`      | `0x5000_0000`  | 4 KiB window (`ParserLength = 0x1000`) |

Within the window (offsets are `addr[11:0]`; decoded in `ariane_testharness.sv`):

| Offset        | Dir   | Meaning |
|---------------|-------|---------|
| `0x000..0x0FF`| write | **packet buffer** — byte offset = window offset; 8-byte `sd` + `wstrb` scatter (`PKT_MAX = 256`) |
| `0x100`       | write | **ParseLen** — low 16 bits → `PktLen.ParseLen` (resets to `PKT_MAX`: an unconfigured run parses the whole buffer, matching the pre-I5 tie-off) |
| `0x108`       | write | **exit landing PC** — 64-bit byte PC the FU resumes at when the parse exits (see §5) |
| `0x100`       | read  | **exit status** — `[32]` = parse-exited-seen, `[31:0]` = signed `ParserExitCode` (latched) |
| `0x200..0x23F`| read  | **flow_keys frame** — meta offset = window offset − `0x200`; 8-byte `ld` (`META_MAX = 64`) |

The symbolic map for bare-metal code lives in
[`toolchain/parser_mmio.h`](../../toolchain/parser_mmio.h).

Reads and writes to the same offset (`0x100`) carry different meaning; `axi2mem`
distinguishes them by `we`, so this is unambiguous.

## 3. Peripheral architecture

The packet buffer's read window and the flow_keys frame are **inside** the EX-stage
FU (the window read is combinational, one cycle — moving it onto the AXI fabric
would break that timing). So the peripheral is a **bridge**, not a memory: it turns
AXI beats into the FU's write/read ports.

```
CPU sd/ld ─▶ AXI xbar ─▶ master[Parser] ─▶ axi2mem ─▶ req/we/addr/be/wdata/rdata
                                                          │
                                       ┌──────────────────┴───────────────────┐
                                       │  decode (ariane_testharness.sv)       │
                                       │   we & off<0x100   → pkt write         │
                                       │   we & off==0x100  → ParseLen reg      │
                                       │   we & off==0x108  → exit-PC reg       │
                                       │   ~we & off==0x100 → exit-status rdata │
                                       │   ~we & off in meta→ meta rdata        │
                                       └──────────────────┬───────────────────┘
             threaded ariane → cva6 → ex_stage → { parser_pktbuf, cva6_parser_wrap }
```

`axi2mem` is the same adapter the bootrom and DRAM use. Timing contract (from
`axi2mem.sv`): a write beat pulses `req/we/addr/be/data_o` for one cycle (captured
by the clocked `parser_pktbuf` write).

> **⚠ Read data MUST be registered — `axi2mem` assumes a 1-cycle-latency (synchronous)
> memory.** This bit us during I5 bring-up. In its `READ` state `axi2mem` combinationally
> advances `addr_o` to the *next* beat address the instant `r_ready` is high
> (`axi2mem.sv` ~L193, `addr_o = cons_addr`). The read data line `slave.r_data = data_i`
> then re-settles to whatever the memory returns for that advanced address — so a
> **combinational** `data_i` yields `mem[ar_addr + 8]` and every single `ld` comes back
> shifted by one 64-bit word (the classic symptom: dst IP read at meta offset 0 instead
> of 8). The bootrom/DRAM avoid this because their SRAMs register read data. We do the
> same: the testharness decode **registers** `parser_mmio_rdata` (one cycle of read
> latency) so the beat's data tracks the address presented in `IDLE` (`ar_addr`), immune
> to the same-cycle `addr_o` reassignment. Any peripheral hung off `axi2mem` must do this.

### Leaf ports (widths mirror `parser_pkg`)

- `parser_pktbuf` — added `clk_i` + a 64-bit write port: `wr_en_i`,
  `wr_addr_i[PKT_OFF_W-1:0]` (8-aligned base), `wr_be_i[7:0]`, `wr_data_i[63:0]`;
  scatters enabled lanes into `mem[]` (range-checked). Read window unchanged.
- `cva6_parser_wrap` — added a 64-bit metadata read port (`meta_rd_addr_i` →
  `meta_rd_data_o`, 8 little-endian bytes from the committed frame), the
  `parse_exit_pc_i` input, and a latched exit-status output.

## 4. Port thread (5 hops)

The bridge signals originate in the testharness and must reach the FU as real
**module ports** (the existing internal parser signals in `cva6.sv` are wires, but
these cross the core boundary):

| File | Change |
|------|--------|
| `corev_apu/tb/ariane_soc_pkg.sv` | `Parser` enum member, `ParserBase`, `ParserLength` |
| `corev_apu/tb/ariane_testharness.sv` | addr-map rule, `axi2mem` + decode, wire into `i_ariane` |
| `corev_apu/src/ariane.sv` | pass-through ports → `i_cva6` |
| `core/cva6.sv` | pass-through ports → `ex_stage_i` |
| `core/ex_stage.sv` | ports → `u_parser_pktbuf` (write) + `u_parser_fu` (ParseLen, exit-PC, meta read, status) |

`ariane_soc_pkg.sv` + the testharness/`ariane.sv` changes are `mmio.patch`; the
`cva6.sv`/`ex_stage.sv` changes ride in the same patch (applied after
`issue-ex.patch`, whose parser wiring they extend). The `parser_pktbuf` /
`cva6_parser_wrap` leaf edits live in `rtl/` and are copied into the tree by
`cva6-patched.nix`.

## 5. Parse-exit "subroutine return" (the subtle part)

The FU walks the parse graph by driving `resolved_branch_o` to steer the CVA6
frontend from one node to the next (I4a/I4b). Two facts make **termination** its
own problem:

1. On parse exit, `st_q.done` latches, and `a_ready_low_when_done` holds
   `parser_ready_o` low for any further parse op — so the **next** custom-0 word
   after an exit would stall issue **forever** (deadlock, not a clean fall-through).
2. Exit can happen at *any* node (e.g. an unknown EtherType exits at node ~2), so
   there is no fixed sequential instruction to fall through to.

Therefore, when the parse program is a **separate block** jumped into, exit must
redirect fetch to a program-provided landing PC. I5 adds `parse_exit_pc_i`: the caller
`sd`s a return address to `0x108`, jumps into the parse block, and on the exiting op
the FU asserts `resolve_branch_o` with `redirect_pc = parse_exit_pc_i` — a parser
*call/return* that resumes at caller code which reads back flow_keys.

The redirect is **gated on a programmed landing PC** (`parse_exit_pc_i != 0`; PC 0 is
the reset vector, never a valid target, so 0 == "unset"). This keeps two usage patterns
correct with one mechanism:
- **Separate block (cosim):** landing PC set → exit **redirects** back to the caller
  (must, else issue deadlocks on the block's next custom-0 word — fact 1 above).
- **Inline stream (directed `parser_insn.S`):** landing PC left at 0 → exit **falls
  through** to the next sequential instruction (which is ordinary code, not a parse op,
  so no deadlock). Without the gate the FU would redirect to PC 0 and hang the core —
  a regression caught by `cva6-parser-test` during I5.

The exit *status* latch is gated on the exit **event**, not the redirect, so
`ParserExitCode` is captured either way.

Invariants (SVA in `cva6_parser_wrap.sv`):
- `a_exit_redirects`: `(parse_exit_o & have_exit_pc) |-> resolve_branch_o` (an exit
  *with a landing PC* always steers).
- `a_jump_xor_exit`: a node-jump redirect and an exit redirect never co-assert
  (an exiting op has no next node).

Exit takes priority over the node-delta jump in the redirect mux.

## 6. Contiguity assumption (why the walk stays consistent)

The redirect target is derived as `parse_base = pc_i − cur_node×4`, recomputed each
op from the live PC and the internal node counter (`st_q.next_pc`), which advances
**only** on custom-0 parse ops. This is self-consistent **iff** the parse program is
a contiguous custom-0 block with node *i* at `parse_base + i×4` and no
non-advancing op (custom-3) inside a jump range.

Verified for the golden slice program: all 53 `pm_slice_program()` words encode to
custom-0 (`enc.hex` — 52 `…0b` + 1 `…8b`, both opcode `0x0b`); there are **no**
custom-3 moves in the program. The CAM-programming custom-3 ops the cosim runs
execute *before* entry (counter still 0, addresses below `parse_base`), so they do
not perturb the mapping.

## 7. Co-simulation flow (`cva6-parser-cosim`)

Per corpus case, the generated bare-metal program:

1. `sd` the packet bytes into `[PARSER_PKT, …)`, then `sd` the length to
   `PARSER_PARSELEN` and the return address to the exit-PC register.
2. Program the CAM: for each entry, `CPPRSWR` a `{key,target}` word into Accum then
   `CPPRSWRCAM` it at its index (targets are node indices; keys are
   `{share,match}`). 13 entries for the slice program.
3. Jump into the contiguous custom-0 parse block (from `enc.hex`); the FU walks it
   via redirects and, on exit, returns to the landing PC.
4. At the landing, `ld` the flow_keys from `[PARSER_META, …)` and the exit status
   from `PARSER_PARSELEN` (read side); `memcmp` against the model's `expected.hex`
   and compare the exit code against `params.hex`.
5. Encode per-case PASS/FAIL into `tohost`.

The program (parse block + CAM table) is shared; only packet / ParseLen / expected
change per case, so one ELF (or one template) covers the whole table. flow_keys
equivalence is the headline check; the latched exit code guards negative/boundary
cases where a partial `flow_keys` could coincide.

## 8. Known limitations / deferred

- **Single in-flight, no concurrency:** the peripheral assumes the CPU is quiescent
  w.r.t. the parser while a parse runs (it drives the parse itself). No arbitration
  between MMIO packet writes and an in-progress parse — the cosim orders them.
- **CAM write speculation-safety** remains the I4b deferred escalation (CAM writes
  apply at execute, not commit-gated). Unchanged by I5.
- **Not synthesis/Phase-8 final:** this is a testharness peripheral for
  co-simulation. A real FPGA packet-DMA path (Phase 8) may replace the bridge with a
  DMA engine, but the FU-side write/read ports are the stable seam.
- **Exit code width:** exit status exposes the 32-bit signed `ParserExitCode`; the
  full `ParserExitCode.Error` sub-field decode is left to the consumer.
