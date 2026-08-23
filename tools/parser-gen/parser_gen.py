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
    return insns, doc.get("sizes", {}), doc.get("p_registers", {})


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
    if kind == "multmin":  # mult:min -> length Shift[23:21] + Len[18:11] (fixed ranges)
        return "Xpl"
    raise ValueError(f"parser_gen: unknown prose sugar kind {kind!r}")


# Cosmetic-fixed destination pseudo-registers (dest.token): a required leading operand
# that prints a keyword but consumes no encoding bits (the discriminator is in `fixed`).
# pcurhdr -> Xph (length family); paccum -> Xpp (load target, always Accum / D=0).
_DEST_TOKENS = {"pcurhdr": "Xph", "paccum": "Xpp"}


def _dest_token(name):
    try:
        return _DEST_TOKENS[name]
    except KeyError:
        raise ValueError(f"parser_gen: unknown cosmetic dest token {name!r}")


def _c0_args(insn, skip=(), prose=False):
    """binutils operand string for a custom-0 row. `skip` is the set of fields folded into
    the mnemonic (Sz via size_class, plus any `suffixes` fields) and so absent from the
    operand list. With prose=True, sugared operands (per insn.prose) become the `Xp*` tokens;
    a `valmask` field also swallows the next operand (Mask), which it encodes jointly.
    Everything else stays the stock `XtuN@S`."""
    toks = []
    swallow = False
    dest_field = insn.dest.get("field") if insn.dest else None
    if insn.dest and "token" in insn.dest:  # cosmetic-fixed leading dest (pcurhdr -> Xph)
        toks.append(_dest_token(insn.dest["token"]))
    for n in insn.operands:
        if n in skip:
            continue
        if swallow:            # the field consumed by a preceding valmask/multmin
            swallow = False
            continue
        if n == dest_field:    # leading destination pseudo-register (paccum/pnext -> D)
            toks.append("Xpc")
            continue
        kind = prose and insn.prose.get(n)
        if kind:
            toks.append(_prose_token(kind, *insn.fields[n]))
            if kind in ("valmask", "multmin"):
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
        elif tok == "Xpl":                   # mult:min -> length Shift[23:21] + Len[18:11]
            bits |= mask_for(23, 21) | mask_for(18, 11)
        elif tok in ("Xph", "Xpp"):          # cosmetic dest pcurhdr/paccum -> no bits (fixed)
            pass
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
           "/* `Xpl` = mult:min (length Shift[23:21]+Len[18:11]); `Xph`/`Xpp` = cosmetic */",
           "/* pcurhdr/paccum dest (no bits): length always targets CurHdr, a load always Accum. */",
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


def _fixed_bit_runs(full_match, operand_ranges):
    """The maximal contiguous runs of bits NOT covered by any operand, each as
    (hi, lo, value) sliced from full_match. Together with the operand bit
    assignments these tile all 32 bits disjointly — the per-field `let Inst{}`
    idiom LLVM's RISC-V formats use (no overlap, no gaps)."""
    op_bits = set()
    for hi, lo in operand_ranges:
        op_bits.update(range(lo, hi + 1))
    runs = []
    lo = 0
    while lo < 32:
        if lo in op_bits:
            lo += 1
            continue
        hi = lo
        while hi + 1 < 32 and (hi + 1) not in op_bits:
            hi += 1
        runs.append((hi, lo, (full_match >> lo) & ((1 << (hi - lo + 1)) - 1)))
        lo = hi + 1
    return runs


def _llvm_record(cname, name_sfx):
    """TableGen record name: prs.store + .b -> PRS_STORE_B."""
    return (cname + name_sfx.replace(".", "_")).upper()


def _llvm_pregisters(pregs):
    """The PRReg register class = the custom-3 Cpreg[28:24] selector, p0..p31.

    Registers are named `pNN`; the 11 ABI-style aliases (paccum, pnext, ...) come from
    isa/parser-opcodes.yaml `p_registers.*.alias` and are the canonical assembler spellings.
    They ride RISC-V's existing ABIRegAltName index, so `llvm-mc` accepts both `p15` and
    `paccum` (MatchRegisterName / MatchRegisterAltName) and `llvm-objdump` prints the alias.
    Registers p0..p31 are defined consecutively so the disassembler's `RISCV::P0 + RegNo`
    (nix/parser-llvm patch, DecodePRRegRegisterClass) is well-formed."""
    alias = {int(k[1:]): v["alias"] for k, v in pregs.items() if v.get("alias")}
    out = ["// Parser p-registers (custom-3 Cpreg[28:24]); aliases from p_registers.*.alias.",
           'let Namespace = "RISCV" in {',
           "class PReg<bits<5> enc, string n, list<string> alt> : Register<n> {",
           "  let HWEncoding{4-0} = enc;",
           "  let AltNames = alt;",
           "  let RegAltNameIndices = [ABIRegAltName];",
           "}"]
    for num in range(32):
        alt = alias.get(num, f"p{num}")   # unnamed regs alias to their own numeric name
        out.append(f'def P{num} : PReg<{num}, "p{num}", ["{alt}"]>;')
    out.append("}")
    out.append('def PRReg : RegisterClass<"RISCV", [i64], 64, (add (sequence "P%u", 0, 31))>;')
    out.append("")
    return out


