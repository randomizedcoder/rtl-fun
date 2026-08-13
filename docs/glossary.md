# Glossary

Terms used throughout the design docs.

| Term | Meaning |
|------|---------|
| **Parse graph** | Directed graph of parse nodes; edges are next-protocol transitions. Parsing = walking it per packet. |
| **Parse node** | Processing for one protocol header: determine length, extract metadata, determine next protocol. |
| **Parse walk** | The sequence of parse nodes visited for a given packet. |
| **Cursor / current header** | The header being parsed right now, described by an offset (`pcurptr`) and length (`pcurhdr`). |
| **`pcurptr`** | Parser register: pointer/offset to the first byte of the current header. |
| **`pcurhdr`** | Parser register: length of the current header. |
| **`paccum`** | Parser "accumulator" register: destination for loads, source for lookups/compares. |
| **`pnext`** | Parser register: address of the next parse node to execute. |
| **`pktbase` / `pktlen`** | Parser registers: base pointer and total length of the packet in memory. |
| **Metadata buffer** | Output area where extracted fields (the flow key) are stored. |
| **End-of-node (`.stp`)** | Instruction qualifier that triggers end-of-node processing: advance `pcurptr` by `pcurhdr` and jump to `pnext`, or exit the parser. |
| **Load-sets-length trick** | A parser load both checks bounds *and* raises `pcurhdr` to (last loaded offset + 1), implicitly setting fixed header lengths (e.g. Ethernet = 14). |
| **`lensetmin`** | Instruction that sets a variable header length from a field, with a multiplier and an enforced minimum (e.g. IPv4 IHL nibble × 4, min 20). |
| **TLV** | Type-Length-Value: self-describing optional field. Requires bounds-safe {type, length} extraction and cursor advance. |
| **Flag-field** | Optional fields whose presence is indicated by flag bits (e.g. GRE, TCP options-ish patterns). |
| **CAM** | Content-Addressable Memory: hardware lookup keyed by a value (here: EtherType, IP proto, port → next node). May be sub-tabled. |
| **Sub-table** | A numbered partition within the CAM/array (e.g. sub-table 1 = EtherTypes, 2 = IP protocols). |
| **`custom-0..3`** | RISC-V major opcodes reserved for non-standard extensions; standard extensions avoid them. Our parser instructions live here. |
| **R-type / I-type** | RISC-V instruction formats (register-register / register-immediate). Parser instrs use both. |
| **funct3 / funct7** | RISC-V sub-opcode fields used to distinguish instructions sharing a major opcode. |
| **RoCC** | Rocket Custom Coprocessor interface — a *loosely-coupled* accelerator port on Rocket Chip. Contrast with tight in-pipeline integration. |
| **CVA6** | OpenHW Group's 6-stage in-order RV64GC application core in SystemVerilog. Our chosen base core. |
| **Ibex** | lowRISC's small 2-stage RV32 core (used in OpenTitan). Documented lighter alternative. |
| **IPC** | Instructions Per Cycle. Parser instrs have lower IPC but do far more per instruction. |
| **flow_dissector** | Linux kernel routine that extracts flow keys from packets; the canonical software baseline for this work. |
| **flow_keys** | The output struct: ip_version, ip_proto, src/dst addresses, sport/dport, etc. |
| **XDP2 / PANDA** | Herbert's parser framework / programming model that this ISA descends from; source of the protocol tables and TLV/flag handling. |
| **Golden model** | The C reference implementation that *defines* ISA semantics; RTL is verified against it. |
| **Co-simulation** | Running RTL (via Verilator) and the golden model on the same inputs and comparing outputs. |
| **cocotb** | Python-based HDL verification framework; used to drive the co-sim testbench. |
| **Data header** | A sub-protocol element (e.g. a TLV) parsed within a protocol header; its offset+length live in the `DataHdr` register. |
| **Sub-parse node / sub-protocol table** | Level-2 parsing constructs: rules + type→node maps for TLVs, flag-fields, and arrays inside a header. |
| **DataBound** | Max byte extent of the data elements within a header (`DataBndLoop.DataBound`); init ∞, decremented per loop iteration; loop ends at 0. |
| **Loop register** | `DataBndLoop.Loop`: holds a loop head address (live loop) or a terminating code; **checked before `Next`** at end-of-node. |
| **Next register** | `Next` (pnext): the next parse node — an **address or a parser code**, with E/V/NE/NV control bits. |
| **Overlay node** | A next node whose transition does **not** advance the cursor (Next bit `0x20000000`). |
| **Encapsulation level** | `Counters.Encap`: incremented per encapsulation layer (Next bit `0x40000000` or `prs.inc.encap`); indexes the metadata frame. |
| **Common metadata / metadata frame** | The metadata block = whole-object "common" area + an array of per-encapsulation "frames"; stores pick one via the F-bit. |
| **Parser code** | A negative-byte status (−1..−127); `STOP_FAIL(−12)` splits normal from abnormal exits; stored in `ParserExitCode.Error`. |
| **Accum / Flags** | `Accum` = working accumulator (load/lookup/compare/length); `Flags` = flag-field loop register / 2nd accumulator. |
| **Counters** | 7 user counters + encap; `prs.inc.cntr`/`setcntrbit`/`resetcntr`; limits with actions; also array indices for metadata stores. |
| **PTLVFASTLOOP / PFLAGSLOOP** | Specialized loop-head instructions for single-byte type+length TLVs and for flag-fields (bit-position iteration). |
| **`Sz` field** | Sub-register width selector; general instrs 0=nibble/1=byte/2=half/3=word, but **load/store** 0=**8 bytes**/1/2/3. |
