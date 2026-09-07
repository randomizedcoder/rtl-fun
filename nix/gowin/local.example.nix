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

  # Absolute host path to the Gowin EDA install (the dir containing IDE/bin/gw_sh).
  #
  # Prefer a STORE PATH from nix/gowin-eda.nix over a hand-extracted directory — that
  # is the whole point of packaging it, and a read-only store path is fine (the
  # gowin-check wrapper overlayfs's it when it needs to write gwlicense.ini):
  #
  #     nix build --no-link --print-out-paths .#gowin-eda
  #
  # It MUST be the COMMERCIAL edition for the Tang Mega 138K Pro. Education
  # 1.9.11.03's device_info.csv has no FPG676 order code, so `set_device
  # GW5AST-LV138FPG676AC1/I0` cannot resolve. See nix/gowin-eda.nix.
  gowinInstall = "/nix/store/xxxxxxxx-gowin-eda-1.9.12.03";

  # Absolute host path to this repo checkout (shared into the guest at /work; the Gowin
  # license file `./gowin` and the Tcl scripts under nix/gowin/ are read from here).
  repoRoot = "/home/you/rtl-fun";

  # Optional. Defaults are vcpu = 6, mem = 8192 (MiB) — enough for blinky (peak
  # ~1.2 GB), nowhere near enough for a full CVA6 synth (~18 GB peak).
  # mem = 49152;
  # vcpu = 16;
}