def _llvm_dest_classes():
    """The L3a destination-pseudo-register operand classes (custom-0 load/cam/length).

    paccum/pnext ride the cam/load D bit; pcurhdr rides the length F2 field. The keywords
    collide with the L2 p-register alt-names, so each has a custom ParserMethod that consumes
    the keyword before the generic register fallback, and a PrintMethod that prints it back
    from the decoded field bit (LLVM decodes printed operands from real bits). The C++ for
    those methods lives in the nix/parser-llvm patch (RISCVAsmParser/RISCVInstPrinter)."""
    return [
        "// Destination pseudo-registers (L3a); C++ in the nix/parser-llvm patch.",
        "class PrsDestOpnd<string nm, string parser, string pred> : AsmOperandClass {",
        "  let Name = nm;",
        '  let RenderMethod = "addImmOperands";',
        "  let ParserMethod = parser;",
        "  let PredicateMethod = pred;",
        "}",
        'def AccumDestOpnd  : PrsDestOpnd<"AccumDest",  "parseAccumDest",  "isAccumDest">;',
        'def CamDestOpnd    : PrsDestOpnd<"CamDest",    "parseCamDest",    "isCamDest">;',
        'def CurHdrDestOpnd : PrsDestOpnd<"CurHdrDest", "parseCurHdrDest", "isCurHdrDest">;',
        "class PrsDestOp<AsmOperandClass mc, string pm> : Operand<i32> {",
        "  let ParserMatchClass = mc;",
        "  let PrintMethod = pm;",
        "}",
        'def accumdest  : PrsDestOp<AccumDestOpnd,  "printAccumDest">;',
        'def camdest    : PrsDestOp<CamDestOpnd,    "printCamDest">;',
        'def curhdrdest : PrsDestOp<CurHdrDestOpnd, "printCurHdrDest">;',
        "",
    ]


# dest operand class per dest kind: cam map -> camdest; cosmetic token -> by keyword.
_DEST_LLVM_CLASS = {"paccum": "accumdest", "pcurhdr": "curhdrdest"}


def _llvm_dest_op(insn):
    """The leading destination-pseudo-register operand (L3a), riding a real discriminator
    bit so the disassembler can reconstruct + print it. Returns (ins, var, hi, lo) or None."""
    d = insn.dest
    if not d:
        return None
    hi, lo = insn.fields[d["field"]]
    if "map" in d:                       # prs.cam: paccum=0 / pnext=1 select the D bit
        cls = "camdest"
    else:                                # cosmetic token riding its fixed field bit
        cls = _DEST_LLVM_CLASS[d["token"]]
    return (f"{cls}:$dst", "dst", hi, lo)


def _llvm_prose_classes():
    """The L3b prose-sugar operand classes (custom-0 load/store/length/cmp).

    Each prose operand rides a REAL field bit (plain immediate: encode/decode stay
    automatic) but takes a custom ParserMethod so llvm-mc accepts BOTH the prose spelling
    (pcurptr+N / pmeta+N / paccum[i] / value:mask / mult:min) and the bare Hybrid
    immediate — the parser dispatches the ParserMethod before the generic immediate path.
    value:mask and mult:min combine two fields in one token, so their ParserMethod
    MULTI-PUSHES (one call emits both operands); the matcher keys only on the final
    operand vector, so the def keeps its plain comma AsmString and both syntaxes match.
    Predicates reuse RISC-V's stock isUImmN. Printing: the single-field forms render the
    prose keyword; the combined forms print positionally (they still round-trip by word).
    The C++ (parse/print methods) lives in the nix/parser-llvm patch."""
    return [
        "// Prose-sugar operand classes (L3b); C++ in the nix/parser-llvm patch.",
        "class PrsProseOpnd<string nm, string parser, string pred> : AsmOperandClass {",
        "  let Name = nm;",
        '  let RenderMethod = "addImmOperands";',
        "  let ParserMethod = parser;",
        "  let PredicateMethod = pred;",
        "}",
        'def PCurPtrOpnd : PrsProseOpnd<"PCurPtr", "parsePCurPtr",   "isUImm9">;',
        'def PMetaOpnd   : PrsProseOpnd<"PMeta",   "parsePMeta",     "isUImm9">;',
        'def PAccum3Opnd : PrsProseOpnd<"PAccum3", "parsePAccumIdx", "isUImm3">;',
        'def PAccum4Opnd : PrsProseOpnd<"PAccum4", "parsePAccumIdx", "isUImm4">;',
        'def ValMaskOpnd : PrsProseOpnd<"ValMask", "parseValueMask", "isUImm8">;',
        'def MultMinOpnd : PrsProseOpnd<"MultMin", "parseMultMin",   "isUImm3">;',
        "class PrsProseOp<AsmOperandClass mc, string pm> : Operand<i32> {",
        "  let ParserMatchClass = mc;",
        "  let PrintMethod = pm;",
        "}",
        'def pcurptroff : PrsProseOp<PCurPtrOpnd, "printPCurPtr">;',
        'def pmetaoff   : PrsProseOp<PMetaOpnd,   "printPMeta">;',
        'def paccumidx3 : PrsProseOp<PAccum3Opnd, "printPAccumIdx">;',
        'def paccumidx4 : PrsProseOp<PAccum4Opnd, "printPAccumIdx">;',
        'def valmask    : PrsProseOp<ValMaskOpnd, "printOperand">;',
        'def multmin    : PrsProseOp<MultMinOpnd, "printOperand">;',
        "",
    ]


