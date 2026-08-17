# tools/

Reusable developer utilities for rtl-fun. Unlike throwaway scratch scripts,
tools live here so they can be re-run later and help retrace a problem if a
regression shows up down the track. Each tool gets its own subdirectory.

## pm-trace/ — golden-model single-step tracer

Runs the Phase-2 reference parser (`model/libparsermodel`) over one frame and
prints the machine state **before every instruction** — cursors, DataBound,
Loop/Next registers, and the accumulator — then the final `flow_keys` and exit
code. It is the fastest way to see *where* a parse diverges when a unit or corpus
test regresses.

It drives the model through an optional, zero-cost trace hook (`ps.trace`) added
to `pstate`; the hook is NULL in normal runs, so the model pays nothing for it.

```sh
# canned Ethernet + IPv4 + TCP frame
nix run .#pm-trace

# first packet of a classic pcap (e.g. the pinned xdp2 corpus)
nix run .#pm-trace -- path/to/some.pcap
```

Or build it directly (from the repo root, for pm-trace):

```sh
gcc -std=c11 -O2 -I model/libparsermodel \
    tools/pm-trace/pm-trace.c \
    model/libparsermodel/parser.c \
    model/libparsermodel/program.c \
    model/libparsermodel/pcap.c -o pm-trace
./pm-trace
```

Example (the eth→ipv4 transition advancing `CurHdr.Offset` 0→14→34):

```
  pc= 2 CAMNEXT   ... cur[off=0 len=14] ...
  pc= 3 LOAD      ... cur[off=14 len=0] ...   <- transitioned into ipv4_node
  ...
exit code = -4   cur.off=34
```

Exit status is 0 when the parse ends in `P_STOP_OKAY`, else 1.

## bitgen/ — patent bit-diagram generator

Regenerates the RFC-style ASCII bit-field diagrams in
[`docs/analysis/patent-encodings-recovered.md`](../docs/analysis/patent-encodings-recovered.md)
from the verified field tables encoded in the script — so the diagrams can never
drift by hand-editing. It prints to stdout; paste the output into the doc.

```sh
python3 tools/bitgen/bitgen.py     # from the repo root (python3 from `nix develop`)
```
