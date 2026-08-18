# nix/cva6-patched.nix
#
# The parser-patched CVA6 source tree, as its OWN small derivation so /nix/store
# caches it: it only rebuilds when the pinned source (cva6.nix), the patches
# (cva6-parser/*.patch), or the parser RTL (rtl/) change — a Verilator build
# layered on top (cva6-parser) then reuses the cached tree. This is the "patched
# source" layer that lets us offer BOTH an unpatched (cva6-baseline) and a patched
# (cva6-parser) build for easy compare/validate. (See docs/nix.md;
# nix-small-cacheable-derivations.)
#
# Two things happen here:
#   1. The parser RTL (rtl/*.sv used by the in-core FU) is copied into
#      core/parser/ so the Flist can compile it into the core.
#   2. The patches are applied in order (plain unified diffs, git apply -p1 from
#      the tree root), so each reviews on its own and is decoupled from the source:
#        decode.patch   — ariane_pkg fu_t::PARSER + PARSER_C0/C3 fu_ops; decoder
#                         routes custom-0/custom-3 to the PARSER FU.
#        issue-ex.patch — ISSUE handshake (parser_valid/ready), EX FU instantiation
#                         (cva6_parser_wrap + parser_decode/pktbuf/cam), a parser
#                         writeback port (NrWbPorts+1), and the resolved_branch_o
#                         end-of-node redirect mux; Flist adds core/parser/*.sv.
#        tb-backdoor.patch — I2 sim-only observability: an XMR watcher in the
#                         testharness that prints a grep-able marker when the parser
#                         FU's commit-gated metadata frame lands (no MMIO; deferred).
#        mmio.patch     — I5 real MMIO: a SoC AXI slave at ariane_soc::ParserBase
#                         (0x5000_0000) that `sd`s the packet into the FU's packet
#                         buffer, sets ParseLen, and `ld`s the committed flow_keys
#                         back out (axi2mem + decode; ports threaded ariane→cva6→
#                         ex_stage→parser_pktbuf/u_parser_fu). Closes the deferred
#                         packet-feed / readback escalation the backdoor stood in for.
#      (docs/analysis/cva6-integration.md §3–§5/§8; cva6-verification-design.md §1.)
#
{ pkgs, cva6-src, parserRtl }:

pkgs.runCommand "cva6-parser-src"
{
  nativeBuildInputs = [ pkgs.git ];
  # the patches applied, in order — bump this list as further stages land.
  #   tandem-get-misa-d-bit  — fix vendored core-v-verif get_misa() to set the D
  #                            misa bit (it only set F), so the Phase-7 RVFI-vs-Spike
  #                            lock-step's reference Spike keeps FP double ops legal.
  #   tandem-mstatus-sd-mask — mask the read-only mstatus.SD summary bit in the tandem
  #                            CSR compare (CVA6's RVFI omits it; Spike computes it).
  #   Both touch only SPIKE_TANDEM-gated SV, so non-tandem builds are unaffected.
  patches = [ ./cva6-parser/decode.patch ./cva6-parser/issue-ex.patch ./cva6-parser/tb-backdoor.patch ./cva6-parser/mmio.patch ./cva6-parser/tandem-get-misa-d-bit.patch ./cva6-parser/tandem-mstatus-sd-mask.patch ];
}
''
  cp -r --no-preserve=mode,ownership ${cva6-src} "$out"
  cd "$out"

  # (1) copy the parser FU RTL into the core so the Flist can compile it. Only the
  # synthesizable units the in-core FU needs — the sim scaffolds (tb/parser_top.sv,
  # tb/parser_smoke_tb.sv) and the generator/formal (verif/) are excluded.
  mkdir -p core/parser
  for f in parser_pkg parser_pktbuf parser_cam parser_decode parser_execute cva6_parser_wrap; do
    cp --no-preserve=mode,ownership ${parserRtl}/$f.sv core/parser/$f.sv
  done
  cp --no-preserve=mode,ownership ${parserRtl}/parser_asserts.svh core/parser/parser_asserts.svh

  # (2) a throwaway git repo makes `git apply` strict (rejects a fuzzy/partial
  # hunk), so a patch that no longer matches the pinned source fails the build
  # loudly.
  git init -q .
  git config user.email nobody@localhost
  git config user.name nobody
  git add -A
  git commit -qm base
  for p in $patches; do
    echo "== applying $p =="
    git apply -p1 --whitespace=nowarn "$p"
  done
  # drop the scratch repo so the output is just the tree.
  rm -rf .git
''
