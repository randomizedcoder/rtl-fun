#!/usr/bin/env python3
"""parser_gen.py — Phase 7 §7.6 codegen spine.

Reads the single source of bits, isa/parser-opcodes.yaml, and emits the toolchain
artifacts so no downstream tool hand-copies encodings:

  toolchain/generated/parser-opc.json  — canonical machine table (humans + tools)
  toolchain/generated/parser-opc.inc   — binutils opcode table fragment (MATCH_/MASK_
                                          + operand descriptors), consumed by the
                                          Phase-7 binutils patch (Stage 1)
  toolchain/generated/parser_intrinsics.h — inline word-builders per mnemonic, the
                                          generated twin of model/libparsermodel/encoding.c

Correctness is cross-checked against the model's hand-written encoders
(verif/gen/parser_gen_check.c) and the golden constants (prs_load_h(12)==0x2010600b).

Usage:  parser_gen.py <isa/parser-opcodes.yaml> <out-dir>
"""
import sys
import json
import re

try:
    import yaml
except ImportError:
    sys.exit("parser_gen: PyYAML is required (nix provides python3.withPackages [pyyaml])")

C0_OPCODE = 0x0B
C3_OPCODE = 0x7B
FNC4_LO, FNC4_HI = 7, 10


def mask_for(hi, lo):
    return ((1 << (hi - lo + 1)) - 1) << lo


def put(val, hi, lo):
    return (val & ((1 << (hi - lo + 1)) - 1)) << lo


class Insn:
    """One assemblable instruction resolved from the yaml."""

    def __init__(self, asm, fields, fixed, operands, match, mask, opcode,
                 size_class=None, gas_args=None, prose=None, suffixes=None, dest=None):
        self.asm = asm                 # mnemonic, e.g. "prs.load"
        self.cname = asm.replace(".", "_")   # prs_load
        self.fields = fields           # {name: (hi, lo)} available field ranges
        self.fixed = fixed             # {name: value} pinned bits (in match+mask)
        self.operands = operands       # [name, ...] variable fields, asm order
        self.match = match             # fixed bits
        self.mask = mask               # opcode+fnc4+fixed-field bits
        self.opcode = opcode           # 0x0b or 0x7b
        self.size_class = size_class   # None | "loadstore" | "general" (folds Sz into a suffix)
        self.gas_args = gas_args       # custom-3 only: explicit binutils operand string
        self.prose = prose or {}       # {field: "ptr"|"index"|"valmask"} Stage-1.5 operand sugar
        # Phase-7 prose-freeze: each entry {field, bare, map} folds a FIELD into a dotted mnemonic
        # suffix in the gas rows (like size_class does Sz). The field stays in `operands` so the C
        # intrinsic keeps its parameter; only the assembler row set changes (bits identical).
        self.suffixes = suffixes or []
        # Phase-7 prose-freeze: {field, map} destination pseudo-register — the leading operand whose
        # keyword selects a discriminator field (cam D: paccum=0/pnext=1). Rendered as the `Xpc` gas
        # operand; the field is a normal `operands` entry so the intrinsic takes it as a parameter.
        self.dest = dest


def resolve_custom0(row, groups):
    group = groups[row["group"]]
    fields = {k: (v[0], v[1]) for k, v in group["fields"].items()}
    fixed = dict(row.get("fixed", {}))
    # fnc4 comes from the group, unless the row pins it (cmp_masked_byte has a list).
    fnc4 = fixed.pop("fnc4", None)
    if fnc4 is None:
        fnc4 = group["fnc4"]
    match = C0_OPCODE | put(fnc4, FNC4_HI, FNC4_LO)
    mask = mask_for(6, 0) | mask_for(FNC4_HI, FNC4_LO)
    for name, val in fixed.items():
        hi, lo = fields[name]
        match |= put(val, hi, lo)
        mask |= mask_for(hi, lo)
    return Insn(row["asm"], fields, fixed, list(row.get("operands", [])),
                match, mask, C0_OPCODE, size_class=row.get("size_class"),
                prose=row.get("prose"), suffixes=row.get("suffixes"),
                dest=row.get("dest"))


def resolve_custom3(name, spec, cop):
    fields = {k: (v[0], v[1]) for k, v in cop["fields"].items()}
    # Fixed selector bits: CoP=0, plus the instr's S/I/R/Func3 (and optional D at bit C).
    match = C3_OPCODE | put(0, 31, 29)
    mask = mask_for(6, 0) | mask_for(31, 29)
    for key in ("S", "I", "R", "Func3"):
        if key in spec:
            hi, lo = fields[key]
            match |= put(spec[key], hi, lo)
            mask |= mask_for(hi, lo)
    # Operands: Cpreg always; Rs/Rd depend on the move direction (kept simple: expose all).
    operands = ["Cpreg", "Rs", "Rd"]
    asm = spec.get("asm", name).split()[0]  # first token is the mnemonic
    return Insn(asm, fields, {k: spec[k] for k in ("S", "I", "R", "Func3") if k in spec},
                operands, match, mask, C3_OPCODE, gas_args=spec.get("gas"))


