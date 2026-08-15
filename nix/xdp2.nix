# Pinned xdp2 source — provides the proto_audit packet corpus (378 protocol
# pcap templates under samples/proto_audit/pcap_templates/). Pinning the exact
# commit makes the packet vectors reproducible; see docs/phase-2-reference-model.md.
#
# To bump: change rev, set hash to lib.fakeHash, `nix build .#xdp2-src`, copy the
# hash from the error. Or: nix run nixpkgs#nix-prefetch-github -- randomizedcoder xdp2 --rev <rev>
{ pkgs }:
pkgs.fetchFromGitHub {
  owner = "randomizedcoder";
  repo = "xdp2";
  rev = "cf54ec62dd633c85ebe259e0c29b29545a896fce"; # flowdis-series6-ebpf-menu
  hash = "sha256-QCEPWUOaEk2NLX6n0vPSxwc+pJMbYrrk4dro0vOs9BU=";
}
