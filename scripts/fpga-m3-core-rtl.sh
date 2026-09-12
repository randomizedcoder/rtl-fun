# scripts/fpga-m3-core-rtl.sh — prepare the STOCK-CVA6 synth input for Gowin (M3a).
#
#   nix run .#fpga-m3-core-rtl            strategy s0 (default)
#   nix run .#fpga-m3-core-rtl -- s0      sv2v only, module hierarchy PRESERVED
#   nix run .#fpga-m3-core-rtl -- s1      sv2v + HIERARCHICAL yosys, Gowin infers BSRAM (FAILED #16)
#   nix run .#fpga-m3-core-rtl -- s2      s1 + yosys HARD-MAPS RAM to gw5a SPX9 BSRAM (the #16 fix)
#   nix run .#fpga-m3-core-rtl -- diag    BSRAM-inference reproducer (challenge #16); no CVA6
#
# Why this exists, and why it is NOT nix/fpga-m{1,2}-rtl's recipe. M1/M2 do
# `sv2v -> yosys flatten`: flatten dissolves every module boundary into one blob,
# which is fine for the ~5K-LUT parser but is EXACTLY what defeats BSRAM inference at
# CVA6 scale — the prior full-flatten attempt inferred 0 BSRAM and put ~543 Kbit of
# cache/tag memory into flip-flops (558,387 DFF, RP0001 resource overflow; see
# docs/fpga-platform-assessment.md §5a, docs/phase-8-status.md #16). So M3a keeps
# hierarchy so GowinSynthesis can recognise CVA6's inferrable RAM leaves
# (vendor/pulp-platform/fpga-support/rtl/SyncSpRamBeNx64.sv — a textbook sync
# single-port byte-enable RAM with registered read) and map them to the device's 340
# BSRAM blocks.
#
# The strategy ladder (docs/phase-8-fpga.md M3a), cheapest experiment first:
#   s0 — sv2v ONLY. sv2v lowers SystemVerilog (packages, packed structs, interfaces,
#        parameterised generate) to Verilog-2001 while KEEPING module boundaries, so
#        the RAM leaves survive as their own modules. This is the key untested probe:
#        does stock CVA6 even hit SP00018 (that was parser-specific, #13), and does
#        Gowin infer BSRAM from the plain hierarchy?
#   s1 — s0 then a HIERARCHICAL yosys pass: run the memory passes so arrays become
#        $mem/BRAM cells, but DO NOT `flatten`, keeping the RAM modules intact, and
#        delegate BRAM inference to GowinSynthesis. VERDICT (2026-09-09): FAILED — Gowin
#        inferred 0 BSRAM, 558,788 DFF, RP0001. `write_verilog -noattr` lowers the
#        byte-write-enable into 64 per-bit write conditionals Gowin can't match to its
#        BSRAM template (challenge #16). Kept as-is so `-- s1` reproduces that failure.
#   s2 — THE FIX (2026-09-10). Same hierarchical elaboration as s1, but instead of leaving
#        BRAM to Gowin inference, yosys 0.68's gw5a Gowin BRAM backend HARD-MAPS the cache
#        RAM to native SPX9 primitives. The mapping is synth_gowin's gw5a "coarse" pass with
#        `alumacc` removed (it fuses arithmetic into $alu/$macc_v2, which write_verilog can't
#        render -> GowinSynthesis EX3937) and `flatten` skipped, followed by map_ram
#        (memory_libmap+techmap -D gw5a). BRAM no longer rides on GowinSynthesis inference;
#        arithmetic stays high-level (+/-/*) for GowinSynthesis's own DSP inference. NO CVA6
#        patch needed (axis A beat axis B, the FPGA_TARGET_GOWIN coding-style patch never shipped).
#        Validated at scale: 4 SPX9 mapped, 0 $alu/$macc, 0 residual $mem, 0 per-bit writes,
#        0 IBUF/OBUF (we never reach map_gates, whose iopadmap would wrap ~155k INTERNAL module
#        ports in I/O buffers under -noflatten). See docs/gowin-bsram-inference-debug.md.
#
# The output is a BUILD ARTIFACT (gitignored), regenerated from the PINNED CVA6 source
# ($CVA6_SRC, injected by the Nix wrapper from nix/cva6.nix) by the pinned sv2v/yosys,
# so it is reproducible without churning the tree. The microVM 9p-mounts the repo, so
# the guest reads it at /work/build/fpga-m3-core-rtl/cva6_core.v (baked into m3-core.tcl).
#
# Injected by the Nix wrapper: CVA6_SRC (pinned source), REPO_ROOT (common.sh).
set -euo pipefail

