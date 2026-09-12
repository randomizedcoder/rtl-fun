#!/usr/bin/env python3
# nix/cva6-fpga/strip-translate-off.py — remove `pragma translate_off` .. `translate_on`
# regions from every SystemVerilog/Verilog file under a tree, IN PLACE.
#
# Why (Phase-8 M3, docs/phase-8-status.md): synthesis front-ends (Vivado, Quartus,
# GowinSynthesis) honor `// pragma translate_off` / `translate_on` and skip the enclosed
# simulation-only text. sv2v does NOT — it treats those pragmas as ordinary comments and
# faithfully lowers whatever is between them. In CVA6 that sim-only text is exactly what
# breaks a Gowin build:
#   * vendor/.../SyncDpRam.sv wraps `define SIMULATION` in translate_off, so sv2v defines
#     it and emits the RAM's SIMULATION branch (a mixed blocking/non-blocking init) instead
#     of the clean `ifndef SIMULATION` synthesis branch — yosys then can't infer $mem and
#     demotes the array to flip-flops (0 BSRAM; the challenge-#16 mechanism).
#   * SyncSpRamBeNx64.sv's SIM_INIT loop, cva6.sv's mock instruction tracer
#     (string/$fopen/$fwrite/$fclose), cvfpu's $fatal/$finish defensive default cases, and
#     common_cells' `default disable iff` SVA all live in translate_off too, and each one
#     is rejected by sv2v, yosys, or Gowin.
# Stripping these regions gives sv2v the same synthesis-only view a real front-end sees.
#
# Line-based and deliberately simple: a line that mentions `translate_off` in a comment
# opens a drop region; the next line mentioning `translate_on` closes it (inclusive). This
# matches CVA6/pulp-platform style, where the pragmas sit on their own lines (incl. the
# `end else` / `translate_on` fall-through trick in the RAM leaves, which this handles
# correctly: dropping `... end else` + the marker leaves `always_ff begin if (CSel...`).
import os, re, sys

OFF = re.compile(r'(//|/\*).*translate_off', re.IGNORECASE)
ON  = re.compile(r'(//|/\*).*translate_on',  re.IGNORECASE)
EXTS = (".sv", ".svh", ".v", ".vh")

def strip(text):
    out, dropping, dropped = [], False, 0
    for line in text.split("\n"):
        if not dropping:
            if OFF.search(line):
                dropping = True
                dropped += 1
            else:
                out.append(line)
        else:
            dropped += 1
            if ON.search(line):
                dropping = False
    if dropping:
        # Unbalanced translate_off (no matching translate_on): synthesis would drop to
        # EOF too, but flag it so a malformed file can't silently swallow real RTL.
        sys.stderr.write("WARNING: unterminated translate_off region\n")
    return "\n".join(out), dropped

def main(root):
    files = regions = 0
    for dirpath, _, names in os.walk(root):
        for n in names:
            if not n.endswith(EXTS):
                continue
            p = os.path.join(dirpath, n)
            try:
                text = open(p, encoding="utf-8", errors="surrogateescape").read()
            except (OSError, UnicodeError):
                continue
            if "translate_o" not in text.lower():
                continue
            new, dropped = strip(text)
            if dropped:
                open(p, "w", encoding="utf-8", errors="surrogateescape").write(new)
                files += 1
                regions += dropped and 1
    sys.stderr.write(f"strip-translate-off: cleaned {files} files\n")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