def load(yaml_path):
    with open(yaml_path) as f:
        doc = yaml.safe_load(f)
    groups = doc["groups"]
    insns = [resolve_custom0(r, groups) for r in doc["mnemonics"]["custom0"]]
    cop = doc["coprocessor"]
    for name, spec in cop["instrs"].items():
        # Only the moves with a clean single-mnemonic asm (skip the "write/delete" pairs).
        if "/" in spec.get("asm", ""):
            continue
        insns.append(resolve_custom3(name, spec, cop))
    return insns, doc.get("sizes", {})


def emit_json(insns):
    return json.dumps([{
        "asm": i.asm, "opcode": i.opcode, "match": i.match, "mask": i.mask,
        "fixed": i.fixed,
        "operands": [{"name": n, "hi": i.fields[n][0], "lo": i.fields[n][1]} for n in i.operands],
    } for i in insns], indent=2) + "\n"


def emit_inc(insns):
    """binutils-facing fragment: MATCH_/MASK_ macros + a table row per insn."""
    out = ["/* GENERATED by tools/parser-gen from isa/parser-opcodes.yaml — do not edit. */",
           "/* Phase 7 §7.6: the binutils opcode spine (custom-0 + custom-3 parser ops). */",
           ""]
    for i in insns:
        u = i.cname.upper()
        out.append(f"#define MATCH_{u} 0x{i.match:08x}")
        out.append(f"#define MASK_{u} 0x{i.mask:08x}")
    out.append("")
    out.append("/* PARSER_OPS(X): X(mnemonic, cname, match, mask, operand-count) */")
    out.append("#define PARSER_OPS(X) \\")
    for i in insns:
        u = i.cname.upper()
        out.append(f"  X(\"{i.asm}\", {i.cname}, MATCH_{u}, MASK_{u}, {len(i.operands)}) \\")
    out.append("  /* end */")
    out.append("")
    return "\n".join(out)


def emit_intrinsics(insns):
    """Generated inline word-builders (the twin of encoding.c) + a raw emit macro."""
    out = ["/* GENERATED by tools/parser-gen from isa/parser-opcodes.yaml — do not edit. */",
           "/*",
           " * parser_intrinsics.h — inline builders for the parser ops, generated from the",
           " * single-source encoding table. Each returns the exact 32-bit word; PRS_EMIT",
           " * plants it into the instruction stream (custom-0 is not a standard RISC-V",
           " * format, so a raw .insn 4 word is used until binutils mnemonics land, Phase 7 L2).",
           " */",
           "#ifndef PARSER_INTRINSICS_H",
           "#define PARSER_INTRINSICS_H",
           "#include <stdint.h>",
           ""]
    for i in insns:
        args = ", ".join(f"unsigned {n.lower()}" for n in i.operands)
        terms = [f"0x{i.match:08x}u"]
        for n in i.operands:
            hi, lo = i.fields[n]
            width = hi - lo + 1
            terms.append(f"(({n.lower()} & 0x{(1 << width) - 1:x}u) << {lo})")
        body = " | ".join(terms)
        out.append(f"static inline uint32_t {i.cname}({args or 'void'})")
        out.append(f"{{ return {body}; }}")
    out.append("")
    out.append("/* Widen to 64-bit UNSIGNED before the \"i\" operand: a uint32_t immediate is")
    out.append(" * SImode, which gas prints as a SIGNED value, so any word with bit 31 set")
    out.append(" * (e.g. prs.cam pnext .stp, 0xe001140b) becomes negative and `.insn 4, <neg>` fails with")
    out.append(" * \"value conflicts with instruction length\". The 64-bit unsigned form prints")
    out.append(" * the full positive word, which gas accepts. */")
    out.append("#define PRS_EMIT(word) \\")
    out.append("    __asm__ __volatile__(\".insn 4, %0\" :: \"i\"((unsigned long long)(uint32_t)(word)))")
    out.append("")
    out.append("#endif /* PARSER_INTRINSICS_H */")
    out.append("")
    return "\n".join(out)


GAS_ROW = '{{"{name}", 0, INSN_CLASS_I, "{args}", 0x{match:08x}, 0x{mask:08x}, match_opcode, 0}},'