STRAT="${1:-s0}"
case "$STRAT" in s0|s1|s2|diag) ;; *) echo "ERROR: unknown strategy '$STRAT' (want s0|s1|s2|diag)" >&2; exit 2 ;; esac

# ---- diag: minimal BSRAM-inference reproducer (challenge #16), no CVA6 needed ----------
# Root-causes and PROVES the fix for #16 in ~1 s instead of a ~24 h full-CVA6 synth. The
# active CVA6 L1 RAM leaf (tc_sram_wrapper: registered read, per-byte write-enable) is
# pushed, as a standalone 256x64 single-port bank, through the SAME two paths the M3a flow
# can take, and their emitted netlists are compared:
#
#   (a) current flow — proc; memory_*; write_verilog -noattr. This is exactly what s1
#       emits (lines below). write_verilog lowers the byte-write-enable into 64 INDEPENDENT
#       single-bit write conditionals (mem[addr][n:n] <= ...). GowinSynthesis reads that as
#       an arbitrary per-bit write MASK, can't match its BSRAM template (word/byte only),
#       and demotes the whole array to flip-flops -> 0 BSRAM -> RP0001 on full CVA6.
#   (b) fix (axis A) — yosys 0.68's gw5a Gowin BRAM backend via `synth_gowin -family gw5a
#       -run :map_ffs` (coarse opt + RAM mapping, STOP before FF/LUT gate mapping so the
#       surrounding logic stays generic for GowinSynthesis). Emits hard SPX9 primitives —
#       the native gw5a single-port byte-write BSRAM cell — so BRAM no longer rides on Gowin
#       inference at all. A 256x64 bank -> 2 SPX9. NB a bare `memory_libmap -lib brams.txt`
#       does NOT map here (the req_i-gated read FF stays async, RD_CLK_ENABLE=0, and the SP
#       candidate is pruned at geometry); the synth_gowin coarse pre-pass is required.
#
# The axis-A netlist (SPX9) is left at build/fpga-m3-core-rtl/diag/axisA_spx9.v for the
# Gowin-side confirmation: `nix run .#fpga-build -- m3-ramtest`. Full write-up:
# docs/gowin-bsram-inference-debug.md.
if [ "$STRAT" = "diag" ]; then
  : "${REPO_ROOT:?REPO_ROOT not set — the Nix wrapper injects it via common.sh}"
  REPRO="$REPO_ROOT/fpga/tang-mega-138k-pro/src/m3_ramtest.v"
  DIAG_OUT="${FPGA_M3_CORE_RTL_OUT:-$REPO_ROOT/build/fpga-m3-core-rtl}/diag"
  mkdir -p "$DIAG_OUT"
  # One D$ data bank: 256 words x 64 bit, 1RW, byte-we, registered read.
  CHP=(-chparam NumPorts 1 -chparam NumWords 256 -chparam DataWidth 64 -chparam ByteWidth 8 -chparam Latency 1)
  CUR="$DIAG_OUT/current_perbit.v"
  SPX="$DIAG_OUT/axisA_spx9.v"

  echo "=== M3a diag: BSRAM-inference reproducer (tc_sram_wrapper 256x64) ==="
  echo "reproducer: $REPRO"

  echo "--- (a) current flow: proc; memory_*; write_verilog -noattr -> $CUR ---"
  yosys -ql "$DIAG_OUT/current.log" -p "
    read_verilog -sv $REPRO;
    hierarchy -top tc_sram_wrapper ${CHP[*]};
    proc; opt_clean; memory_dff; memory_share; memory_collect; opt_clean;
    stat;
    write_verilog -noattr $CUR
  "
  echo "--- (b) fix axis A: synth_gowin -family gw5a -run :map_ffs -> $SPX ---"
  yosys -ql "$DIAG_OUT/axisA.log" -p "
    read_verilog -sv $REPRO;
    hierarchy -top tc_sram_wrapper ${CHP[*]};
    synth_gowin -family gw5a -run :map_ffs;
    stat;
    write_verilog -noattr $SPX
  "

  # The smoking gun (a) and the proof (b), counted from the emitted netlists.
  PERBIT=$(grep -cE 'mem\[.*\]\[[0-9]+:[0-9]+\] <=' "$CUR" || true)
  SPX9=$(grep -cE '\bSPX9\b' "$SPX" || true)
  {
    echo "reproducer=$REPRO geometry=256x64 1RW byte-we registered-read"
    echo "current_flow_per_bit_write_conditionals=$PERBIT   (expect 64: the demotion form)"
    echo "axisA_SPX9_primitives=$SPX9                        (expect 2: hard gw5a BSRAM)"
  } | tee "$DIAG_OUT/summary.txt"

  if [ "$PERBIT" -gt 0 ] && [ "$SPX9" -gt 0 ]; then
    echo "DIAG RESULT: PASS — current flow demotes (per-bit writes); axis A yields SPX9 BSRAM."
    echo "  confirm Gowin ACCEPTS the SPX9 netlist as block RAM:"
    echo "    nix run .#fpga-build -- m3-ramtest   (synth $SPX -> BSRAM count in the report)"
    exit 0
  fi
  echo "DIAG RESULT: FAIL — unexpected counts (per-bit=$PERBIT spx9=$SPX9); see $DIAG_OUT/*.log" >&2
  exit 1