# prose kind -> LLVM operand class (paccum[i] widens by field: paccumidx3/paccumidx4).
_PROSE_LLVM = {"ptr": "pcurptroff", "metaptr": "pmetaoff",
               "valmask": "valmask", "multmin": "multmin"}


def _llvm_prose_class(kind, w):
    if kind == "index":
        return f"paccumidx{w}"
    return _PROSE_LLVM[kind]


def _llvm_c0_operand(insn, n):
    """One custom-0 operand (ins, var, hi, lo): a prose-sugar class when insn.prose names
    the field (L3b), else the stock uimmN. value:mask/mult:min leave the swallowed second
    field (Mask/Len) as a plain uimm — the ParserMethod multi-pushes it, so it stays a
    separate operand slot (unlike binutils, which fuses them into one token)."""
    hi, lo = insn.fields[n]
    w = hi - lo + 1
    var = n.lower()
    kind = insn.prose.get(n)
    cls = _llvm_prose_class(kind, w) if kind else f"uimm{w}"
    return (f"{cls}:${var}", var, hi, lo)


def _llvm_c3_ops(insn):
    """Translate a custom-3 `gas:` operand string into LLVM (ins ...) operands.

    Returns [(ins_operand, var, hi, lo)] in asm order — the LLVM twin of the binutils
    `d`/`s`/`Xpr`/`XtuN@S` tokens: `d`->GPR rd[11:7], `s`->GPR rs1[19:15],
    `Xpr`->PRReg preg (Cpreg[28:24]), `XtuN@S`->uimmN at [S+N-1:S] (the ld.immed split
    imm). The non-operand selector fields (S/I/R/Func3/CoP) stay in the fixed word."""
    out = []
    imm_idx = 0
    for tok in [t for t in (insn.gas_args or "").split(",") if t]:
        if tok == "d":
            hi, lo = insn.fields["Rd"]
            out.append(("GPR:$rd", "rd", hi, lo))
        elif tok == "s":
            hi, lo = insn.fields["Rs"]
            out.append(("GPR:$rs1", "rs1", hi, lo))
        elif tok == "Xpr":
            hi, lo = insn.fields["Cpreg"]
            out.append(("PRReg:$preg", "preg", hi, lo))
        elif tok.startswith("Xtu"):
            m = re.match(r"Xtu(\d+)@(\d+)$", tok)
            if not m:
                raise ValueError(f"parser_gen: bad custom-3 imm token {tok!r}")
            w, s = int(m.group(1)), int(m.group(2))
            var = f"imm{imm_idx}"
            imm_idx += 1
            out.append((f"uimm{w}:${var}", var, s + w - 1, s))
        else:
            raise ValueError(f"parser_gen: unhandled custom-3 gas token {tok!r}")
    return out


def _emit_prs_def(out, rec, asm, full_match, ops):
    """Emit one `def <rec> : PrsInst<...>` from resolved operands [(ins, var, hi, lo)].
    Fixed bits (everything an operand does not cover) come from `full_match`; each operand
    binds its bit range by name — the per-field `let Inst{}` idiom shared with emit_gas."""
    ins_dag = ("(ins " + ", ".join(o[0] for o in ops) + ")") if ops else "(ins)"
    argstr = ", ".join(f"${o[1]}" for o in ops)
    out.append(f'def {rec} : PrsInst<(outs), {ins_dag},')
    out.append(f'                    "{asm}", "{argstr}"> {{')
    for _ins, var, hi, lo in ops:
        out.append(f"  bits<{hi - lo + 1}> {var};")
    for hi, lo, val in _fixed_bit_runs(full_match, [(o[2], o[3]) for o in ops]):
        span = f"{hi}-{lo}" if hi != lo else f"{hi}"
        out.append(f"  let Inst{{{span}}} = 0x{val:x};")
    for _ins, var, hi, lo in ops:
        out.append(f"  let Inst{{{hi}-{lo}}} = {var};")
    out.append("}")
    out.append("")


