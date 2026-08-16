# nix/cva6-patched.nix
#
# The parser-patched CVA6 source tree, as its OWN small derivation so /nix/store
# caches it: it only rebuilds when the pinned source (cva6.nix) or the patch
# (cva6-parser/*.patch) changes — a Verilator build layered on top (cva6-parser)
# then reuses the cached tree. This is the "patched source" layer that lets us
# offer BOTH an unpatched (cva6-baseline) and a patched (cva6-parser) build for
# easy compare/validate. (See docs/nix.md; nix-small-cacheable-derivations.)
#
# The patch is a plain unified diff (git apply -p1 from the tree root), so it is
# reviewable on its own and decoupled from the fetched source. Content so far:
#   decode.patch — ariane_pkg fu_t::PARSER + PARSER_C0/C3 fu_ops; decoder routes
#                  custom-0/custom-3 to the PARSER FU (docs/analysis/cva6-integration.md §3).
#
{ pkgs, cva6-src }:

pkgs.runCommand "cva6-parser-src"
{
  nativeBuildInputs = [ pkgs.git ];
  # the patches applied, in order — bump this list as issue/EX land.
  patches = [ ./cva6-parser/decode.patch ];
}
''
  cp -r --no-preserve=mode,ownership ${cva6-src} "$out"
  cd "$out"
  # a throwaway git repo makes `git apply` strict (rejects a fuzzy/partial hunk),
  # so a patch that no longer matches the pinned source fails the build loudly.
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
