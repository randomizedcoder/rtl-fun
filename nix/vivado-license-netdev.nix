# nix/vivado-license-netdev.nix
#
# NixOS module: a dummy network interface (`vivadolic`) carrying the fixed
# Vivado-license MAC (nix/vivado-license-mac.nix), so the free Vivado Basic license
# node-locked to that MAC is valid on ANY machine that imports this module — one
# license, portable across `l`, `hp5`, etc.
#
# Why a system-level module (not inside the box): creating a network interface or
# setting a MAC is blocked in unprivileged user namespaces on this kernel (bwrap
# `ip link add` -> "RTNETLINK answers: Operation not permitted"), so the fixed MAC must
# be established at the system layer with real privilege. The Vivado box shares the host
# network namespace, so once `vivadolic` exists on the host, FlexLM inside the box sees
# it and matches the license.
#
# Non-disruptive: this ADDS a new dummy interface and never touches your real NICs. It
# is a stack-agnostic systemd oneshot (works alongside NetworkManager, systemd-networkd,
# or scripted networking) rather than a `systemd.network.*` netdev, so it does not force
# a particular networking backend on your system.
#
# Usage — import into your NixOS configuration and rebuild:
#   imports = [ /path/to/rtl-fun/nix/vivado-license-netdev.nix ];
#   # or, from a flake system config:
#   imports = [ inputs.rtl-fun.nixosModules.vivado-license-netdev ];
# then:
#   sudo nixos-rebuild switch
#   ip link show vivadolic          # confirm it exists with the fixed MAC
{ lib, pkgs, ... }:

let
  mac = import ./vivado-license-mac.nix;
  ip = "${pkgs.iproute2}/bin/ip";
in
{
  boot.kernelModules = [ "dummy" ];

  systemd.services.vivado-license-nic = {
    description = "Dummy NIC carrying the fixed Vivado license MAC (${mac})";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-pre.target" ];
    before = [ "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "vivado-license-nic-up" ''
        set -eu
        ${ip} link show vivadolic >/dev/null 2>&1 || ${ip} link add vivadolic type dummy
        ${ip} link set vivadolic address ${mac}
        ${ip} link set vivadolic up
      '';
      ExecStop = "${ip} link del vivadolic";
    };
  };
}