fi

: "${CVA6_SRC:?CVA6_SRC not set — the Nix wrapper injects the pinned source}"
TARGET_CFG="${TARGET_CFG:-cv64a6_imafdc_sv39}"
TOP="${CVA6_TOP:-cva6}"
OUT_DIR="${FPGA_M3_CORE_RTL_OUT:-$REPO_ROOT/build/fpga-m3-core-rtl}"
FLIST_OUT="$OUT_DIR/files.txt"
INCDIR_OUT="$OUT_DIR/incdirs.txt"
SV2V_OUT="$OUT_DIR/cva6_core_sv2v.v"
FINAL="$OUT_DIR/cva6_core.v"
mkdir -p "$OUT_DIR"

echo "=== M3a core RTL prep: strategy=$STRAT cfg=$TARGET_CFG top=$TOP ==="
echo "cva6 source: $CVA6_SRC"

# ---- 1. resolve the core-only Flist (${CVA6_REPO_DIR}/${TARGET_CFG}/${HPDCACHE_DIR}) ----
# Mirrors the intent of the old build/fpga-eval/resolve_flist.py, but reads every path
# from env so it is reproducible against the pinned source (no hard-coded /nix/store).
CVA6_REPO_DIR="$CVA6_SRC" \
TARGET_CFG="$TARGET_CFG" \
HPDCACHE_DIR="$CVA6_SRC/core/cache_subsystem/hpdcache" \
FLIST_OUT="$FLIST_OUT" INCDIR_OUT="$INCDIR_OUT" \
python3 - <<'PY'
import os, sys
env = {
    "CVA6_REPO_DIR": os.environ["CVA6_REPO_DIR"],
    "TARGET_CFG":    os.environ["TARGET_CFG"],
    "HPDCACHE_DIR":  os.environ["HPDCACHE_DIR"],
}
def sub(line):
    for k, v in env.items():
        line = line.replace("${" + k + "}", v)
    return line
files, incdirs = [], []
def parse(path):
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("//"):
                continue
            line = sub(line)
            if line.startswith("+incdir+"):
                incdirs.append(line[len("+incdir+"):])
            elif line.startswith("-F ") or line.startswith("-f "):
                parse(line[3:].strip())
            else:
                files.append(line)
