#
# nix/gowin/local.example.nix — template for the machine-local Gowin VM settings.
#
# Copy this to nix/gowin/local.nix (which is GITIGNORED) and fill in your values.
# nix/gowin-vm.nix imports local.nix if it exists, otherwise falls back to this template
# so `nix flake check` still evaluates on machines without a local config.
#
# Keep the real MAC and host paths OUT of git: they are a personal, license-locked
# credential. Only nix/gowin/local.nix carries them, and it is gitignored.
#
{
  # The MAC address your Gowin node-locked license is issued against (HOST_ID), in
  # colon-separated form. The VM's virtual NIC presents this so `gw_sh` licenses cleanly.
  # Placeholder — replace with your licensed MAC in local.nix.
  mac = "02:00:00:00:00:01";

  # Absolute host path to the extracted Gowin EDA install (the dir containing IDE/bin/gw_sh).
  gowinInstall = "/opt/gowin-eda";

  # Absolute host path to this repo checkout (shared into the guest at /work; the Gowin
  # license file `./gowin` and the Tcl scripts under nix/gowin/ are read from here).
  repoRoot = "/home/you/rtl-fun";
}