def _imm_operand(hi, lo):
    """binutils' stock N-bit-unsigned-at-shift bitfield operand (all parser fields are unsigned)."""
    return f"Xtu{hi - lo + 1}@{lo}"


def _prose_token(kind, hi, lo):
    """Stage-1.5 sugar operand token (parsed by the parser-binutils `Xp*` patch)."""
    w = hi - lo + 1
    if kind == "ptr":      # pcurptr+N -> w-bit displacement at lo (load Offset)
        return f"Xpo{w}@{lo}"
    if kind == "index":    # paccum[i] -> w-bit sub-register index at lo (Pos)
        return f"Xpa{w}@{lo}"
    if kind == "valmask":  # value:mask -> cmp Value[26:19] + Mask[18:11] (fixed ranges)
        return "Xpm"
    if kind == "metaptr":  # pmeta+N -> w-bit displacement at lo (store/storeimm Offset)
        return f"Xpe{w}@{lo}"
    raise ValueError(f"parser_gen: unknown prose sugar kind {kind!r}")


def _c0_args(insn, skip=(), prose=False):
    """binutils operand string for a custom-0 row. `skip` is the set of fields folded into
    the mnemonic (Sz via size_class, plus any `suffixes` fields) and so absent from the
    operand list. With prose=True, sugared operands (per insn.prose) become the `Xp*` tokens;
    a `valmask` field also swallows the next operand (Mask), which it encodes jointly.
    Everything else stays the stock `XtuN@S`."""
    toks = []
    swallow = False
    dest_field = insn.dest["field"] if insn.dest else None
    for n in insn.operands:
        if n in skip:
            continue
        if swallow:            # the Mask consumed by a preceding valmask
            swallow = False
            continue
        if n == dest_field:    # leading destination pseudo-register (paccum/pnext -> D)
            toks.append("Xpc")
            continue
        kind = prose and insn.prose.get(n)
        if kind:
            toks.append(_prose_token(kind, *insn.fields[n]))
            if kind == "valmask":
                swallow = True
        else:
            toks.append(_imm_operand(*insn.fields[n]))
    return ",".join(toks)


# The binutils opcode `mask` must fix EVERY bit that is not consumed by an operand
# (validate_riscv_insn rejects any bit that is neither fixed nor an operand). So the
# gas mask is ~(union of operand bits) — which equals the encoder mask for the custom-0
# rows (all fields are fixed-or-operand) and additionally pins the forced-zero GPR/CAM
# fields on the custom-3 moves. Operand bit spans are read straight off the args string.
def _args_bits(args):
    bits = 0
    for tok in filter(None, args.split(",")):
        if tok == "d":                       # rd  [11:7]
            bits |= mask_for(11, 7)
        elif tok == "s":                     # rs1 [19:15]
            bits |= mask_for(19, 15)
        elif tok.startswith("Xpr"):          # parser p-register, Cpreg [28:24]
            bits |= mask_for(28, 24)
        elif tok == "Xpm":                   # value:mask -> Value[26:19] + Mask[18:11]
            bits |= mask_for(26, 19) | mask_for(18, 11)
        elif tok == "Xpc":                   # cam dest paccum/pnext -> D[30]
            bits |= mask_for(30, 30)
        elif tok.startswith(("Xpo", "Xpa", "Xpe")):  # pcurptr+N / paccum[i] / pmeta+N -> N-bit at S
            n, s = (int(x) for x in re.match(r"Xp[oae](\d+)@(\d+)", tok).groups())
            bits |= mask_for(s + n - 1, s)
        elif tok.startswith(("Xtu", "Xts")):  # stock N-bit bitfield at S
            n, s = (int(x) for x in re.match(r"Xt[us](\d+)@(\d+)", tok).groups())
            bits |= mask_for(s + n - 1, s)
        else:
            raise ValueError(f"parser_gen: unknown gas operand token {tok!r}")
    return bits


def _gas_mask(args):
    return 0xFFFFFFFF & ~_args_bits(args)


def _suffix_variants(insn, sizes):
    """The cartesian product of an insn's dotted-suffix groups → list of
    (name_suffix, match_delta). The size suffix (size_class → Sz) is the first group;
    each `suffixes` entry adds another. Every combination is one gas mnemonic row set.
    Returns [("", 0)] for an op with no suffixes (a single base row)."""
    groups = []  # each: list of (suffix_str, match_delta)
    if insn.size_class:
        hi, lo = insn.fields["Sz"]
        groups.append([(f".{sfx}", put(v, hi, lo)) for sfx, v in sizes[insn.size_class].items()])
    for grp in insn.suffixes:
        hi, lo = insn.fields[grp["field"]]
        variants = []
        bare = grp.get("bare")
        if bare is not None:                       # a no-suffix row with the default value
            variants.append(("", put(bare, hi, lo)))
        for sfx, v in grp["map"].items():          # one named row per mapped value
            variants.append((f".{sfx}", put(v, hi, lo)))
        groups.append(variants)
    combos = [("", 0)]
    for grp in groups:
        combos = [(n + sn, m | sm) for (n, m) in combos for (sn, sm) in grp]
    return combos