parse(env["CVA6_REPO_DIR"] + "/core/Flist.cva6")
def dedupe(xs):
    seen, out = set(), []
    for x in xs:
        if x not in seen:
            seen.add(x); out.append(x)
    return out
files, incdirs = dedupe(files), dedupe(incdirs)

# Drop modules that core/Flist.cva6 always compiles but that THIS config never
# instantiates, so we don't hand sv2v dead RTL it chokes on. For
# cv64a6_imafdc_sv39: EnableAccelerator = RVV = CVA6ConfigVExtEn = 0 (see
# core/include/build_config_pkg.sv:21), so cva6.sv's `gen_accelerator` generate
# branch is statically false and `acc_dispatcher` is never elaborated — yet the
# file is in the flist and the pinned sv2v (0.0.13.1) crashes converting it
# (Convert/Scoper.hs on acc_req_o.insn). Excluding dead logic is safe and keeps
# the build reproducible from the pinned source.
EXCLUDE_BASENAMES = {"acc_dispatcher.sv"}
files = [f for f in files if os.path.basename(f) not in EXCLUDE_BASENAMES]

missing = [x for x in files if not os.path.isfile(x)]
sys.stderr.write("FILES=%d INCDIRS=%d MISSING=%d\n" % (len(files), len(incdirs), len(missing)))
for m in missing:
    sys.stderr.write("MISSING: %s\n" % m)
if missing:
    sys.exit("flist references missing files — pinned source / TARGET_CFG mismatch")
open(os.environ["FLIST_OUT"], "w").write("\n".join(files) + "\n")
open(os.environ["INCDIR_OUT"], "w").write("\n".join(incdirs) + "\n")
PY

# ---- 2. sv2v: SystemVerilog -> Verilog, module hierarchy preserved ----
# The CVA6 source here is already the translate-off-stripped tree (nix/cva6-fpga.nix),
# so the sim-only text sv2v would otherwise choke on or mis-lower (the mock tracer, the
# RAM SIM_INIT loops, `define SIMULATION, $fatal/$finish, `default disable iff` SVA) is
# gone. The defines that remain shape the surviving synthesis RTL:
#   -DSYNTHESIS          drops any `ifdef SYNTHESIS sim scaffolding still in-band.
#   -DVERILATOR          matches the prior working recipe (`sv2v -DVERILATOR ...`); with
#                        translate_off already stripped it only excludes any residual
#                        `ifndef VERILATOR` SVA, and touches no synthesizable RTL.
#   -DFPGA_TARGET_XILINX selects the generic inferrable RAM coding style in the SRAM leaf.
#                        s2 (the fix) uses this SAME generic leaf — the winning axis A
#                        hard-maps it in yosys, so there is no FPGA_TARGET_GOWIN patch.
SV2V_DEFINES=(--define=SYNTHESIS --define=VERILATOR --define=FPGA_TARGET_XILINX)

# assemble +incdir and file args
SV2V_ARGS=()
while IFS= read -r d; do [ -n "$d" ] && SV2V_ARGS+=("-I$d"); done < "$INCDIR_OUT"
while IFS= read -r f; do [ -n "$f" ] && SV2V_ARGS+=("$f"); done < "$FLIST_OUT"

echo "=== sv2v ($(wc -l < "$FLIST_OUT") files) -> $SV2V_OUT ==="
sv2v "${SV2V_DEFINES[@]}" --top="$TOP" --write="$SV2V_OUT" "${SV2V_ARGS[@]}"

