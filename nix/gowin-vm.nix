#
# nix/gowin-vm.nix — Gowin EDA feasibility microVM.
#
# Purpose (Phase-8 pre-purchase gate): the Gowin GW5AST-138 license is node-locked to a
# MAC address (HOST_ID). This builds a throwaway NixOS microVM whose virtual NIC presents
# *exactly* that MAC, so `gw_sh` licenses cleanly without rebinding the host's real NIC.
# The synth/place-and-route/timing flow runs in software with no board attached, which is
# enough to answer: does the Education/NODELOCK license permit GW5AST-LV138FPG676A?
#
# Run:  nix run .#gowin-vm      (boots to a root serial console)
# Then inside the guest:
#   gowin-check /work/nix/gowin/device-check.tcl   # Tier-1: license/device gate (blinky)
#   gowin-check /work/nix/gowin/cva6-util.tcl       # Tier-2: cv64a6_imac utilization + Fmax
#
# See docs/gowin-microvm.md. The license-locked MAC and the host install path are read from
# the gitignored nix/gowin/local.nix (fall back to the committed template so `nix flake check`
# still evaluates for anyone without a local.nix). Nothing PII lands in a committed file.
#
{ nixpkgs, microvm, system ? "x86_64-linux" }:
let
  # Machine-local settings (license-locked MAC + host paths) are NOT in git, so a pure flake
  # eval cannot see them. Read them impurely from the path in $GOWIN_VM_LOCAL (which the run
  # command sets to the gitignored nix/gowin/local.nix); fall back to the committed template
  # so `nix flake check` still evaluates on machines without a local config.
  #   GOWIN_VM_LOCAL=$PWD/nix/gowin/local.nix nix run --impure .#gowin-vm
  envLocal = builtins.getEnv "GOWIN_VM_LOCAL";
  local =
    if envLocal != "" && builtins.pathExists envLocal
    then import envLocal
    else import ./gowin/local.example.nix;

  repoRoot = local.repoRoot;

  nixos = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      microvm.nixosModules.microvm
      { nixpkgs.config.allowUnfree = true; }
      ({ pkgs, lib, ... }:
        let
          # `gowin-check <script.tcl>` — sets up the node-locked license and runs gw_sh.
          # Gowin selects node-locked (GWLIC::check_from_local) vs a license server
          # (check_from_server) via a `gwlicense.ini` sitting next to the binary: `lic=` set
          # to a filesystem PATH reads the node-locked file; `lic="host:port"` connects to a
          # server (which is what an ABSENT ini defaults to — hence the earlier "Connection
          # timeout"). We point lic= at the shared license file /work/gowin.
          # The install may be a read-only share, so fall back to an overlay for a writable
          # bin dir. Hoisted so both the interactive PATH and the gate service use it.
          gowinCheck = pkgs.writeShellScriptBin "gowin-check" ''
            export GOWIN_HOME=/opt/gowin/IDE
            # gw_sh links Qt and inits a QApplication; force the headless offscreen platform
            # (bundled) so it does not try to open the xcb/X11 display and abort.
            export QT_QPA_PLATFORM=offscreen
            lic=/work/gowin
            bin=/opt/gowin/IDE/bin
            write_ini() { printf '[license]\nlic="%s"\n' "$lic" > "$1/gwlicense.ini"; }
            if ! write_ini "$bin" 2>/dev/null; then
              # read-only install: overlay a writable IDE tree (needs root; the gate + the
              # interactive console both run as root).
              mkdir -p /run/gowin-up /run/gowin-wk /run/gowin-ide
              mount -t overlay overlay \
                -o lowerdir=/opt/gowin/IDE,upperdir=/run/gowin-up,workdir=/run/gowin-wk \
                /run/gowin-ide
              bin=/run/gowin-ide/bin
              export GOWIN_HOME=/run/gowin-ide
              write_ini "$bin"
            fi
            echo "[gowin-check] using bin=$bin GOWIN_HOME=$GOWIN_HOME license=$lic" >&2
            export PATH="$bin:$PATH"
            exec gw_sh "$@"
          '';
        in
        {
          microvm.hypervisor = "qemu";
          microvm.vcpu = local.vcpu or 6;
          microvm.mem = local.mem or 8192; # override in local.nix; Tier-2 CVA6 synth may want more

          # The license-locked MAC on a QEMU user-mode NIC (no host root / tap needed).
          # The guest reads this off its NIC; Gowin matches it against the license HOST_ID.
          microvm.interfaces = [{
            type = "user";
            id = "gowin0";
            mac = local.mac;
          }];

          # Share the host store, the extracted Gowin install (ro), and the repo (rw for reports).
          # 9p (built into qemu, no virtiofsd) keeps the runner a single self-contained process;
          # switch to proto = "virtiofs" for faster shares once the flow is validated.
          microvm.shares = [
            {
              proto = "9p";
              tag = "store";
              source = "/nix/store";
              mountPoint = "/nix/.ro-store";
            }
            {
              proto = "9p";
              tag = "gowin";
              source = local.gowinInstall;
              mountPoint = "/opt/gowin";
            }
            {
              proto = "9p";
              tag = "work";
              source = repoRoot;
              mountPoint = "/work";
            }
          ];

          # gw_sh is a prebuilt x86-64 ELF (interpreter /lib64/ld-linux-x86-64.so.2). nix-ld
          # provides the loader shim + these libs; the Gowin/Qt libs are self-contained via
          # the binary's $ORIGIN/../lib rpath. The GL/NSS/X11 set is dragged in by bundled
          # Qt5WebEngine and mostly dormant for the headless CLI, but the loader still resolves it.
          programs.nix-ld.enable = true;
          programs.nix-ld.libraries = with pkgs; [
            zlib
            libGL
            expat
            fontconfig
            freetype
            nss
            nspr
            dbus
            glib
            libx11 # ships libX11-xcb.so.1 too
            libxcomposite
            libxdamage
            libxfixes
            libxrandr
            libxtst
            libxext
            libxrender
            libxkbcommon # Qt xcb platform pulls this in even for the CLI
            xorg.libxcb
            xorg.xcbutil
            xorg.xcbutilwm
            xorg.xcbutilimage
            xorg.xcbutilkeysyms
            xorg.xcbutilrenderutil
            xorg.xcbutilcursor
            xorg.libXi
            xorg.libXcursor
            xorg.libXScrnSaver
            # The Gowin binary bundles Qt5WebEngine, whose NEEDED closure the loader must
            # satisfy even for the headless CLI. This is that closure.
            alsa-lib
            at-spi2-atk
            at-spi2-core
            cairo
            pango
            gtk3
            gdk-pixbuf
            cups
            libdrm
            mesa # libgbm / libEGL
            libxshmfence
            libpulseaudio
            systemd # libudev
            bzip2 # libbz2.so.1
            libkrb5 # libgssapi_krb5.so.2 (via bundled libcurl/nss)
            stdenv.cc.cc.lib
          ];

          # Serial console drops straight into a shell.
          services.getty.autologinUser = "root";

          environment.systemPackages = [
            gowinCheck
            pkgs.zlib
            pkgs.dtc
          ];

          # Marker-gated autorun: for headless verification the Tier-1 gate runs at boot and the
          # VM powers off, so its result lands in the shared /work — WITHOUT changing the default
          # interactive experience. It only fires when /work/build/gowin/RUN_GATE exists; a normal
          # `nix run .#gowin-vm` (no marker) just boots to the shell.
          systemd.services.gowin-gate = {
            description = "Gowin GW5AST-138 marker-gated autorun (Tier-1 gate / Tier-2 CVA6 synth)";
            wantedBy = [ "multi-user.target" ];
            after = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              StandardOutput = "journal+console";
              StandardError = "journal+console";
            };
            path = [ gowinCheck pkgs.coreutils pkgs.util-linux pkgs.systemd ];
            script = ''
              # Wait for the 9p shares to be mounted.
              for m in /work /opt/gowin; do
                for _ in $(seq 1 60); do mountpoint -q "$m" && break; sleep 1; done
              done

              # Tier-1 gate (blinky license/device check).
              if [ -e /work/build/gowin/RUN_GATE ]; then
                mkdir -p /work/build/gowin
                cd /work/build/gowin
                {
                  echo "[gowin-gate] ===== Tier-1 gate run ====="
                  echo "[gowin-gate] gw_sh: $(command -v gw_sh || echo MISSING)"
                  echo "[gowin-gate] license: $(ls -l /work/gowin 2>&1)"
                  echo "[gowin-gate] --- gw_sh device-check.tcl output ---"
                  gowin-check /work/nix/gowin/device-check.tcl || echo "[gowin-gate] gw_sh exit=$?"
                  echo "[gowin-gate] ===== done ====="
                } 2>&1 | tee /work/build/gowin/gate.log
                rm -f /work/build/gowin/RUN_GATE
                systemctl poweroff
                exit 0
              fi

              # Tier-2 CVA6 utilization/Fmax. The marker file may carry `netlist=<path>` and
              # `outdir=<path>` lines; both default to the on-disk imafdc flatten.
              if [ -e /work/build/gowin/RUN_CVA6 ]; then
                netlist=$(sed -n 's/^netlist=//p' /work/build/gowin/RUN_CVA6)
                outdir=$(sed -n 's/^outdir=//p' /work/build/gowin/RUN_CVA6)
                : "''${netlist:=/work/build/fpga-eval/flat.v}"
                : "''${outdir:=/work/build/gowin-cva6-imafdc}"
                mkdir -p "$outdir"
                cd "$outdir"
                {
                  echo "[gowin-gate] ===== Tier-2 CVA6 synth run ====="
                  echo "[gowin-gate] netlist=$netlist outdir=$outdir"
                  echo "[gowin-gate] netlist size: $(ls -l "$netlist" 2>&1)"
                  CVA6_NETLIST="$netlist" CVA6_TOP=cva6 \
                    gowin-check /work/nix/gowin/cva6-util.tcl || echo "[gowin-gate] gw_sh exit=$?"
                  echo "[gowin-gate] ===== done ====="
                } 2>&1 | tee "$outdir/synth.log"
                rm -f /work/build/gowin/RUN_CVA6
                systemctl poweroff
                exit 0
              fi

              echo "[gowin-gate] no RUN_GATE/RUN_CVA6 marker under /work/build/gowin — interactive boot, skipping autorun"
              exit 0
            '';
          };

          # Quality-of-life for an interactive throwaway VM.
          networking.hostName = "gowin-vm";
          time.timeZone = "UTC";
          system.stateVersion = "24.11";
        })
    ];
  };
in
{
  inherit nixos;
  # What `nix run .#gowin-vm` executes.
  runner = nixos.config.microvm.declaredRunner;
}