def emit_llvm(insns, sizes, pregs):
    """TableGen fragment (RISCVInstrInfoXparser.td) for the LLVM MC layer, Phase 7 L3.

    The LLVM twin of emit_gas. Instructions sit in the DEFAULT RISCV decoder namespace
    with NO predicate, so `llvm-mc` assembles/disassembles them unconditionally — the
    analogue of the binutils INSN_CLASS_I rows (custom-0 0x0b / custom-3 0x7b are unused
    by the base ISA, so there is no matcher/decoder conflict and no -mattr gate).

    L1 emits the immediate-only custom-0 ops (store/storeimm/cmp*/nextnode/setcode/stp):
    every operand is a stock uimmN, so no custom C++ is needed. L2 adds the custom-3 moves
    (mv.x.p/mv.p.x/ld.immed/cam.read/array.read): their GPR + p-register operands match and
    encode entirely from TableGen (register-class membership + HWEncoding are automatic);
    only the disassembler needs one small `DecodePRRegRegisterClass` helper (nix/parser-llvm
    patch), the generated decoder's reference. L3a adds the destination pseudo-registers
    (paccum/pnext/pcurhdr on load/cam/length, riding a real discriminator bit). L3b adds the
    prose-sugar operand classes (pcurptr+N / pmeta+N / paccum[i] / value:mask / mult:min) that
    parse both the prose and the Hybrid spelling. Bits are identical to emit_gas."""
    out = ["//===-- RISCVInstrInfoXparser.td ---------------------------*- tablegen -*-===//",
           "//",
           "// GENERATED by tools/parser-gen from isa/parser-opcodes.yaml -- do not edit.",
           "// Phase 7 L3: the rtl-fun parser-unit MC extension (custom-0 / custom-3 ops).",
           "// Included from RISCVInstrInfo.td by the nix/parser-llvm patch. Ops live in the",
           "// default RISCV decoder namespace with no predicate (always assemblable), so",
           "// llvm-mc assembles + disassembles them to the exact isa/parser-opcodes.yaml bits.",
           "//",
           "//===----------------------------------------------------------------------===//",
           ""]
    out += _llvm_pregisters(pregs)
    out += ["class PrsInst<dag outs, dag ins, string opcodestr, string argstr>",
            "    : RVInst<outs, ins, opcodestr, argstr, [], InstFormatOther> {",
            "  let hasSideEffects = 1;",
            "  let mayLoad = 0;",
            "  let mayStore = 0;",
            "  let hasNoSchedulingInfo = 1;",
            "}",
            ""]
    out += _llvm_dest_classes()
    out += _llvm_prose_classes()
    for i in insns:
        if i.opcode == C3_OPCODE:
            _emit_prs_def(out, _llvm_record(i.cname, ""), i.asm, i.match, _llvm_c3_ops(i))
            continue
        skip = set()
        if i.size_class:
            skip.add("Sz")
        for grp in i.suffixes:
            skip.add(grp["field"])
        dest_op = _llvm_dest_op(i)     # None if no dest; else rides i.dest["field"]
        if dest_op:
            skip.add(i.dest["field"])  # the dest carries this field, not a plain operand
        # L3b: each prose field (insn.prose) takes a custom operand class that parses BOTH
        # the prose spelling and the bare Hybrid immediate; non-prose fields stay uimmN. The
        # encoding is unchanged — the sugar is presentation only (parse + print).
        names = [n for n in i.operands if n not in skip]
        for name_sfx, match_delta in _suffix_variants(i, sizes):
            ops = ([dest_op] if dest_op else []) + \
                  [_llvm_c0_operand(i, n) for n in names]
            _emit_prs_def(out, _llvm_record(i.cname, name_sfx),
                          f"{i.asm}{name_sfx}", i.match | match_delta, ops)
    return "\n".join(out)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: parser_gen.py <parser-opcodes.yaml> <out-dir>")
    yaml_path, out_dir = sys.argv[1], sys.argv[2]
    insns, sizes, pregs = load(yaml_path)
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
    with open(os.path.join(out_dir, "parser-llvm.td"), "w") as f:
        f.write(emit_llvm(insns, sizes, pregs))
    print(f"parser_gen: emitted {len(insns)} instructions to {out_dir}")


if __name__ == "__main__":
    main()