# ---- 2b. fold the 4 config-struct fields sv2v leaves as dotted `CVA6Cfg.<field>` ----
# sv2v (0.0.13.1) lowers ~every CVA6Cfg field access to a bit-slice `CVA6Cfg[off-:32]`,
# but leaves 4 fields (used in cva6_tlb/cva6_shared_tlb/cva6_mmu function/for-loop
# contexts) as literal DOTTED refs. Downstream that dotted form is fatal: yosys reads
# `CVA6Cfg.PtLevels` as a hierarchical ref to an undeclared net -> AST_AUTOWIRE ("can't
# detect sign and width"); GowinSynthesis -> EX3828 (the same gap). All 4 are elaboration
# CONSTANTS for the pinned config (core/include/build_config_pkg.sv), so we substitute the
# literal here (applies to every strategy, incl. s0's direct-to-Gowin path). Guarded to
# TARGET_CFG because the values are config-specific.
echo "=== fold dotted CVA6Cfg.<field> (guard: $TARGET_CFG) -> $SV2V_OUT ==="
SV2V_OUT="$SV2V_OUT" TARGET_CFG="$TARGET_CFG" python3 - <<'PY'
import os, re, sys
# From core/include/build_config_pkg.sv for XLEN=64, RVH=0:
#   PtLevels=(XLEN==64)?3:2  VpnLen=(XLEN==64)?(RVH?29:27):20
#   ASID_WIDTH=(XLEN==64)?16:1  VMID_WIDTH=(XLEN==64)?14:1
VALUES = {
    "cv64a6_imafdc_sv39": {"PtLevels": "3", "VpnLen": "27", "ASID_WIDTH": "16", "VMID_WIDTH": "14"},
}
cfg = os.environ["TARGET_CFG"]
if cfg not in VALUES:
    sys.exit("fold CVA6Cfg fields: no pinned values for TARGET_CFG=%r — add them from "
             "build_config_pkg.sv (PtLevels/VpnLen/ASID_WIDTH/VMID_WIDTH)" % cfg)
path = os.environ["SV2V_OUT"]
text = open(path, encoding="utf-8", errors="surrogateescape").read()
total = 0
for field, val in VALUES[cfg].items():
    text, n = re.subn(r"\bCVA6Cfg\." + field + r"(?![A-Za-z0-9_])", "(" + val + ")", text)
    sys.stderr.write("  CVA6Cfg.%s -> %s: %d\n" % (field, val, n))
    total += n
if total == 0:
    sys.exit("fold CVA6Cfg fields: 0 substitutions — sv2v output shape changed, revisit")
open(path, "w", encoding="utf-8", errors="surrogateescape").write(text)
sys.stderr.write("fold CVA6Cfg fields: %d substitutions\n" % total)
PY

if [ "$STRAT" = "s0" ]; then
  cp "$SV2V_OUT" "$FINAL"