def emit_gas(insns, sizes):
    """binutils riscv_opcodes[] rows, ready to paste into opcodes/riscv-opc.c (Phase 7 L2).

    Immediates use binutils' generic `XtuN@S` bitfield operand; the parser p-register `Xpr`
    (Cpreg[28:24]) is the one operand class the patch adds by hand. Size-bearing custom-0 ops
    fold Sz[29:28] into a dotted suffix, one row per size; the prose-freeze `suffixes` fold
    further attribute/discriminator fields (E→.be, S→.stp, cmp Er→.stop/.stopnode/.stopsub/.fail)
    the same way, cross-producted with the size suffix. INSN_CLASS_I keeps the ops always
    enabled (no -march gate), matching how the extension is decoded in-core.
    """
    out = ["/* GENERATED by tools/parser-gen from isa/parser-opcodes.yaml — do not edit. */",
           "/* Phase 7 §7.3: binutils riscv_opcodes[] rows for the parser ops (custom-0 + custom-3). */",
           "/* Paste inside riscv_opcodes[] (opcodes/riscv-opc.c). `Xpr` = parser p-register; */",
           "/* `XtuN@S` = binutils stock N-bit-unsigned-at-S immediate; `d`/`s` = rd/rs1 GPRs.  */",
           "/* Stage 1.5 prose sugar (parser-binutils patch): `XpoN@S` = pcurptr+N; `XpaN@S` = */",
           "/* paccum[i]; `Xpm` = value:mask; `XpeN@S` = pmeta+N (store metadata frame). Each */",
           "/* sugared op has a prose row (printed by objdump) */",
           "/* before its Hybrid row (same match/mask); the Hybrid form still assembles.  */",
           "/* Prose-freeze suffixes (.be/.stp/.stop/.stopnode/.stopsub/.fail) fold a field into */",
           "/* the mnemonic; each (size × suffix) combination is its own {prose,Hybrid} row pair. */",
           "/* `Xpc` = cam destination pseudo-register (paccum⇒D=0 / pnext⇒D=1), the leading operand */",
           "/* that selects the CAM D bit — the single prs.cam mnemonic (no prs.camnext). */",
           ""]
    def rows(name, match, hybrid, prose):
        """The prose row (if any) then the Hybrid row for ONE mnemonic name. Prose
        first so objdump prints the readable form; the two share match/mask. They MUST
        be adjacent: gas's opcode hash rejects non-consecutive rows with the same name."""
        if prose is not None:
            out.append(GAS_ROW.format(name=name, args=prose, match=match, mask=_gas_mask(prose)))
        out.append(GAS_ROW.format(name=name, args=hybrid, match=match, mask=_gas_mask(hybrid)))

    for i in insns:
        if i.opcode == C3_OPCODE:
            args = i.gas_args or ""
            out.append(GAS_ROW.format(name=i.asm, args=args,
                                      match=i.match, mask=_gas_mask(args)))
            continue
        skip = set()
        if i.size_class:
            skip.add("Sz")
        for grp in i.suffixes:
            skip.add(grp["field"])
        hybrid = _c0_args(i, skip=skip)
        prose = _c0_args(i, skip=skip, prose=True) if i.prose else None
        for name_sfx, match_delta in _suffix_variants(i, sizes):
            rows(f"{i.asm}{name_sfx}", i.match | match_delta, hybrid, prose)
    out.append("")
    return "\n".join(out)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: parser_gen.py <parser-opcodes.yaml> <out-dir>")
    yaml_path, out_dir = sys.argv[1], sys.argv[2]
    insns, sizes = load(yaml_path)
    import os
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "parser-opc.json"), "w") as f:
        f.write(emit_json(insns))
    with open(os.path.join(out_dir, "parser-opc.inc"), "w") as f:
        f.write(emit_inc(insns))
    with open(os.path.join(out_dir, "parser-opc-gas.inc"), "w") as f:
        f.write(emit_gas(insns, sizes))
    with open(os.path.join(out_dir, "parser_intrinsics.h"), "w") as f:
        f.write(emit_intrinsics(insns))
    print(f"parser_gen: emitted {len(insns)} instructions to {out_dir}")


if __name__ == "__main__":
    main()