else
  # ---- 3 (s1/s2). HIERARCHICAL yosys in TWO stages, NO flatten ----
  # Keeping hierarchy (no `flatten`, contrast M1/M2) preserves the RAM leaves and stays
  # SP00018-clean (challenge #13 is parser-specific). Stage 1 is shared; stage 2 differs:
  # s1 leaves BRAM to Gowin inference (FAILED, kept for the record); s2 hard-maps it to
  # gw5a SPX9 in yosys (the #16 fix).
  #
  # Stage 1 — elaborate with `-defer`. This is ESSENTIAL, not an optimization: sv2v emits
  # CVA6's config-struct field accesses as enormous UN-folded part-select expressions
  # (e.g. issue_read_operands' forwarding logic: 18 MB single lines). Plain `read_verilog`
  # eagerly generates RTLIL for those abstract modules and effectively HANGS (observed 7h+).
  # `-defer` stores each module's AST and lets `hierarchy` derive it with CONCRETE params,
  # folding the offsets to constants. The stored abstract ASTs dominate RAM (~60 GB peak on
  # full CVA6), so checkpoint the small derived design to RTLIL and lower it in a fresh,
  # low-memory process (stage 2). (docs/phase-8-status.md M3a.)
  CKPT="$OUT_DIR/elab.il"
  echo "=== yosys stage 1: elaborate (-defer) -> $CKPT ==="
  yosys -q -p "
    read_verilog -sv -defer $SV2V_OUT;
    hierarchy -top $TOP;
    write_rtlil $CKPT
  "
  if [ "$STRAT" = "s1" ]; then
    # Stage 2 (s1, the documented FAIL) — lower + collect memories, leave BRAM to Gowin.
    # `write_verilog -noattr` lowers the byte-write-enable into 64 per-bit write conditionals
    # that GowinSynthesis demotes to flops -> 0 BSRAM, RP0001 (challenge #16). Kept so
    # `-- s1` reproduces the failure. Write BEFORE any stat: `stat -top` crashes yosys 0.67
    # (std::out_of_range / map::at) on this design; the plain write_verilog path is unaffected.
    echo "=== yosys stage 2 (s1): lower + memory passes, Gowin inference (no flatten) -> $FINAL ==="
    yosys -q -p "
      read_rtlil $CKPT;
      proc; opt_clean;
      memory_dff; memory_share; memory_collect;
      opt_clean;
      write_verilog -noattr $FINAL
    "
  else
    # Stage 2 (s2, THE FIX) — hand-rolled synth_gowin "coarse" MINUS alumacc, then map_ram,
    # so yosys hard-maps the cache RAM to gw5a SPX9 BSRAM while leaving the surrounding logic
    # as HIGH-LEVEL cells that write_verilog can render and GowinSynthesis can re-synthesize.
    #
    # Why not `synth_gowin -run :map_gates` (the earlier attempt)? Its coarse step runs
    # `alumacc`, which FUSES $add/$sub/$mul/compare into the coarse macros $alu and $macc_v2.
    # write_verilog cannot render those, so it emits them as module instantiations and
    # GowinSynthesis fast-fails: `ERROR (EX3937): Instantiating unknown module '$macc_v2'`
    # (621 $alu + 151 $macc_v2 in the :map_gates netlist). There is no clean inverse pass to
    # un-fuse them, and a full `techmap` over-lowers ALL arithmetic to gates (kills DSP
    # inference, LUT bloat). So we simply never run alumacc: the passes below are exactly
    # synth_gowin's gw5a coarse (see `yosys -p 'help synth_gowin'`) with `alumacc` removed and
    # `flatten` skipped (-noflatten keeps the SP00018-clean hierarchy; #13 is parser-specific).
    # yosys does NOT run mul2dsp/dsp_map for gw5a anyway — $mul is left for GowinSynthesis's
    # own DSP inference, which is exactly what we want.
    #
    # map_ram = the #16 fix: memory_libmap+techmap (-D gw5a) map the byte-we cache arrays
    # (tc_sram_wrapper.mem) to $__GOWIN_SP_ -> SPX9 BSRAM, bypassing GowinSynthesis inference
    # (which demotes them to flops). memory_collect leaves the ~13 tiny remaining arrays
    # (predictor counters, fpnew lookup ROMs; <=128 entries) as clean inferrable behavioral
    # RAM for GowinSynthesis to place in LUTRAM/BSRAM — cheaper on the FF budget than FF-mapping.
    #
    # Validated at scale from the checkpoint: 4 SPX9, 0 $alu/$macc, 0 IBUF/OBUF, 0 residual
    # $mem, 0 per-bit writes, high-level +/-/* preserved (426/659/57), 139 modules.
    # See docs/gowin-bsram-inference-debug.md.
    echo "=== yosys stage 2 (s2): coarse-minus-alumacc + hard-map RAM -> gw5a SPX9 BSRAM -> $FINAL ==="
    yosys -q -p "
      read_rtlil $CKPT;
      proc; opt_expr; opt_clean; check;
      opt -nodffe -nosdff; fsm; opt; wreduce; peepopt; opt_clean; share;
      opt; memory -nomap; opt_clean;
      memory_libmap -lib +/gowin/lutrams.txt -lib +/gowin/brams.txt -D gw5a;
      techmap -map +/gowin/lutrams_map.v -map +/gowin/brams_map.v -D gw5a;
      opt_clean; memory_collect; opt_clean;
      write_verilog -noattr $FINAL
    "
  fi
fi

echo "fpga-m3-core-rtl: wrote $FINAL ($(wc -l < "$FINAL") lines, $(grep -c '^module' "$FINAL") modules)"
echo "  guest path baked into m3-core.tcl: /work/build/fpga-m3-core-rtl/cva6_core.v"
echo "  next:  nix run .#fpga-build -- m3-core"
