#!/usr/bin/env bash
# phase-3-arch-postinstall/postinstall.sh
#
# Run as user `tom` after first login on the freshly-installed Arch system.
# Network required. Idempotent — safe to re-run.
#
#   chmod +x ~/postinstall.sh && ~/postinstall.sh
#
# What it does (all per decisions.md):
#   - pacman -S everything available in extra (signed, fast)
#   - yay bootstrap; yay -S for AUR-only tail (VSCode, Edge, pinpam-git, ...)
#   - SSH key (ed25519) if missing
#   - sshd: hardened drop-in (key-only, no root, AllowUsers tom) + enable
#   - Callisto pubkey (hardcoded, idempotent append to authorized_keys)
#   - ufw firewall (default deny in, allow ssh, enable) — required because
#     router's IPv6 filter is host-global, can't filter per port
#   - azure-ddns: AUR package (https://github.com/fnrhombus/azure-ddns) —
#     bash + systemd timer that keeps metis.rhombus.rocks A+AAAA in sync
#     with this host's public IPs against Azure DNS (no maintained off-
#     the-shelf option exists). The package ships a stub /etc/azure-ddns.env;
#     `setup-azure-ddns.sh` fills in SP creds and enables the timer.
#   - Claude Code CLI + bash completion
#   - Goodix-aware fingerprint enrollment (VID 27C6 detected → detailed diag on fail)
#   - pinpam TPM-PIN + PAM wiring for sudo/polkit/hyprlock
#   - Bitwarden SSH agent in ~/.ssh/config
#   - gh identity + signing key registration (first-login planter if no token yet)
#   - zgenom + p10k + the full fnwsl plugin set (history/completion/PATH dedup
#     brought in from fnwsl; WSL-specific pieces dropped). p10k config itself
#     is authored by the user via `p10k configure` on first shell launch —
#     no pre-shipped ~/.p10k.zsh.
#   - chezmoi init --apply rhombu5/dots — clones the dots repo into
#     ~/src/dots@rhombu5 (sourceDir override via
#     ~/.config/chezmoi/chezmoi.toml; matches the user prefs convention
#     of `{repo}@{user}` under ~/src/ for github clones the user
#     edits) and writes the bare Hyprland configs (split fragments),
#     waybar, swaync, fuzzel, ghostty, yazi, helix, qt5/6ct,
#     matugen pipeline + templates, helper scripts.
#   - 2-in-1 touch: iio-sensor-proxy / iio-hyprland (rotation), wvkbd (OSK),
#     libwacom (Wacom AES stylus)
#   - matugen Material You palette derived from wallpaper; rendered into
#     waybar / swaync / fuzzel / ghostty / hypr-colors / etc.
#   - Snapper baseline snapshot
#   - USB-serial udev rules (ESP32/Pico)
#
# The verify block at the end enumerates every tool as FAIL/OK.

set -euo pipefail

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; RUN_WARNINGS+=("$*"); }
die()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

# Every warn() call appends here. Surfaced as a summary panel at the end
# of the run (right after the verify block) so issues that happened on
# screen 3 of 30 don't get lost in scrollback.
RUN_WARNINGS=()

# retry <cmd> [args...] — 4 attempts, exponential backoff (2/4/8s between).
# For network ops that flap on transient connection drops. We use this
# even on yay -S: yay's RPC client to aur.archlinux.org/rpc does NOT
# retry on EOF and just returns "Failed to find AUR package for X",
# which on a flaky link can wrongly mark a perfectly-good package as
# unfindable. pacman is multi-mirror so it doesn't need this.
retry() {
    local delay=2 attempt
    for attempt in 1 2 3 4; do
        if "$@"; then return 0; fi
        if [[ $attempt -lt 4 ]]; then
            warn "retry ($attempt/4) — sleeping ${delay}s before retrying: $*"
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done
    die "retry: gave up after 4 attempts: $*"
}

# retry_soft is retry's non-fatal sibling: same backoff, but on terminal
# failure it warns and returns 1 instead of die-ing. Use this when the
# script can continue without this particular thing succeeding (e.g.
# one AUR package out of 14 in the AUR loop).
retry_soft() {
    local delay=2 attempt
    for attempt in 1 2 3 4; do
        if "$@"; then return 0; fi
        if [[ $attempt -lt 4 ]]; then
            warn "retry_soft ($attempt/4) — sleeping ${delay}s before retrying: $*"
            sleep "$delay"
            delay=$((delay * 2))
        fi
    done
    warn "retry_soft: gave up after 4 attempts: $*"
    return 1
}

# Per docs/wsl-setup-lessons.md: every `git clone` in this repo's setup
# scripts must run with GIT_TEMPLATE_DIR="" to avoid leaking the user's
# global init-template into freshly-cloned repos. Exporting once here
# means the retry helper doesn't have to special-case env prefixes.
export GIT_TEMPLATE_DIR=""

# CLI flags. Order-independent, no-arg.
SKIP_VERIFY=0
SKIP_WINDOWS_INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --no-verify|--skip-verify) SKIP_VERIFY=1 ;;
        --skip-windows-install) SKIP_WINDOWS_INSTALL=1 ;;
        -h|--help)
            cat <<USAGE
Usage: postinstall.sh [--no-verify] [--skip-windows-install]

  --no-verify              Skip the verify block at the end (faster re-runs
                           when you've just touched one section and don't
                           want to wait for ~70 checks to fan out).

  --skip-windows-install   Don't bring up the dockur/windows VM and don't
                           wait for the ~30 min unattended Windows install.
                           Use when you want postinstall to finish quickly
                           and you'll run \`docker compose -f /etc/dockur-windows/compose.yaml up -d\`
                           manually later.
USAGE
            exit 0 ;;
        *)
            warn "unknown arg: $arg (ignoring)" ;;
    esac
done

[[ "$(id -un)" == "tom" ]] || die "Run as user 'tom'."
ping -c1 -W3 archlinux.org >/dev/null || die "No network."

# --- sudoa auto-detect ---
# Replaces the `sudo -v` prerequisite for re-runs / installs where dots
# has been applied at least once. If ~/.local/bin/claude-askpass is
# present and successfully returns a password, export SUDO_ASKPASS so
# the keeper below picks the askpass branch — no interactive auth at
# all for the rest of the run.
# Fresh installs without dots applied yet still hit the fallback below
# (the unchanged `sudo -v` requirement); that path is preserved.
if [[ -z "${SUDO_ASKPASS:-}" ]] \
    && [[ -x "$HOME/.local/bin/claude-askpass" ]] \
    && "$HOME/.local/bin/claude-askpass" >/dev/null 2>&1; then
    export SUDO_ASKPASS="$HOME/.local/bin/claude-askpass"
    log "sudoa detected: SUDO_ASKPASS=$SUDO_ASKPASS — postinstall will run unattended"
fi

# --- sudo keeper ---
# A full postinstall takes 10-20 min and fires dozens of sudo calls. If sudo
# needs fresh auth mid-run (fingerprint/PIN/password), it silently hangs the
# script — our Bash context has no TTY to prompt through. Keep the credential
# cache warm by touching it every 60s for the life of this script.
#
# Two modes:
#   - SUDO_ASKPASS exported + helper executable  → keeper can re-auth on its
#     own via `sudo -A` when the cache expires. Robust to anything inside
#     the run that clears the cache (some installer scripts have been observed to).
#   - Otherwise                                    → keeper only refreshes an
#     already-cached credential via `sudo -n -v`. A pre-run `sudo -v` is
#     required; if the cache is ever cleared during the run, the next sudo
#     call will hang.
if [[ -n "${SUDO_ASKPASS:-}" ]] && [[ -x "${SUDO_ASKPASS}" ]]; then
    sudo -A -v 2>/dev/null \
        || die "sudo -A prime failed. Check SUDO_ASKPASS=$SUDO_ASKPASS returns the correct password."
    sudo_refresh() { sudo -An -v 2>/dev/null || sudo -A -v 2>/dev/null; }
else
    sudo -n -v 2>/dev/null \
        || die "sudo is not pre-authed. Either run 'sudo -v' in your terminal first, or export SUDO_ASKPASS pointing at a helper script that prints your password."
    sudo_refresh() { sudo -n -v 2>/dev/null; }
fi
(
    while sudo_refresh; do sleep 60; done
) &
SUDO_KEEPER_PID=$!
trap 'kill "$SUDO_KEEPER_PID" 2>/dev/null || true' EXIT

export HOME="/home/tom"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HOME"

# ---------- 1. pacman: repo packages (signed, fast) ----------
# --overwrite '/boot/memtest86+/*': on re-runs (or when an earlier failed
# transaction left orphan files behind), pacman aborts with "exists in
# filesystem" for /boot/memtest86+/memtest.{bin,efi}. Same bytes, same
# package version — overwriting is safe and idempotent.
log "Installing pacman packages from official repos..."
sudo pacman -Syu --noconfirm --needed \
    --overwrite '/boot/memtest86+/*' \
    base-devel git curl wget openssh \
    inetutils bind \
    zsh tmux helix \
    bat fd ripgrep eza lsd btop jq fzf zoxide direnv \
    sd go-yq xh \
    man-db man-pages pkgfile tldr \
    wl-clipboard grim slurp \
    xdg-user-dirs pipewire pipewire-pulse pipewire-jack wireplumber \
    noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd ttf-firacode-nerd \
    terminus-font \
    bitwarden bitwarden-cli \
    ghostty fuzzel cliphist satty hyprshot \
    nautilus yazi \
    hyprland hyprlock hypridle hyprpolkitagent hyprpicker uwsm \
    waybar swaync swayosd \
    xdg-desktop-portal-gtk xdg-desktop-portal-hyprland \
    network-manager-applet pavucontrol hyprpwcenter ttf-material-symbols-variable blueman udiskie \
    nwg-look nwg-displays \
    qt5ct qt6ct papirus-icon-theme \
    imv zathura zathura-pdf-poppler \
    iio-sensor-proxy libwacom wtype \
    mission-center \
    remmina freerdp \
    ufw \
    azure-cli lego rclone \
    memtest86+ memtest86+-efi \
    smartmontools \
    sbctl \
    mise chezmoi github-cli \
    docker docker-compose docker-buildx nvidia-container-toolkit \
    snapper snap-pac \
    cmake cpio

sudo pkgfile -u

# ---------- 1-print. CUPS + gutenprint (Canon Pro 9000 Mk II via USB) ----------
# CUPS is the spooler; gutenprint ships the open-source PPDs that cover
# legacy Canon Pixma inkjets including the Pro 9000 Mark II (released 2009 —
# pre-cnijfilter consolidation, so Canon's own driver isn't packaged for it).
# system-config-printer adds the GTK GUI for adding/removing printers.
# usbutils is needed by CUPS auto-discovery on USB-attached printers.
log "Installing CUPS + gutenprint (Canon Pro 9000 Mk II)..."
sudo pacman -S --noconfirm --needed \
    cups cups-pdf cups-filters \
    gutenprint foomatic-db foomatic-db-engine \
    ghostscript system-config-printer usbutils
# cups.socket = on-demand activation (vs cups.service which runs forever).
# Lighter; CUPS spins up only when something hits :631 or queues a job.
sudo systemctl enable --now cups.socket
# `lp` group lets users manage queues / cancel others' jobs.
if ! id -nG tom | grep -qw lp; then
    sudo usermod -aG lp tom
    warn "Added tom to lp group — log out and back in for CUPS GUI access."
fi

# ---------- 1-smart. smartd: ongoing SMART monitoring ----------
# The BIOS "SMART Reporting" toggle only surfaces errors at POST. smartd
# runs continuously and logs to journald + emails root on pre-fail events.
# Arch's default /etc/smartd.conf is a single DEVICESCAN line that covers
# every detected drive with sensible defaults — no custom config needed
# unless we want per-drive test schedules later.
sudo systemctl enable --now smartd.service

# ---------- 1a. docker: enable service, add tom to docker group ----------
# `docker` group grants root-equivalent access to the daemon; that's fine on
# a single-user laptop. Logging out and back in (or `newgrp docker`) is
# required for the group to take effect in a running shell.
log "Enabling docker service and adding tom to docker group..."
sudo systemctl enable --now docker.service
if ! id -nG tom | grep -qw docker; then
    sudo usermod -aG docker tom
    warn "Added tom to docker group — log out and back in for it to take effect."
fi

# ---------- 1a-nvctk. NVIDIA Container Toolkit: wire GPU into Docker ----------
# nvidia-container-toolkit (§1) installs the runtime; `nvidia-ctk runtime
# configure --runtime=docker` writes /etc/docker/daemon.json so containers
# can `docker run --gpus all ...` against the host nvidia-470xx driver.
# Idempotent: nvidia-ctk re-applies the same config block on re-runs;
# docker.service is only restarted if the config actually changed.
#
# The host driver (nvidia-470xx-dkms + utils) is installed via §3 AUR;
# this step only needs the toolkit binary in place, which is true after
# the §1 pacman pass above.
if command -v nvidia-ctk >/dev/null; then
    log "Configuring NVIDIA Container Toolkit runtime for Docker..."
    daemon_json=/etc/docker/daemon.json
    pre_hash=$(sudo sha256sum "$daemon_json" 2>/dev/null | awk '{print $1}' || true)
    sudo nvidia-ctk runtime configure --runtime=docker --quiet
    post_hash=$(sudo sha256sum "$daemon_json" 2>/dev/null | awk '{print $1}' || true)
    if [[ "$pre_hash" != "$post_hash" ]]; then
        log "  daemon.json changed — restarting docker.service"
        sudo systemctl restart docker.service
    fi
fi

# ---------- 1a-dockur. Windows VM compose for dockur/windows + WinApps ----------
# dockur/windows runs Win11 in QEMU under Docker, fully unattended on first
# `docker compose up`. Replaces the prior libvirt+QEMU stack: smaller
# footprint (no virt-manager / libvirt daemon), declarative compose-as-
# code, fits the existing Docker-for-cloud-storage story. WinApps
# (§3-winapps) bridges via FreeRDP to surface individual Windows apps
# as Hyprland windows (Parallels-Coherence-equivalent).
#
# We write the compose file + OEM first-boot script here. The actual
# `docker compose up -d` + 30-min wait happens in §15-windows below
# (skippable via --skip-windows-install). Splitting the write from the
# bring-up means the compose file lands even if the user skips the
# install — they can run it manually later.
log "Writing dockur/windows compose + OEM first-boot script..."
sudo install -d -m 755 /etc/dockur-windows /etc/dockur-windows/oem
sudo tee /etc/dockur-windows/compose.yaml >/dev/null <<'DOCKUREOF'
# /etc/dockur-windows/compose.yaml — Win11 + VS Enterprise, exposed via
# RDP on 127.0.0.1:3389 for WinApps. Web UI at http://127.0.0.1:8006/
# during install / for direct VM display.
#
# Ports bind to 127.0.0.1 only — VM is not reachable from LAN. The host
# is single-user + LUKS-encrypted, so the literal "Docker"/"Docker" RDP
# credentials are fine here; threat model is local-only.
name: windows
services:
  windows:
    image: dockurr/windows
    container_name: windows
    environment:
      VERSION: "11"
      RAM_SIZE: "8G"
      CPU_CORES: "4"
      DISK_SIZE: "128G"
      USERNAME: "Docker"
      PASSWORD: "Docker"
    devices:
      - /dev/kvm
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    ports:
      - "127.0.0.1:8006:8006"
      - "127.0.0.1:3389:3389/tcp"
      - "127.0.0.1:3389:3389/udp"
    volumes:
      - windows_data:/storage
      - /etc/dockur-windows/oem:/oem
    restart: unless-stopped
    stop_grace_period: 2m

volumes:
  windows_data:
DOCKUREOF

# OEM first-boot scripts. dockur/windows copies the /oem mount into
# C:\OEM in the guest and SetupComplete.cmd executes any *.bat / *.cmd
# files there during Windows OOBE finalization. We ship four files,
# adapted from the pre-2026-04-27 autounattend.xml that targeted a
# bare-metal Windows install (since dropped — see git log). Bare-metal-
# specific bits (Samsung-by-size disk detection, BitLocker handoff,
# diskpart partitioning, Wi-Fi profile injection, $WinPEDriver$ handling)
# are dropped; only the OS-config tweaks survive:
#
#   install.bat   — winget-installs Visual Studio 2022 Enterprise (IDE
#                   only — workloads picked via VS Installer GUI later
#                   to avoid multi-GB downloads on every reinstall).
#   setup.cmd     — HKLM machine tweaks (power, RDP, long paths, Edge
#                   policy, privacy/consumer-features off, Defender
#                   fully disabled — services + Group Policy + scheduled
#                   tasks + SmartScreen + Set-MpPreference), HKU\.DEFAULT
#                   sticky keys off, Default-user-hive defaults (so
#                   accounts created from Default inherit them), RunOnce
#                   registration for UserOnce.ps1.
#   debloat.ps1   — invoked by setup.cmd; removes consumer AppX
#                   provisioned packages (Bing/Maps/Xbox/etc.),
#                   Print.Fax.Scan capability, and Recall feature
#                   (Win11 24H2 screenshot-everything).
#   UserOnce.ps1  — fires once at first logon (HKLM\...\RunOnce),
#                   modifies HKCU (Explorer LaunchTo=ThisPC, hide
#                   taskbar searchbox, restart explorer.exe).
#
# VS Enterprise requires a Visual Studio subscription license. The bare
# IDE installs without one; sign in with your MSDN/VS subscription on
# first launch to activate.
#
# Defender disabled is appropriate here: VM is local-only, host is
# LUKS-encrypted, the threat model is "dev sandbox" not "internet-facing
# server." If you ever change that posture, edit setup.cmd to drop the
# whole "----- Defender: full disable -----" block (it's clearly fenced
# with REM banners) and re-run dockur from a fresh volume.
sudo tee /etc/dockur-windows/oem/install.bat >/dev/null <<'OEMEOF'
@echo off
REM Wait for winget to register (Win11 ships winget but registration
REM lags first boot by a minute or two on a fresh image).
:wait_winget
where winget >nul 2>&1
if errorlevel 1 (
    timeout /t 30 /nobreak >nul
    goto wait_winget
)

REM VS 2022 Enterprise — IDE only, no workloads (pick via VS Installer GUI).
winget install --exact --id Microsoft.VisualStudio.2022.Enterprise ^
    --accept-package-agreements ^
    --accept-source-agreements ^
    --silent
OEMEOF

sudo tee /etc/dockur-windows/oem/setup.cmd >/dev/null <<'SETUPEOF'
@echo off
REM ============================================================================
REM Adapted from the pre-2026-04-27 autounattend.xml's Specialize.ps1 +
REM DefaultUser.ps1 blocks. Runs once at SetupComplete via dockur's /oem mount.
REM ============================================================================

REM ----- Power: hibernation + Fast Startup off (no point on a VM) -----
powercfg.exe /hibernate off
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f

REM ----- Filesystem: long paths + skip lastAccess timestamps (perf) -----
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f
fsutil.exe behavior set disableLastAccess 1

REM ----- RDP: enable + open firewall (belt-and-suspenders for WinApps) -----
reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f
netsh.exe advfirewall firewall set rule group="@FirewallAPI.dll,-28752" new enable=Yes

REM ----- Privacy / consumer-features off -----
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v DisablePrivacyExperience /t REG_DWORD /d 1 /f
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Dsh" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f
reg.exe add "HKLM\Software\Policies\Microsoft\Windows\CloudContent" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f

REM ----- Edge: skip first-run, no background service, no startup boost -----
reg.exe add "HKLM\Software\Policies\Microsoft\Edge" /v HideFirstRunExperience /t REG_DWORD /d 1 /f
reg.exe add "HKLM\Software\Policies\Microsoft\Edge\Recommended" /v BackgroundModeEnabled /t REG_DWORD /d 0 /f
reg.exe add "HKLM\Software\Policies\Microsoft\Edge\Recommended" /v StartupBoostEnabled /t REG_DWORD /d 0 /f

REM ----- Defender: full disable -----
REM Tamper Protection caveat: Win11 24H2+ enables TP shortly after first user
REM interaction. SetupComplete runs BEFORE that, so the writes below stick on
REM the install we're doing. If a future Windows ISO ever enables TP earlier,
REM real-time monitoring may revert on reboot — manual workaround is Settings
REM > Privacy > Windows Security > Virus & threat protection > Manage settings
REM > Tamper Protection > Off, then re-run this script.

REM Group Policy registry (deprecated by MS for consumer 2022+, still honoured
REM on Enterprise/Server SKUs and as a belt-and-suspenders signal):
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiSpyware /t REG_DWORD /d 1 /f
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiVirus /t REG_DWORD /d 1 /f
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v DisableBehaviorMonitoring /t REG_DWORD /d 1 /f
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v DisableOnAccessProtection /t REG_DWORD /d 1 /f
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v DisableScanOnRealtimeEnable /t REG_DWORD /d 1 /f
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v DisableIOAVProtection /t REG_DWORD /d 1 /f
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet" /v DisableBlockAtFirstSeen /t REG_DWORD /d 1 /f
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet" /v SpynetReporting /t REG_DWORD /d 0 /f
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet" /v SubmitSamplesConsent /t REG_DWORD /d 2 /f

REM SmartScreen (file/URL reputation prompts) off
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableSmartScreen /t REG_DWORD /d 0 /f
reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" /v SmartScreenEnabled /t REG_SZ /d "Off" /f

REM Notification spam from the Security Center
reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications" /v DisableNotifications /t REG_DWORD /d 1 /f

REM Service start types (4 = Disabled). Sense = MDE telemetry; SecurityHealthService
REM = the tray icon / notification surface; the Wd* + WinDefend ones are the actual
REM scanning engine pieces.
for %%s in (Sense WdBoot WdFilter WdNisDrv WdNisSvc WinDefend SecurityHealthService) do reg.exe add "HKLM\SYSTEM\CurrentControlSet\Services\%%s" /v Start /t REG_DWORD /d 4 /f

REM Disable Defender's own scheduled-task cron jobs
schtasks.exe /Change /TN "\Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance" /Disable >nul 2>&1
schtasks.exe /Change /TN "\Microsoft\Windows\Windows Defender\Windows Defender Cleanup" /Disable >nul 2>&1
schtasks.exe /Change /TN "\Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan" /Disable >nul 2>&1
schtasks.exe /Change /TN "\Microsoft\Windows\Windows Defender\Windows Defender Verification" /Disable >nul 2>&1

REM Final belt-and-suspenders: ask Defender itself to turn off (only sticks if
REM Tamper Protection isn't enforcing — fine on our SetupComplete-time pass).
powershell.exe -NoProfile -Command "Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue"
powershell.exe -NoProfile -Command "Set-MpPreference -DisableIOAVProtection $true -ErrorAction SilentlyContinue"

REM ----- PowerShell exec policy + non-expiring local password (throwaway VM creds) -----
powershell.exe -NoProfile -Command "Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned -Force"
net.exe accounts /maxpwage:UNLIMITED

REM ----- Sticky keys off (HKU\.DEFAULT applies to LocalSystem + Default profile template) -----
reg.exe add "HKU\.DEFAULT\Control Panel\Accessibility\StickyKeys" /v Flags /t REG_SZ /d 10 /f

REM ----- Drop "Authenticated Users" write access from C:\ root (single-user VM hardening) -----
icacls.exe C:\ /remove:g "*S-1-5-11"

REM ============================================================================
REM Default user hive — defaults inherited by accounts created from Default.
REM Mount C:\Users\Default\NTUSER.DAT into HKU\DefaultUser; write; unmount.
REM ============================================================================
reg.exe load "HKU\DefaultUser" "C:\Users\Default\NTUSER.DAT"

REM Game DVR off (perf in VM)
reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v AppCaptureEnabled /t REG_DWORD /d 0 /f

REM Explorer: show extensions, show hidden, hide TaskView button, taskbar align left
reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v HideFileExt /t REG_DWORD /d 0 /f
reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Hidden /t REG_DWORD /d 1 /f
reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowTaskViewButton /t REG_DWORD /d 0 /f
reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAl /t REG_DWORD /d 0 /f

REM Developer: Task Manager 'End task' on right-click in taskbar
reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" /v TaskbarEndTask /t REG_DWORD /d 1 /f

REM No web-suggestions in start-menu search
reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer" /v DisableSearchBoxSuggestions /t REG_DWORD /d 1 /f

REM Sticky keys off (also under HKU\DefaultUser for new account inheritance)
reg.exe add "HKU\DefaultUser\Control Panel\Accessibility\StickyKeys" /v Flags /t REG_SZ /d 10 /f

REM NumLock on at logon
reg.exe add "HKU\DefaultUser\Control Panel\Keyboard" /v InitialKeyboardIndicators /t REG_SZ /d 2 /f

REM Mouse acceleration off (predictable cursor)
reg.exe add "HKU\DefaultUser\Control Panel\Mouse" /v MouseSpeed /t REG_SZ /d 0 /f
reg.exe add "HKU\DefaultUser\Control Panel\Mouse" /v MouseThreshold1 /t REG_SZ /d 0 /f
reg.exe add "HKU\DefaultUser\Control Panel\Mouse" /v MouseThreshold2 /t REG_SZ /d 0 /f

REM Suggested-app / promo spam off
for %%n in (ContentDeliveryAllowed FeatureManagementEnabled OEMPreInstalledAppsEnabled PreInstalledAppsEnabled PreInstalledAppsEverEnabled SilentInstalledAppsEnabled SoftLandingEnabled SubscribedContentEnabled SystemPaneSuggestionsEnabled) do reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v %%n /t REG_DWORD /d 0 /f

reg.exe unload "HKU\DefaultUser"

REM ============================================================================
REM Copy UserOnce.ps1 to a path that survives /oem cleanup, register RunOnce.
REM HKLM\...\RunOnce fires once at next logon (regardless of which user) — the
REM Docker user from compose USERNAME is the only account, so this lands in
REM their HKCU.
REM ============================================================================
if not exist "C:\Windows\Setup\Scripts" mkdir "C:\Windows\Setup\Scripts"
copy /y "C:\OEM\UserOnce.ps1" "C:\Windows\Setup\Scripts\UserOnce.ps1"
reg.exe add "HKLM\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "UnattendedUserOnce" /t REG_SZ /d "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:\Windows\Setup\Scripts\UserOnce.ps1\"" /f

REM ============================================================================
REM Debloat: AppX consumer apps + Print.Fax.Scan capability + Recall feature.
REM ============================================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\OEM\debloat.ps1"
SETUPEOF

sudo tee /etc/dockur-windows/oem/debloat.ps1 >/dev/null <<'DEBLOATEOF'
# Adapted from RemovePackages.ps1 + RemoveCapabilities.ps1 + RemoveFeatures.ps1
# of the pre-2026-04-27 autounattend.xml. Removes consumer AppX (Bing/Maps/Xbox
# etc.), Print.Fax.Scan capability, and the Recall feature (Win11 24H2's
# screenshot-everything thing). All non-VS-Enterprise-load-bearing.

$packages = @(
    'Microsoft.BingSearch'
    'MicrosoftCorporationII.MicrosoftFamily'
    'Microsoft.WindowsFeedbackHub'
    'Microsoft.Edge.GameAssist'
    'Microsoft.GetHelp'
    'Microsoft.Getstarted'
    'Microsoft.WindowsMaps'
    'Microsoft.MixedReality.Portal'
    'Microsoft.BingNews'
    'Microsoft.MicrosoftOfficeHub'
    'Microsoft.Office.OneNote'
    'Microsoft.OutlookForWindows'
    'Microsoft.People'
    'Microsoft.MicrosoftSolitaireCollection'
    'Microsoft.MicrosoftStickyNotes'
    'Microsoft.Todos'
    'Microsoft.Wallet'
    'Microsoft.BingWeather'
    'Microsoft.Xbox.TCUI'
    'Microsoft.XboxApp'
    'Microsoft.XboxGameOverlay'
    'Microsoft.XboxGamingOverlay'
    'Microsoft.XboxIdentityProvider'
    'Microsoft.XboxSpeechToTextOverlay'
    'Microsoft.GamingApp'
    'Microsoft.ZuneVideo'
)
$installed = Get-AppxProvisionedPackage -Online
foreach ($pkg in $packages) {
    $found = $installed | Where-Object DisplayName -EQ $pkg
    if ($found) {
        $found | Remove-AppxProvisionedPackage -AllUsers -Online -ErrorAction Continue
    }
}

# Capabilities
Get-WindowsCapability -Online | Where-Object {
    ($_.Name -split '~')[0] -eq 'Print.Fax.Scan' -and $_.State -ne 'NotPresent'
} | Remove-WindowsCapability -Online -ErrorAction Continue

# Optional features (Recall on Win11 24H2)
Get-WindowsOptionalFeature -Online | Where-Object {
    $_.FeatureName -eq 'Recall' -and $_.State -notin @('Disabled', 'DisabledWithPayloadRemoved')
} | Disable-WindowsOptionalFeature -Online -Remove -NoRestart -ErrorAction Continue
DEBLOATEOF

sudo tee /etc/dockur-windows/oem/UserOnce.ps1 >/dev/null <<'USERONCEEOF'
# Adapted from UserOnce.ps1 of the pre-2026-04-27 autounattend.xml. Fires at
# first logon via HKLM\...\RunOnce (registered by setup.cmd). HKCU tweaks that
# need an interactive user context — Default-hive equivalents wouldn't fire
# until profile creation, but RunOnce gives us the actual logged-in HKCU.

# Open File Explorer to "This PC" by default
Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Type DWord -Value 1

# Hide the taskbar search box (small icon only)
Set-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type DWord -Value 0

# Remove Edge desktop shortcut (created by Edge installer despite policies)
Remove-Item -LiteralPath "$env:USERPROFILE\Desktop\Microsoft Edge.lnk" -ErrorAction SilentlyContinue

# Restart explorer.exe to apply the taskbar / explorer changes immediately
Get-Process -Name 'explorer' -ErrorAction SilentlyContinue | Where-Object {
    $_.SessionId -eq (Get-Process -Id $PID).SessionId
} | Stop-Process -Force
USERONCEEOF

sudo chmod 644 \
    /etc/dockur-windows/compose.yaml \
    /etc/dockur-windows/oem/install.bat \
    /etc/dockur-windows/oem/setup.cmd \
    /etc/dockur-windows/oem/debloat.ps1 \
    /etc/dockur-windows/oem/UserOnce.ps1

# Kick off `docker compose up -d` NOW so the ~15-30 min Windows install runs
# inside the container in parallel with the rest of postinstall (yay AUR
# builds, fingerprint enrollment, chezmoi apply, etc.) instead of serially.
# `up -d` itself returns in seconds — the install proceeds asynchronously
# inside the dockur container. §15-windows below blocks at end-of-postinstall
# until container health=healthy.
#
# We use sudo because tom was just added to the docker group in §1a and
# group membership doesn't propagate to the current shell until logout/login.
# The sudo keeper (top of script) keeps the credential cache warm.
if (( SKIP_WINDOWS_INSTALL == 1 )); then
    log "Skipping early dockur bring-up (--skip-windows-install). To start later:"
    log "  sudo docker compose -f /etc/dockur-windows/compose.yaml up -d"
else
    log "Starting dockur/windows VM in background (install runs in parallel)..."
    sudo docker compose -f /etc/dockur-windows/compose.yaml up -d \
        || warn "docker compose up failed — see 'docker logs windows'."
fi

# ---------- 1a-tss. TPM access for tom (needed by pinutil) ----------
# /dev/tpmrm0 is mode 660 root:tss, so tom needs to be in the `tss`
# group to call pinutil without sudo. pinutil scopes the PIN to the
# effective user, so it MUST run as tom (not via sudo) for libpinpam.so
# to find the PIN at PAM time. See §7 for the rationale.
if ! id -nG tom | grep -qw tss; then
    sudo usermod -aG tss tom
    warn "Added tom to tss group — log out and back in for it to take effect (or pinutil setup will be skipped this run)."
fi

# ---------- 1a-numlock. Enable numlock at boot (covers greeter + TTY) ----------
# Hyprland's `numlock_by_default = true` only applies INSIDE the Hyprland
# session. greetd's regreet runs in `cage` before Hyprland and inherits
# whatever the kernel sets — typically OFF. Add a oneshot systemd service
# that runs `setleds +num` on each VT before greetd starts, so the greeter
# (and any TTY login) sees numlock already on. setleds is from the `kbd`
# package, in base.
log "Writing /etc/systemd/system/numlock-on.service (numlock at boot)..."
sudo tee /etc/systemd/system/numlock-on.service >/dev/null <<'NUMLOCKEOF'
[Unit]
Description=Enable Numlock on each TTY at boot
DefaultDependencies=no
After=systemd-vconsole-setup.service
Before=greetd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for tty in /dev/tty{1..6}; do /usr/bin/setleds -D +num < $tty 2>/dev/null || true; done'

[Install]
WantedBy=multi-user.target
NUMLOCKEOF
sudo systemctl daemon-reload
sudo systemctl enable numlock-on.service

# ---------- 1b. user services ----------
# hyprpolkitagent ships a user unit but the preset doesn't auto-activate on
# a fresh install — apps that need PolicyKit auth (Bitwarden unlock, mount
# prompts, etc.) silently fail until the service is registered on the
# session D-Bus. Idempotent: --now starts it here, enable persists across
# logins.
systemctl --user enable --now hyprpolkitagent.service 2>/dev/null || \
    warn "hyprpolkitagent.service enable failed — Bitwarden may flag system-auth as unavailable."

# ---------- 1c. memtest86+ limine entry ----------
# Arch splits memtest86+ into two packages: `memtest86+` ships only the BIOS
# binary (memtest.bin), `memtest86+-efi` ships the UEFI binary (memtest.efi).
# Metis boots UEFI via limine, so the EFI package is the one we need. We
# append a /Memtest86+ entry to /boot/limine.conf (chained as efi_chainload).
# Idempotent: only appends if the entry isn't already there.
MEMTEST_EFI=$(pacman -Ql memtest86+-efi 2>/dev/null | awk '/\.efi$/ {print $2; exit}')
if [[ -n "$MEMTEST_EFI" ]] && sudo test -f "$MEMTEST_EFI"; then
    # Strip the /boot prefix — limine's boot():… is ESP-relative.
    MEMTEST_EFI_REL="${MEMTEST_EFI#/boot}"
    if sudo test -f /boot/limine.conf && ! sudo grep -qE '^/Memtest86\+' /boot/limine.conf; then
        log "Adding memtest86+ entry to /boot/limine.conf..."
        sudo tee -a /boot/limine.conf >/dev/null <<MEMEOF

/Memtest86+
    protocol: efi_chainload
    image_path: boot():${MEMTEST_EFI_REL}
MEMEOF
    fi
else
    warn "memtest86+-efi EFI binary not found — limine entry skipped. Did pacman -S memtest86+-efi succeed?"
fi

# ---------- 1d. tablet-mode auto-detection (Inspiron 7786 2-in-1) ----------
# Implemented as a user-level systemd service running an angle-polling
# daemon — see rhombu5/dots:
#   dot_local/bin/executable_tablet-mode-watcher
#   dot_config/systemd/user/tablet-mode-watcher.service
# The daemon polls the HID sensor hub's `hinge` IIO channel at 10 Hz,
# applies ±10° hysteresis around 180° (>190° → tablet, <170° → laptop), shells out
# to ~/.local/bin/tablet-mode-toggle on each transition. No udev rule
# is needed (and one wouldn't work — empirically the kernel doesn't
# emit udev events for EV_SW value changes on existing input devices,
# and the firmware-set SW_TABLET_MODE threshold is ~360° not 180°).
# See docs/tablet-mode-investigation.md for the trace.
#
# Nothing to install at this point in postinstall — chezmoi (§13) lays
# down both the script and the unit file. The service enable lives in
# §13a, after chezmoi apply.

# ---------- 1e. Suppress benign systemd-tpm2-setup.service failure ----------
# systemd ships TWO TPM2 setup services that run at boot:
#   - systemd-tpm2-setup-early.service: initializes the SRK in the TPM
#     and writes the public-key file under /run/. SUCCEEDS on this hardware
#     (with a warning that the TPM lacks a SHA256 PCR bank, falls back to SHA1).
#   - systemd-tpm2-setup.service:       persists the SRK to /var/, then
#     attempts to unseal a "machine identity secret" if one was previously
#     stored. On a fresh install nothing was sealed, so the unseal attempt
#     fails with "No such device or address" and the service exits 1.
#     This produces a noisy red 'Failed to start TPM SRK Setup' line right
#     before greetd.
#
# The unseal failure is benign — our LUKS unlock uses systemd-cryptsetup
# against /etc/crypttab.initramfs (with TPM2-bound recovery key), which is
# completely independent of systemd's machine-identity feature. systemd-
# tpm2-setup{,-early} are not on any boot dependency path we use; the
# failure is purely cosmetic. Mask the late variant to silence it without
# changing any actual security posture.
# References:
#   - man systemd-tpm2-setup.service
#   - https://github.com/systemd/systemd/blob/main/src/tpm2-setup/tpm2-setup.c
log "Masking systemd-tpm2-setup.service (benign unseal failure on fresh install)..."
sudo systemctl mask systemd-tpm2-setup.service

# ---------- 1f. Disable greetd in favour of TTY login ----------
# Decision (2026-04-30): greetd + ReGreet didn't earn its keep — slow VT
# handoff, regreet's GTK chrome looks awkward on a 17" panel, and the
# auth flow gives no visibility into what's failing when fprintd doesn't
# match. Disable the service; the user logs in at tty1 (with optional
# fingerprint via the same fprintd PAM stack as sudo) and runs `Hyprland`
# when they want a session.
#
# We keep greetd + greetd-regreet INSTALLED in case we want to flip back
# (the PAM stacks at /etc/pam.d/greetd and /etc/greetd/config.toml stay).
# To re-enable: `sudo systemctl enable --now greetd.service`.
#
# To auto-launch Hyprland on tty1 login, add to ~/.zprofile (chezmoi can
# manage this — see dot_zprofile in rhombu5/dots if shipped):
#   if [[ $(tty) == /dev/tty1 && -z $DISPLAY && -z $WAYLAND_DISPLAY ]]; then
#       exec Hyprland
#   fi
log "Disabling greetd.service (TTY login mode)..."
sudo systemctl disable greetd.service 2>/dev/null || true

# ---------- 2. yay bootstrap ----------
if ! command -v yay >/dev/null; then
    log "Bootstrapping yay from AUR..."
    TMP=$(mktemp -d)
    retry git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$TMP/yay-bin"
    pushd "$TMP/yay-bin" >/dev/null
    makepkg -si --noconfirm
    popd >/dev/null
    rm -rf "$TMP"
fi

# ---------- 3. AUR: only what's not in extra ----------
# claude-desktop-native: unofficial repackage of Anthropic's Windows Electron
# build (Anthropic ships no official Linux binary). `-native` variant is the
# community-recommended one — `-bin` has recurring ffmpeg dep issues. Lags
# official releases; expect occasional breakage on Anthropic updates.
log "Installing AUR-exclusive apps (VSCode, Edge, Claude, awww, matugen, overskride, wleave, Bibata, wvkbd, pinpam, iio-hyprland, powershell)..."
# Verified existence on AUR 2026-04-23 — package names below are the
# actual AUR slugs, NOT the upstream project names.
#
# Notes per package:
#   - awww-bin       — continuation of archived swww (LGFae, Codeberg);
#                      provides=awww so binaries `awww` + `awww-daemon`
#                      end up on PATH.
#   - sesh-bin       — was once available as bare `sesh` somewhere;
#                      currently AUR-only as `sesh-bin`.
#   - wvkbd          — moved here from §1 pacman: NOT in extra, AUR-only.
#   - bibata-cursor-theme  — Xcursor format. Used as Xwayland fallback.
#   - hyprcursor-format Bibata: NO clean AUR package as of 2026-04. The
#     LOSEARDES77/Bibata-Cursor-hyprcursor github repo is the source;
#     install manually via:
#       git clone https://github.com/LOSEARDES77/Bibata-Cursor-hyprcursor ~/.icons/Bibata-hyprcursor
#     Until then, Hyprland falls back to the Xcursor build (works fine,
#     just larger ~44 MB resident vs ~6.6 MB hyprcursor).
# Per-package install (vs one batched yay -S call) so that one bad apple
# doesn't abort the whole list — common AUR failure modes (source-vs-bin
# variant conflicts, transient build breaks, key-rotation PGP fails) are
# all per-package. A failure prints a warning and the loop continues;
# the verify block at the end will list any missing tool as FAIL so
# nothing slips through silently.
AUR_PACKAGES=(
    visual-studio-code-bin
    microsoft-edge-stable-bin
    claude-desktop-native
    # dropbox: official Dropbox Linux daemon. Tray icon under Wayland is
    # degraded (post-May-2025 AppIndicator mandate), but sync still works.
    # `dropbox-cli` is a separate AUR pkg providing the `dropbox` Python CLI
    # for status/control from the terminal — pairs with the daemon.
    dropbox
    dropbox-cli
    # pinpam-git: replaced by pinpam-fnrhombus in §3-overrides below (carries
    # a try_first_pass / use_first_pass patch needed by §7a's concurrent
    # PAM stack). Drop the override and restore pinpam-git here when
    # upstream merges the patch — see runbook/post-reinstall-followups.md.
    sesh-bin
    wvkbd
    iio-hyprland-git
    powershell-bin
    awww-bin
    hyprlax-bin
    matugen-bin
    overskride
    wleave
    hyprshutdown
    # physlock: TTY-based screen lock. dots' hypridle.conf invokes this
    # as the lock_cmd (replaced hyprlock 2026-05-05). /etc/pam.d/physlock
    # is written in §7a below to include the hyprlock auth stack.
    physlock
    bibata-cursor-theme
    # Meta package — pulls in every ttf-*-nerd variant from extra/. The
    # explicit ttf-jetbrains-mono-nerd / ttf-firacode-nerd in §1's pacman
    # list stay as a safety net if AUR is unreachable on first run.
    ttf-nerd-fonts-meta
    pacseek
    limine-snapper-sync
    # azure-ddns intentionally NOT here — see §4d below. We build the
    # versioned aur/azure-ddns/PKGBUILD from the source tree (no yay
    # cache hop) so the install is hermetic to the repo checkout.
    # NVIDIA compute-only stack for the MX250 (Pascal, compute capability 6.1).
    # Display modules are blacklisted in chroot.sh; these pull in the kernel
    # driver + nvidia-smi/CUDA runtime libs for bare-metal CUDA workloads
    # (PyTorch, ffmpeg NVENC, etc.). nvidia-container-toolkit (§1) wires the
    # runtime into Docker so containers can `docker run --gpus all ...`
    # without an additional driver install in the image. Note: the MX250 is
    # Pascal, so use container images with CUDA ≤11.x for actual GPU
    # acceleration — newer CUDA-12 images compile-out Pascal kernels.
    nvidia-470xx-dkms
    nvidia-470xx-utils
    # WinApps is NOT on AUR (verified empty `winapps` search 2026-04-29). The
    # earlier `winapps-git` AUR pkg referenced an upstream that has since
    # migrated from Fmstrat/winapps to winapps-org/winapps. We install it
    # from upstream source in §3-winapps below — clone-and-symlink, no AUR.
)
# yay -S --needed exits 0 even when its AUR RPC query EOFs out — it
# treats "couldn't query AUR" as "package not selected, nothing to do"
# and reports success. So we have to inspect output: if we see the
# specific RPC-failure markers, treat it as failure and let retry_soft
# kick in. Tee preserves live output to the user's terminal so progress
# is still visible during the build.
yay_install_one() {
    local pkg="$1"
    local logf
    logf=$(mktemp -t yay-install-XXXXXX.log)
    yay -S --noconfirm --needed "$pkg" 2>&1 | tee "$logf"
    local rc=${PIPESTATUS[0]}
    if grep -qE 'request failed.*EOF|Failed to find AUR package for|No AUR package found' "$logf"; then
        rm -f "$logf"
        return 1
    fi
    rm -f "$logf"
    return "$rc"
}

AUR_FAILED=()
for pkg in "${AUR_PACKAGES[@]}"; do
    # retry_soft: 4 attempts on AUR RPC EOF, then warn and continue.
    if ! retry_soft yay_install_one "$pkg"; then
        AUR_FAILED+=("$pkg")
    fi
done
if (( ${#AUR_FAILED[@]} > 0 )); then
    warn "AUR install failures: ${AUR_FAILED[*]}"
    warn "Resolve manually (often: 'pacman -R <conflicting-variant>' then 'yay -S <pkg>'), then re-run this script."
fi

# ---------- 3-overrides. Fork-pinned AUR packages built from in-repo PKGBUILDs ----------
# Two AUR packages need patches that haven't landed upstream:
#   pinpam-fnrhombus              — adds try_first_pass / use_first_pass
#                                   to libpinpam (upstream PR pending).
#   pam-fprint-grosshack-fnrhombus — 1-line sed: reset the per-call SIGUSR1
#                                   flag so sudo's retry loop is intact
#                                   (upstream effectively abandoned 2022-07).
# Both are required for §7a's concurrent fingerprint+PIN+password PAM stack.
# Build via local makepkg (yay can't, since the PKGBUILDs aren't on AUR),
# install via pacman -U. provides=(...) lets dependents see the upstream name.
# When upstream releases land, drop the override here and revert to AUR
# (see runbook/post-reinstall-followups.md for the per-package recipe).
log "Building fork-pinned AUR overrides..."
for _override in pinpam-fnrhombus pam-fprint-grosshack-fnrhombus; do
    _ovr_dir="$SCRIPT_DIR/aur-overrides/$_override"
    if [[ ! -f "$_ovr_dir/PKGBUILD" ]]; then
        warn "  $_override: PKGBUILD missing at $_ovr_dir — skipping"
        continue
    fi
    log "  $_override: makepkg from $_ovr_dir"
    pushd "$_ovr_dir" >/dev/null
    if makepkg -sf --noconfirm --noprogressbar 2>&1; then
        # provides=(upstream-name) means we may collide with an installed
        # upstream pkg; remove it first if present so pacman -U doesn't
        # default-N the conflict prompt.
        _upstream=$(awk -F'[()]' '/^provides=/ {print $2}' PKGBUILD | tr -d "'\"" | awk '{print $1}')
        if [[ -n "$_upstream" ]] && pacman -Qq "$_upstream" >/dev/null 2>&1 && [[ "$_upstream" != "$_override" ]]; then
            log "    removing conflicting upstream pkg: $_upstream"
            sudo pacman -Rdd --noconfirm "$_upstream" || true
        fi
        sudo pacman -U --noconfirm ./"$_override"-*.pkg.tar.zst \
            || warn "  $_override: pacman -U failed"
    else
        warn "  $_override: makepkg failed"
    fi
    popd >/dev/null
done
unset _override _ovr_dir _upstream

# ---------- 3-winapps. WinApps from upstream (winapps-org/winapps) ----------
# WinApps lets you launch Windows apps from a Win11 VM as native Hyprland
# windows via RDP — the Parallels-Coherence equivalent. The VM itself is
# the dockur/windows container defined in §1a-dockur (compose at
# /etc/dockur-windows/compose.yaml); WinApps just talks to its RDP port.
#
# WinApps is NOT on AUR (the prior `winapps-git` package referenced
# Fmstrat/winapps which has migrated to winapps-org/winapps). We install
# from upstream source: clone to /opt/winapps, symlink the setup script
# onto PATH, and write ~/.config/winapps/winapps.conf with WAFLAVOR=docker
# so winapps-setup talks to the dockur container instead of libvirt.
#
# Idempotent: subsequent runs `git pull` to refresh; the symlink is
# unconditional (ln -sf); the conf file is rewritten each run.
log "Installing WinApps from upstream (winapps-org/winapps)..."
if [[ ! -d /opt/winapps/.git ]]; then
    sudo git clone --depth 1 https://github.com/winapps-org/winapps.git /opt/winapps \
        || warn "WinApps clone failed — re-run later or install manually."
else
    sudo git -C /opt/winapps pull --ff-only >/dev/null 2>&1 || \
        warn "WinApps repo update failed — keeping existing checkout."
fi
if [[ -x /opt/winapps/setup.sh ]]; then
    sudo ln -sf /opt/winapps/setup.sh /usr/local/bin/winapps-setup
fi

# Write WinApps config pointing at the dockur container. RDP creds match
# the compose USERNAME/PASSWORD; IP is loopback because compose binds
# 3389 to 127.0.0.1 only.
install -d -m 755 "$XDG_CONFIG_HOME/winapps"
cat >"$XDG_CONFIG_HOME/winapps/winapps.conf" <<'WACONFEOF'
# Auto-written by postinstall §3-winapps. Edit if you change the dockur
# compose USERNAME/PASSWORD or the port bindings.
RDP_USER="Docker"
RDP_PASS="Docker"
RDP_DOMAIN=""
RDP_IP="127.0.0.1"
WAFLAVOR="docker"
WACONFEOF
log "  WinApps installed (backend=docker). Run 'winapps-setup --user' once the dockur VM is up to wire desktop entries."

# ---------- 3-edge. Microsoft Edge: suppress OOBE / welcome / sign-in nags ----------
# Edge's default first-launch flow drops the user into a multi-page welcome
# wizard ("Make Edge yours" → sign-in prompt → choose appearance → import →
# pin to taskbar) BEFORE navigating to whatever URL xdg-open passed it.
# That broke the user during `gh auth login`: the device-code URL was
# requested, but Edge stayed on edge://welcome-edge until OOBE finished.
#
# Managed-policy file at /etc/opt/edge/policies/managed/ short-circuits
# all of that. HideFirstRunExperience is the single most important key;
# the others suppress nags that show up later (sign-in pop-ups, telemetry
# banners, Microsoft Rewards promos, etc).
#
# Policy reference:
#   https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies
if pacman -Q microsoft-edge-stable-bin >/dev/null 2>&1; then
    log "Writing Edge managed policy (suppress OOBE / sign-in / promos)..."
    sudo install -d -m 755 /etc/opt/edge/policies/managed
    sudo tee /etc/opt/edge/policies/managed/arch-setup.json >/dev/null <<'EDGEPOLICYEOF'
{
    "HideFirstRunExperience": true,
    "DefaultBrowserSettingEnabled": true,
    "BrowserSignin": 1,
    "RestoreOnStartup": 1,
    "SyncDisabled": false,
    "MetricsReportingEnabled": false,
    "PersonalizationReportingEnabled": false,
    "PromotionalTabsEnabled": false,
    "ShowMicrosoftRewards": false,
    "PromotionsEnabled": false
}
EDGEPOLICYEOF
fi

# ---------- 3a. lego (Let's Encrypt cert issuance via Azure DNS) ----------
# certbot was the original plan. It died on Python 3.14 — josepy 1.15's
# metaclass-based JSONObjectWithFields broke under PEP 749 (deferred
# annotations), and the upgrade path (josepy 2.x) removed
# `ComparableX509`, which certbot 3.3.0 still calls. Beyond that,
# `certbot-dns-azure` is PyPI-only and required a pipx-managed venv
# with a pinned `azure-mgmt-dns<9` because the plugin hadn't migrated
# to the 9.x DnsManagementClient signature. Total of ~40 lines of
# dependency wrangling on top of certbot's own complexity.
#
# `lego` (extra/lego) is a single static Go binary with first-class
# Azure DNS support — no Python in the loop, no plugin venvs, no
# version pins. Installed via pacman in §1; here we wire up the
# renewal pipeline. The cert itself is issued during setup-azure-ddns
# (after `az login`); this block only sets up the systemd-driven
# renewal so a fresh install has the timer ready when the user
# eventually issues their first cert.
log "Setting up lego renewal pipeline..."
sudo install -d -m 750 -o root -g root /etc/lego
# /etc/lego/lego.env is written by setup-azure-ddns.sh — service starts
# disabled until that file exists.
LEGO_EMAIL="${LEGO_EMAIL:-goliyth@gmail.com}"
LEGO_DOMAINS="${LEGO_DOMAINS:-metis.rhombus.rocks}"

sudo tee /etc/systemd/system/lego-renew.service >/dev/null <<LEGOSVC
[Unit]
Description=Renew Let's Encrypt certs via lego (Azure DNS)
After=network-online.target azure-ddns.service
Wants=network-online.target
ConditionPathExists=/etc/lego/lego.env

[Service]
Type=oneshot
EnvironmentFile=/etc/lego/lego.env
ExecStart=/usr/bin/lego --accept-tos \\
    --email ${LEGO_EMAIL} \\
    --domains ${LEGO_DOMAINS} \\
    --dns azuredns \\
    --path /etc/lego \\
    renew --days 30
# Reload nginx/whatever after a successful renewal. No-op if the unit
# isn't installed.
ExecStartPost=-/bin/systemctl reload nginx.service
LEGOSVC

sudo tee /etc/systemd/system/lego-renew.timer >/dev/null <<'LEGOTMR'
[Unit]
Description=Daily Let's Encrypt cert renewal check via lego

[Timer]
OnCalendar=daily
RandomizedDelaySec=12h
Persistent=true

[Install]
WantedBy=timers.target
LEGOTMR

sudo systemctl daemon-reload
sudo systemctl enable lego-renew.timer >/dev/null 2>&1 || true

# ---------- 4. (no local SSH keygen — Bitwarden SSH agent holds keys) ----------
# Keys live in the Bitwarden vault as "SSH key" items and surface via
# ~/.bitwarden-ssh-agent.sock once Bitwarden desktop is running with the
# SSH-agent toggle enabled. Public keys are readable via `ssh-add -L`.
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"

# ---------- 4a. sshd: accept incoming connections, key-only ----------
# Hardened sshd drop-in: pubkey only, no root, no passwords, no kbd-interactive.
log "Installing sshd hardened drop-in and enabling sshd..."
sudo install -d -m 755 /etc/ssh/sshd_config.d
sudo tee /etc/ssh/sshd_config.d/10-arch-setup.conf >/dev/null <<'SSHDEOF'
# arch-setup: hardened sshd policy (key-only, no root, no passwords)
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
PrintMotd no
AllowUsers tom
SSHDEOF
sudo systemctl enable --now sshd.service

# ---------- 4b. Callisto authorized key ----------
# Hardcoded public half of the user's "Callisto" Bitwarden vault SSH key.
# Public keys are non-secret; private half stays in Bitwarden, surfaces via
# the Bitwarden SSH agent socket on the originating box. Idempotent append.
CALLISTO_PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmgv+3Enh89mb5vutzHEgwzKitOzdrje8lQVF/bss/X thoma@callisto'
if ! grep -qxF "$CALLISTO_PUBKEY" "$HOME/.ssh/authorized_keys"; then
    log "Adding Callisto pubkey to authorized_keys..."
    echo "$CALLISTO_PUBKEY" >> "$HOME/.ssh/authorized_keys"
fi

# ---------- 4c. ufw: host firewall (IPv4 + IPv6) ----------
# IPv6 puts every device on a globally routable address, so the router's
# all-or-nothing IPv6 filter for this host means anything bound to a port
# on the laptop is exposed to the internet when IPv6 is "on" at the router.
# ufw is the simplest IPv4+IPv6-aware firewall: rules apply to both stacks.
# Order is load-bearing: add allow rules BEFORE `ufw --force enable` so a
# remote re-run (over SSH) can't lock itself out. Idempotent — `ufw enable`
# on an already-active firewall is a no-op, and `ufw allow` won't dupe.
log "Configuring ufw (deny incoming, allow ssh) and enabling..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'sshd (Callisto + others)'
sudo ufw --force enable
sudo systemctl enable --now ufw.service

# Disable any leftover keyd from the previous Super-tap-to-launcher
# attempt (mapping leftmeta -> overload(meta, f20) made F20 trigger the
# volume OSD on this hardware — root cause unclear, see git history
# for rationale). Idempotent: no-op if the unit was never installed.
sudo systemctl disable --now keyd.service 2>/dev/null || true
sudo rm -f /etc/keyd/default.conf

# ---------- 4d. azure-ddns: build versioned package + enable timer ----------
# Keeps metis.rhombus.rocks A+AAAA records pointed at this host's current
# public IPv4/IPv6. Build the versioned `aur/azure-ddns/PKGBUILD` checked
# into the repo (matches the AUR's published copy of `azure-ddns`). The
# `-git` flavor at `aur/azure-ddns-git/PKGBUILD` is kept around for users
# who want HEAD-tracking, but our default is the tagged release so
# install-time output is reproducible and `pacman -Q` shows a real version.
#
# The package ships:
#   /usr/bin/azure-ddns
#   /usr/lib/systemd/system/azure-ddns.{service,timer}
#   /usr/lib/NetworkManager/dispatcher.d/90-azure-ddns
#   /etc/azure-ddns.env (template; mode 600, root-owned, placeholder values)
#
# `setup-azure-ddns.sh` (staged at /home/tom/) does the Azure-side
# provisioning + writes real values into /etc/azure-ddns.env. We just
# enable the timer here; first tick no-op-fails until creds are filled in,
# which is fine — we just don't want a FAILED state screaming at first boot.
log "Building azure-ddns from aur/azure-ddns/PKGBUILD..."
AZDDNS_BUILD=$(mktemp -d)
trap "rm -rf '$AZDDNS_BUILD'" RETURN 2>/dev/null || true
if retry git clone --depth 1 https://github.com/fnrhombus/azure-ddns "$AZDDNS_BUILD/azure-ddns"; then
    pkgdir="$AZDDNS_BUILD/azure-ddns/aur/azure-ddns"
    if [[ -f "$pkgdir/PKGBUILD" ]]; then
        pushd "$pkgdir" >/dev/null
        # -f forces overwrite of any existing built tarball; -i installs;
        # --noconfirm avoids prompts. --needed is intentionally OMITTED so
        # we always rebuild against latest source.
        if ! makepkg -si --noconfirm --force; then
            warn "azure-ddns: makepkg -si failed; falling back to AUR's published azure-ddns."
            popd >/dev/null
            retry_soft yay -S --noconfirm --rebuild --noprovides azure-ddns || \
                warn "azure-ddns: AUR fallback also failed. Run setup-azure-ddns.sh anyway — it'll surface the missing pieces."
        else
            popd >/dev/null
        fi
    else
        warn "azure-ddns: aur/azure-ddns/PKGBUILD missing in repo checkout; falling back to AUR."
        retry_soft yay -S --noconfirm --rebuild --noprovides azure-ddns || true
    fi
else
    warn "azure-ddns: git clone failed; falling back to AUR."
    retry_soft yay -S --noconfirm --rebuild --noprovides azure-ddns || true
fi
rm -rf "$AZDDNS_BUILD"

log "Enabling azure-ddns timer (real creds filled in by setup-azure-ddns.sh)..."
sudo install -d -m 755 /var/lib/azure-ddns
sudo systemctl daemon-reload
sudo systemctl enable azure-ddns.timer

# Stub /etc/letsencrypt/azure.ini for certbot's dns-azure plugin (same SP
# creds as the DDNS daemon — DNS Zone Contributor covers both record
# updates and dns-01 challenge TXT records). setup-azure-ddns.sh rewrites
# this with real values; until then certbot-renew.timer no-ops.
sudo install -d -m 755 /etc/letsencrypt
if [[ ! -f /etc/letsencrypt/azure.ini ]]; then
    sudo tee /etc/letsencrypt/azure.ini >/dev/null <<'CERTBOTEOF'
# /etc/letsencrypt/azure.ini — credentials for certbot's dns-azure plugin.
# mode 600, owner root. NEVER commit this file with real values.
#
# Mirror values from /etc/azure-ddns.env after setup-azure-ddns.sh runs.
#
# Issuance command (one-time, after DNS is live):
#   sudo certbot certonly \
#       --authenticator dns-azure \
#       --dns-azure-credentials /etc/letsencrypt/azure.ini \
#       --dns-azure-propagation-seconds 60 \
#       -d metis.rhombus.rocks \
#       --agree-tos -m <your-email> --no-eff-email
#
# Renewal: certbot installs certbot-renew.timer that runs `certbot renew`
# twice daily. Idempotent — only acts within 30d of expiry.

dns_azure_environment = "AzurePublicCloud"
dns_azure_tenant_id =
dns_azure_subscription_id =
dns_azure_resource_group =
dns_azure_sp_client_id =
dns_azure_sp_client_secret =
CERTBOTEOF
    sudo chmod 600 /etc/letsencrypt/azure.ini
    sudo chown root:root /etc/letsencrypt/azure.ini
fi
sudo systemctl enable certbot-renew.timer 2>/dev/null || true

# ---------- 5. Claude Code CLI ----------
# Two-stage install:
#   (a) bootstrap via mise+npm — gets us a working `claude` binary
#   (b) `claude install` (native) — migrates to ~/.claude/local/, which is
#       user-owned. Without this, `claude doctor` warns:
#         "Insufficient permissions for auto-updates"
#       because the npm-installed binary lives under a path the auto-update
#       checker can't write to (mise prefix or symlinked into /usr/local/bin).
#
# After (b), the npm-installed copy is harmless leftovers — `claude install`
# rewrites .bashrc/.zshrc to point at ~/.claude/local/claude. We keep the
# /usr/local/bin/claude symlink as a fallback for non-interactive shells
# (sudo, scripts) until the user verifies the native install resolves cleanly.
if ! command -v claude >/dev/null; then
    if command -v mise >/dev/null; then
        log "Installing node@lts via mise, then Claude Code via npm (bootstrap)..."
        if ! mise use -g node@lts >>/tmp/mise-node.log 2>&1; then
            warn "mise node@lts install failed — tail of /tmp/mise-node.log:"
            tail -n 10 /tmp/mise-node.log >&2 || true
        fi
        if ! mise exec -- npm install -g @anthropic-ai/claude-code >>/tmp/mise-node.log 2>&1; then
            warn "Claude Code install failed — tail of /tmp/mise-node.log:"
            tail -n 10 /tmp/mise-node.log >&2 || true
            warn "Retry manually: mise use -g node@lts && mise exec -- npm i -g @anthropic-ai/claude-code"
        fi
    else
        warn "mise missing; skipping Claude Code CLI install."
    fi
fi
# Ensure claude resolves globally (outside mise-activated shells too). Re-run
# every time so a node version bump silently refreshes the symlink target.
if claude_bin=$(mise which claude 2>/dev/null) && [[ -x "$claude_bin" ]]; then
    sudo ln -sf "$claude_bin" /usr/local/bin/claude
fi
# Migrate to native install so auto-updates work without sudo.
# `claude install` is idempotent: re-running on an already-native install
# is a no-op. Pipe 'y' to auto-confirm any prompts (the command was
# stabilized to non-interactive accept by 2.1.x).
if command -v claude >/dev/null && [[ ! -d "$HOME/.claude/local" ]]; then
    log "Migrating Claude Code to native install (unprivileged auto-updates)..."
    if ! printf 'y\n' | claude install >/tmp/claude-install.log 2>&1; then
        warn "claude install failed — tail of /tmp/claude-install.log:"
        tail -n 10 /tmp/claude-install.log >&2 || true
        warn "Run 'claude install' manually to fix the doctor's auto-update warning."
    fi
fi
# Claude Code ships its own completions at runtime: `claude --print-completion zsh`
# is wired in .zshrc below, no fragile external download needed.

# ---------- 6. Fingerprint enrollment (Goodix-aware) ----------
# Known unsupported Goodix PIDs (Match-On-Chip variants — require proprietary
# vendor firmware/driver, not covered by stock libfprint OR libfprint-git).
# Listing them up front lets us skip the enroll→diagnose→AUR-fallback dance
# entirely on re-runs for hardware that will never work.
# 538C lives in libfprint-goodix-53xc (older Dell blob); handled below.
GOODIX_UNSUPPORTED_PIDS='5395|55b4|600c|639c'
if [[ -z "${SKIP_FPRINT:-}" ]]; then
    if command -v lsusb >/dev/null && lsusb | grep -qiE "27c6:($GOODIX_UNSUPPORTED_PIDS)"; then
        warn "Goodix reader ($(lsusb | grep -iE "27c6:($GOODIX_UNSUPPORTED_PIDS)" | head -1 | awk '{print $6}')) is a Match-On-Chip variant with no open-source driver."
        warn "Skipping fingerprint setup. Set SKIP_FPRINT=1 on re-runs to suppress this message."
        warn "Status reference: https://fprint.freedesktop.org/supported-devices.html"
        SKIP_FPRINT=1
    fi
fi

# Pre-install correct driver for known-mapped Goodix PIDs so the enroll-below
# succeeds first try. 538C → libfprint-goodix-53xc (older Dell blob via TOD),
# which declares Depends On: libfprint-tod (the released AUR pkg, NOT -git —
# an earlier revision of this script tried to pre-build libfprint-tod-git
# from AUR, but that PKGBUILD has a chronic LTO / symbol-versioning failure
# and the released libfprint-tod is what goodix-53xc actually wants). The
# released libfprint-tod replaces stock libfprint, so we pull stock first
# to keep yay from prompting under --noconfirm.
if [[ -z "${SKIP_FPRINT:-}" ]] && command -v lsusb >/dev/null && lsusb | grep -qi '27c6:538c'; then
    if command -v fprintd-list >/dev/null && sudo fprintd-list tom 2>/dev/null | grep -qi 'finger'; then
        log "Goodix 538C detected, fingerprints already enrolled — skipping driver swap."
    else
        log "Goodix 538C detected — installing libfprint-goodix-53xc (depends on libfprint-tod)..."
        if pacman -Q libfprint >/dev/null 2>&1 && ! pacman -Q libfprint-tod >/dev/null 2>&1; then
            sudo pacman -Rdd --noconfirm libfprint || warn "Could not remove stock libfprint."
        fi
        retry_soft yay -S --noconfirm --needed libfprint-goodix-53xc || \
            warn "libfprint-goodix-53xc install failed — see AUR comments."
    fi
fi
if [[ -z "${SKIP_FPRINT:-}" ]]; then
    GOODIX_PRESENT=0
    if command -v lsusb >/dev/null && lsusb | grep -qi '27c6:'; then
        GOODIX_PRESENT=1
        log "Goodix fingerprint reader detected: $(lsusb | grep -i '27c6:' | head -1)"
    fi

    # sudo + explicit user: bypasses polkit which denies enroll from a bare TTY
    # (no graphical session = no active-local seat). Idempotent: skip already-enrolled
    # fingers so re-runs don't force re-touching.
    FINGERS_TO_ENROLL=(right-index-finger left-index-finger right-middle-finger left-middle-finger right-thumb)
    log "Enrolling ${#FINGERS_TO_ENROLL[@]} fingerprints (~13 scans each)..."
    fp_any_success=0
    for finger in "${FINGERS_TO_ENROLL[@]}"; do
        if sudo fprintd-list tom 2>/dev/null | grep -q "$finger"; then
            log "  $finger: already enrolled — skipping."
            fp_any_success=1
            continue
        fi
        log "  $finger: touch power button ~13 times..."
        if sudo fprintd-enroll -f "$finger" tom 2>&1 | tee /tmp/fprint-enroll.log; then
            fp_any_success=1
        else
            warn "  $finger: enroll failed (rc=${PIPESTATUS[0]})."
        fi
    done
    if (( ! fp_any_success )); then
        warn "fprintd-enroll failed for all fingers. Diagnostic:"
        echo "----- lsusb (full) -----"
        lsusb 2>&1 || true
        echo "----- fingerprint candidates (Goodix/Validity/Synaptics/Elan/AuthenTec) -----"
        lsusb | grep -iE '27c6:|138a:|06cb:|04f3:|08ff:' || \
            echo "  (no known fingerprint-vendor device visible — reader may be disabled in BIOS, or on a bus we don't recognize)"
        echo "----- fprintd-list tom -----"
        fprintd-list tom 2>&1 || true
        echo "----- last 20 lines of /tmp/fprint-enroll.log -----"
        tail -n 20 /tmp/fprint-enroll.log 2>/dev/null || true
        echo "-----"
        if (( GOODIX_PRESENT )); then
            echo "Goodix detected (VID 27C6) but enrollment failed. Stock libfprint may lag your PID."
        else
            echo "Reader vendor unknown/unrecognized — stock libfprint may still work with a retry,"
            echo "or your reader may be newer than the packaged libfprint."
        fi
        # If libfprint-tod is already in (e.g. 538C path above), libfprint-git
        # would conflict — skip the fallback and surface a manual diagnostic hint.
        if pacman -Q libfprint-tod >/dev/null 2>&1; then
            warn "libfprint-tod is installed (Goodix-specific path) — skipping libfprint-git fallback."
            warn "Check: journalctl -u fprintd -n 50; lsusb | grep 27c6; ls /usr/lib/libfprint-2/tod-1/"
        else
            log "Falling back to libfprint-git from AUR (covers newer PIDs for all vendors)..."
            # libfprint-git conflicts with stock libfprint; pacman's "Remove libfprint? [y/N]"
            # prompt defaults to N under --noconfirm, so the install aborts. Pull the
            # stock package out first (-Rdd bypasses reverse-dep check; fprintd will
            # briefly have no provider until libfprint-git re-provides it below).
            # Only attempt removal if stock libfprint is actually installed AND
            # libfprint-git isn't already taking its place (avoids "target not found"
            # noise on re-runs where the swap already happened).
            if pacman -Q libfprint >/dev/null 2>&1 && ! pacman -Q libfprint-git >/dev/null 2>&1; then
                sudo pacman -Rdd --noconfirm libfprint || warn "Could not remove stock libfprint — conflict will still block install."
            fi
            if retry_soft yay -S --noconfirm --needed libfprint-git && sudo systemctl restart fprintd; then
                sudo fprintd-enroll -f right-index-finger tom || warn "libfprint-git retry also failed — likely unsupported reader. See https://fprint.freedesktop.org/supported-devices.html"
            else
                warn "libfprint-git install failed — see https://fprint.freedesktop.org/supported-devices.html"
            fi
        fi
    fi
fi

# ---------- 7. pinpam TPM-PIN setup ----------
# pinutil setup asks for a fresh PIN and stores it in TPM NVRAM,
# scoped to the EFFECTIVE USER running the command (per `pinutil --help`:
# "Set up a new PIN (root or user for self)"). At PAM time, libpinpam.so
# looks up the PIN keyed to PAM_USER (tom for `sudo -v`), so the PIN
# MUST be set for tom — NOT for root. Earlier versions of this section
# used `sudo pinutil setup`, which (because postinstall already runs as
# tom and `sudo` elevates to root) stored the PIN for root and made
# `sudo -v` later report "PIN authentication is not configured".
#
# Prereq: tom must be in the `tss` group to access /dev/tpmrm0 directly,
# without root. Postinstall §1 below adds tom to tss; verify with
# `groups | grep -w tss`. New-group membership only takes effect on the
# NEXT login, so the very first postinstall run after the install may
# need to be re-run from a fresh shell — or the user can run pinutil
# manually after logging out and back in.
#
# PAM wiring for PIN lives in §7a below (sudo + hyprlock only — not greetd).
if command -v pinutil >/dev/null; then
    if [[ -z "${SKIP_PIN:-}" ]]; then
        if [[ -t 0 ]] && id -nG tom | grep -qw tss; then
            log "Setting up TPM-backed PIN for tom (digits-only, 6+ chars)..."
            # No sudo — the PIN must belong to tom, not root. tom needs
            # tss-group membership for /dev/tpmrm0 access (handled by §1).
            if pinutil setup 2>&1 | tee /tmp/pinutil-setup.log; then
                log "TPM PIN set (per pinutil)."
            elif grep -q 'already has a PIN' /tmp/pinutil-setup.log; then
                log "TPM PIN already set — keeping (idempotent re-run)."
            else
                warn "pinutil setup failed; PAM PIN unlock won't work until fixed."
            fi
            # CRITICAL: pinutil setup can return success while the TPM NV
            # write actually failed (TPM NVRAM full, NV index conflict with
            # BitLocker or LUKS-TPM2 enrollment, etc). `pinutil status`
            # is unreliable too — it returns {"Ok":null} even when the
            # NV handle errors out (TPM_RC_HANDLE / 0x18B). The reliable
            # smoke test is `pinutil test < /dev/null` — returns NoPinSet
            # if the PIN didn't actually persist.
            if pinutil test < /dev/null 2>&1 | grep -q NoPinSet; then
                warn "pinutil test reports NoPinSet immediately after setup."
                warn "This means the TPM NV write failed silently (likely NV"
                warn "index conflict with BitLocker/LUKS-TPM2). PAM PIN auth"
                warn "will NOT work until you reclaim NV space:"
                warn "  sudo tpm2_nvreadpublic   # see what's allocated"
                warn "  sudo tpm2_nvundefine 0xXXXX  # free the conflicting slot"
                warn "  pinutil delete && pinutil setup     # (no sudo!)"
            fi
        elif [[ -t 0 ]]; then
            warn "Skipping pinutil setup — tom is not yet in the tss group."
            warn "  Log out and back in (group membership refreshes on login),"
            warn "  then run: pinutil setup"
        else
            warn "No TTY — skipping 'pinutil setup'. Run it manually after login: pinutil setup"
        fi
    fi
else
    warn "pinutil not found; skipping TPM-PIN setup."
fi

# ---------- 7a. PAM stacks for sudo / hyprlock / greetd ----------
# Three surfaces. greetd: PIN intentionally excluded (cold-boot wants full credential
# per the Windows Hello pattern). chroot.sh installs the canonical
# template from phase-3-arch-postinstall/system-files/pam.d/greetd at
# install time; we re-stomp it here on every postinstall run so any
# drift (manual edits, stale entries from prior postinstall iterations)
# gets corrected. The template ships with this script's directory, so
# locate it via SCRIPT_DIR.
GREETD_PAM_TEMPLATE="$SCRIPT_DIR/system-files/pam.d/greetd"
if [[ -f "$GREETD_PAM_TEMPLATE" ]]; then
    log "Re-installing /etc/pam.d/greetd from canonical template (drift correction)..."
    sudo install -m 644 "$GREETD_PAM_TEMPLATE" /etc/pam.d/greetd
else
    warn "Couldn't locate greetd PAM template at $GREETD_PAM_TEMPLATE — leaving /etc/pam.d/greetd as-is."
fi
#
# Design (rewritten 2026-05-05): concurrent fingerprint + PIN + password.
# pam_fprintd_grosshack races a fingerprint verify against a typed-input
# prompt; whichever side resolves first wins.
#
# Behavior:
#   Finger swipe    → grosshack SUCCESS → stack short-circuits, done <2s.
#   Typed PIN       → grosshack stashes AUTHTOK, returns AUTHINFO_UNAVAIL
#                    → libpinpam (use_first_pass) tests AUTHTOK as PIN
#                    → SUCCESS, stack short-circuits.
#   Typed password  → grosshack stashes AUTHTOK; libpinpam sees non-digits
#                    → AUTH_ERR silently → pam_unix tests AUTHTOK as
#                    password → SUCCESS.
#   Wrong typed     → libpinpam silent-fall-through; pam_unix tries and
#                    fails → standard sudo 3-retry loop.
#

# Stack split across surfaces:
#   sudo / hyprlock / polkit-1 — full concurrent stack (finger + PIN + password).
#                                These are in-session re-auth; PIN is fine.
#   login (TTY)                — finger + password ONLY; libpinpam excluded
#                                by design. Cold-boot is not a PIN surface.
#
# Why not lid-aware: the fingerprint reader is on the keyboard deck and
# IS physically blocked when the lid is closed. Earlier designs branched
# on lid state to skip fprintd. The race-based design makes that
# unnecessary: when the lid is closed grosshack still starts an fprintd
# verify, no finger ever lands, but the typed-input pthread wins the
# race fast. Cost is a few hundred ms of wasted D-Bus setup per closed-
# lid auth, paid in exchange for stack simplicity (no lid sensor, no
# pam_exec helper, no acpid/logind coupling, no broken-finger-skip
# branching).
#
# Module quirks:
#   - libpinpam.so (NOT pam_pinpam.so): pinpam-fnrhombus ships it under
#     this exact name. Bare references resolve against /usr/lib/security/.
#   - pinpam-fnrhombus carries our try_first_pass/use_first_pass patch
#     until upstream merges it. With use_first_pass + AUTHTOK missing or
#     non-digits, libpinpam returns AUTH_ERR silently (no re-prompt).
#     With no PIN provisioned at all, returns AUTHINFO_UNAVAIL.
#   - pam-fprint-grosshack-fnrhombus carries a 1-line patch that resets
#     a static SIGUSR1 flag at the start of each pam_authenticate call,
#     fixing sudo's retry loop (without it, retries 2+ silently corrupt
#     typed input).
#   - pam_unix uses try_first_pass: tests AUTHTOK first; if absent or
#     wrong, prompts fresh — that's how sudo's standard 3-retry loop
#     surfaces.
#
# NEVER remove pam_unix from the stack via the `system-auth` /
# `system-login` / `login` includes — that's the password fallback.
#
# Fully idempotent: tee overwrites with identical bytes on re-run.
#
# Recovery: if PAM is borked and you can't sudo, log into a different
# TTY (Ctrl+Alt+F2 then `root` + install-time root password), then
# edit /etc/pam.d/<broken-file>. Test with `sudo -k && sudo true`
# from a fresh shell after every edit.
#
# Unattended-sudo escape hatch: for batch tasks where Claude can't
# drive an interactive auth prompt, use `sudoa <cmd>` (defined in
# rhombu5/dots dot_zsh_aliases) instead of `sudo <cmd>`. It uses
# SUDO_ASKPASS=~/.local/bin/claude-askpass which pulls the local
# password from Bitwarden silently. Pre-req: `bwu` once per fresh
# login. See ~/.claude/CLAUDE.linux.md "Two sudo wrappers" for the
# trust model. The helper script + alias are user-config-shaped so
# they live in dots; this script just verifies their presence.

# Scrub the old lid-aware helper from prior installs.
log "Removing /usr/local/bin/lid-closed (lid-aware helper from prior installs)..."
sudo rm -f /usr/local/bin/lid-closed

log "Writing PAM stacks (concurrent fingerprint+PIN+password)..."

# In-session re-auth surfaces (sudo / hyprlock / polkit-1) — full concurrent
# stack. Same body, written byte-identical to all three.
read -r -d '' CONCURRENT_STACK <<'CONCEOF' || true
#%PAM-1.0
# arch-setup: concurrent fingerprint+PIN+password.
# grosshack races finger vs typed input; libpinpam tests typed value as PIN
# (use_first_pass = silent fall-through on non-digits); pam_unix tests typed
# value as password (try_first_pass = standard prompt-on-fail retry).
# See postinstall.sh §7a for design.
auth        sufficient    pam_fprintd_grosshack.so
auth        sufficient    libpinpam.so use_first_pass
auth        required      pam_unix.so try_first_pass nullok

account     include     system-auth
session     include     system-auth
CONCEOF

# /etc/pam.d/login (cold-boot, TTY) — fingerprint + password ONLY.
# libpinpam is intentionally excluded: PIN is not a cold-boot login factor
# on this design. system-local-login (NOT system-auth) chains pam_systemd
# via system-login, which sets XDG_RUNTIME_DIR for the tty1 → uwsm flow
# from .zprofile (without it Hyprland dies on launch and tty1 loops back).
read -r -d '' LOGIN_STACK <<'LOGINEOF' || true
#%PAM-1.0
# arch-setup: cold-boot TTY login — fingerprint or password (NO PIN).
# PIN is intentionally excluded at this surface; available at sudo /
# hyprlock / polkit-1 (in-session re-auth). See postinstall.sh §7a.
auth        sufficient    pam_fprintd_grosshack.so
auth        required      pam_unix.so try_first_pass nullok

account     include     system-local-login
session     include     system-local-login
LOGINEOF

for pam_file in sudo hyprlock polkit-1; do
    log "  /etc/pam.d/${pam_file}"
    printf '%s\n' "$CONCURRENT_STACK" | sudo tee "/etc/pam.d/${pam_file}" >/dev/null
done
log "  /etc/pam.d/login (no PIN — cold-boot surface)"
printf '%s\n' "$LOGIN_STACK" | sudo tee /etc/pam.d/login >/dev/null

# /etc/pam.d/physlock — TTY-based screen lock invoked from hypridle.
# Just includes the hyprlock stack so physlock and hyprlock stay in
# sync (same in-session auth surface: finger / PIN / password). If
# we ever re-introduce hyprlock as the lock_cmd, this file still
# applies — physlock is harmless when unused.
log "  /etc/pam.d/physlock"
sudo tee /etc/pam.d/physlock >/dev/null <<'PHYSEOF'
#%PAM-1.0
# arch-setup: physlock includes the hyprlock stack (in-session re-auth:
# fingerprint + PIN + password). See postinstall.sh §7a.
auth     include    hyprlock
account  include    hyprlock
session  include    hyprlock
PHYSEOF

# ---------- 7.5 LUKS TPM2 autounlock — VERIFY-ONLY (FDE per decisions.md §Q11) ----------
# install.sh §5b is now the single source of truth for TPM2 enrollment:
# it binds cryptroot to signed-PCR-11 + PCR 7 in one shot, while $LUKS_PW
# is still in memory. That eliminates the LUKS passphrase prompt that this
# stage used to require for re-enrollment.
#
# This stage just verifies the install-time enrollment is still in place.
# It does NOT attempt to unseal — signed-PCR-11 policy is phase-locked
# past `leave-initrd`, so any unseal probe from user session would fail
# (by design — that's the BitLocker temporal scope property). The probe-
# based "is the seal healthy?" check would have to either:
#   (a) re-implement the TPM authPolicyAuthorize verification dance, or
#   (b) reboot to test
# Both impractical from postinstall. We trust the install-time enrollment
# was sound (visible in install.sh log) and just sanity-check the LUKS
# header still has a tpm2 token.
log "Verifying TPM2 enrollment from install.sh §5b is still in place..."
if [[ -c /dev/tpm0 || -c /dev/tpmrm0 ]] && [[ -z "${SKIP_TPM_LUKS:-}" ]]; then
    _dev="/dev/disk/by-partlabel/ArchRoot"
    if [[ ! -b "$_dev" ]]; then
        warn "$_dev not found — can't verify TPM enrollment."
    elif sudo systemd-cryptenroll "$_dev" 2>/dev/null | awk 'NR>1 && $2=="tpm2"{f=1} END{exit !f}'; then
        log "  TPM2 keyslot present in LUKS header on ArchRoot. ✓"
        log "  (If first boot was silent, the seal works. If you ever need to"
        log "  re-enroll — TPM clear, key rotation, etc — see docs/"
        log "  tpm-luks-bitlocker-parity.md §Recovery.)"
    else
        warn "No TPM2 keyslot in LUKS header on ArchRoot. install.sh §5b enrollment must have failed."
        warn "Boot still works with the LUKS recovery key. To enroll TPM now:"
        warn "  sudo systemd-cryptenroll --tpm2-device=auto \\"
        warn "    --tpm2-public-key=/etc/systemd/tpm2-pcr-public.pem \\"
        warn "    --tpm2-public-key-pcrs=11 --tpm2-pcrs=7 \\"
        warn "    /dev/disk/by-partlabel/ArchRoot"
        warn "  (will prompt for the LUKS recovery key once)"
    fi
    unset _dev
else
    log "  TPM device missing or SKIP_TPM_LUKS set — skipping verify."
fi

# ---------- 8. Bitwarden: self-hosted server + SSH agent wiring ----------
BW_SERVER="${BW_SERVER:-https://hass4150.duckdns.org:7277}"

if command -v bw >/dev/null; then
    CURRENT=$(bw config server 2>/dev/null | tr -d '[:space:]' || true)
    if [[ "$CURRENT" != "$BW_SERVER" ]]; then
        log "Pointing Bitwarden CLI at self-hosted server: $BW_SERVER"
        bw config server "$BW_SERVER" >/dev/null || \
            warn "bw config server failed — set manually: bw config server $BW_SERVER"
    fi
fi

# Pre-seed the Bitwarden desktop app's `global` settings so the first
# launch lands on the self-hosted server with the user's preferred
# tray + autostart + browser-integration setup. Only writes if no
# data.json exists yet — re-running postinstall won't clobber any
# settings the user has tuned in-GUI.
#
# What's seeded vs interactive:
#   ✓ environmentUrls.base   — self-hosted server URL
#   ✓ tray.enabled, .minimizeToTray, .startToTray   — tray behavior
#   ✓ openAtLogin = false    — Hyprland exec-once handles autostart
#   ✓ enableBrowserIntegration — flag only; toggle in-GUI once after
#                                 first launch to write per-browser
#                                 native-messaging manifests under
#                                 ~/.mozilla/native-messaging-hosts/
#                                 (or Edge/Chromium equivalent).
#   ✗ "Unlock with system authentication" — PAM + keyring handshake;
#                                            must enable via Settings.
#   ✗ "Enable SSH agent" — creates ~/.bitwarden-ssh-agent.sock at
#                          toggle time; must enable via Settings.
#   ✗ "Ask for SSH auth = Never" — per-key, set when adding each key.
BW_DESKTOP_DIR="$HOME/.config/Bitwarden"
if [[ ! -f "$BW_DESKTOP_DIR/data.json" ]]; then
    mkdir -p "$BW_DESKTOP_DIR"
    cat > "$BW_DESKTOP_DIR/data.json" <<EOF
{
  "global": {
    "environmentUrls": {
      "base": "$BW_SERVER"
    },
    "tray": {
      "enabled": true,
      "minimizeToTray": true,
      "startToTray": true
    },
    "openAtLogin": false,
    "enableBrowserIntegration": true
  }
}
EOF
fi

log "Wiring Bitwarden SSH agent into ~/.ssh/config..."
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
if ! grep -q bitwarden-ssh-agent.sock "$HOME/.ssh/config" 2>/dev/null; then
    cat >> "$HOME/.ssh/config" <<'EOF'

Host *
    IdentityAgent ~/.bitwarden-ssh-agent.sock
EOF
    chmod 600 "$HOME/.ssh/config"
fi

# SSH_AUTH_SOCK export lives in chezmoi-managed ~/.zshenv (rhombu5/dots
# `dot_zshenv`), not here — .zshenv is sourced by every zsh including
# non-interactive (cron, systemd user units, captured shell-snapshots),
# whereas .zshrc.d/* only fires for interactive zsh.

# ---------- 9. GitHub identity (one-shot if gh already authed) ----------
# The planter scripts that handle bw login / gh auth login / SSH-signing
# wire-up live in this repo at phase-3-arch-postinstall/planters/, are
# planted to ~/.local/share/arch-setup-bootstraps/ by §13b, and are
# dispatched by ~/.zshrc.d/arch-bootstrap-runner.zsh (chezmoi-managed
# in rhombu5/dots) on each interactive shell. Each script self-checks
# its precondition and self-deletes on success.
#
# What stays here is the install-time fast path: if `gh` already authed
# (e.g. the user re-runs postinstall after first login), surgically write
# user.name/user.email into ~/.gitconfig.local so we don't wait for the
# next interactive shell to do it.
#
# CRITICAL: use `git config --file` for individual keys, NOT
# `cat > ~/.gitconfig.local`. Earlier versions did `cat >` which clobbered
# the whole file on every postinstall re-run — wiping the [commit]/gpg.ssh
# signing block that ssh-signing.sh appends, plus any hand-added user
# config. `git config --file` surgically updates leaving other sections
# intact.
if gh auth status &>/dev/null; then
    log "Configuring GitHub identity (gh already authed)..."
    gh_user=$(gh api user --jq '.login' 2>/dev/null) || gh_user=""
    gh_id=$(gh api user --jq '.id' 2>/dev/null) || gh_id=""
    if [[ -n "$gh_user" && -n "$gh_id" ]]; then
        gh_email="${gh_id}+${gh_user}@users.noreply.github.com"
        touch "$HOME/.gitconfig.local"
        git config --file "$HOME/.gitconfig.local" user.name  "$gh_user"
        git config --file "$HOME/.gitconfig.local" user.email "$gh_email"
        echo "  Git identity: ${gh_user} <${gh_email}>"
    fi
else
    log "gh not authed — first-login.sh (from dots) will run on next interactive shell."
fi

# ---------- 9a. fnpostinstall shell function ----------
# Convenience wrapper for re-running the latest postinstall from GitHub,
# piped through tee so there's always a log to grep. Written to a
# .zshrc.d fragment so it lands on $PATH via the .zshrc loop.
#
# Clones the whole repo to a tmpfs path instead of fetching just
# postinstall.sh — earlier sections (greetd PAM template, system-files/
# tree) reference sibling files via $SCRIPT_DIR, which a single-file
# fetch wouldn't supply. Passes any args through
# (e.g. `fnpostinstall --no-verify`).
cat > "$HOME/.zshrc.d/arch-postinstall.zsh" <<'FNEOF'
# arch-setup: re-run the latest postinstall from GitHub, logging to /tmp.
fnpostinstall() {
    local log="/tmp/postinstall-$(date +%Y%m%d-%H%M%S).log"
    local tmp
    tmp=$(mktemp -d -t arch-setup-XXXXXX) || return 1
    echo "Logging to $log; staging in $tmp"
    {
        git clone --depth 1 https://github.com/fnrhombus/arch-setup.git "$tmp/repo" \
            && bash "$tmp/repo/phase-3-arch-postinstall/postinstall.sh" "$@"
    } 2>&1 | tee "$log"
}
FNEOF

# ---------- 10. zgenom + zsh config (enriched from fnwsl) ----------
if [[ ! -d "$HOME/.zgenom" ]]; then
    log "Cloning zgenom..."
    retry git clone https://github.com/jandamm/zgenom.git "$HOME/.zgenom"
fi

log "Writing ~/.zshrc..."
cat > "$HOME/.zshrc" <<'ZSHEOF'
# --- Powerlevel10k instant prompt (must be near top) ---
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# --- Zgenom plugin manager ---
ZGEN_DIR="${HOME}/.zgenom"
source "${ZGEN_DIR}/zgenom.zsh"

if ! zgenom saved; then
  zgenom ohmyzsh
  zgenom ohmyzsh plugins/sudo
  zgenom ohmyzsh plugins/colored-man-pages
  zgenom ohmyzsh plugins/extract
  zgenom ohmyzsh plugins/command-not-found
  zgenom ohmyzsh plugins/docker
  zgenom ohmyzsh plugins/docker-compose
  zgenom ohmyzsh plugins/npm
  zgenom ohmyzsh plugins/pip
  zgenom ohmyzsh plugins/dotnet
  zgenom load zdharma-continuum/fast-syntax-highlighting
  zgenom load zsh-users/zsh-autosuggestions
  zgenom load zsh-users/zsh-history-substring-search
  zgenom load zsh-users/zsh-completions
  zgenom load Aloxaf/fzf-tab
  zgenom load unixorn/fzf-zsh-plugin
  zgenom load romkatv/powerlevel10k powerlevel10k
  zgenom save
  zgenom compile "$HOME/.zshrc"
fi

# --- History ---
HISTFILE=~/.zsh_history
HISTSIZE=100000
SAVEHIST=100000
setopt APPEND_HISTORY SHARE_HISTORY HIST_EXPIRE_DUPS_FIRST HIST_IGNORE_DUPS \
       HIST_IGNORE_ALL_DUPS HIST_FIND_NO_DUPS HIST_IGNORE_SPACE \
       HIST_SAVE_NO_DUPS HIST_REDUCE_BLANKS

# --- Shell options ---
setopt NO_BEEP INTERACTIVE_COMMENTS MULTIOS

# --- Completion ---
autoload -Uz compinit
if [[ -n ~/.zcompdump(#qN.mh+24) ]]; then
  compinit
else
  compinit -C
fi
autoload -Uz bashcompinit && bashcompinit
# Claude Code ships completions via `claude --print-completion zsh` at runtime.
# Previous versions sourced a bash-completion file we never wrote — that was
# dead code. Source only if the binary is actually on PATH, otherwise
# mise-shim startup is a ~200ms tax on every shell for nothing.
if command -v claude &>/dev/null; then
    eval "$(claude --print-completion zsh 2>/dev/null)" || true
fi
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path ~/.zsh/cache
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

# --- PATH ---
export PATH="$HOME/.local/bin:$PATH"
typeset -aU path

# --- Tool inits ---
eval "$(mise activate zsh)"
eval "$(zoxide init zsh)"
eval "$(direnv hook zsh)"

# --- Aliases ---
source ~/.zsh_aliases 2>/dev/null

# --- Local overrides ---
for f in ~/.zshrc.d/*(N); do source "$f"; done

# --- Report commands that ran >2s ---
REPORTTIME=2

# --- Powerlevel10k config ---
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh
ZSHEOF

# No pre-shipped ~/.p10k.zsh on purpose: first zsh launch fires `p10k configure`,
# the interactive wizard that writes ~/.p10k.zsh based on user taste. Sourcing
# of ~/.p10k.zsh is already wired in the .zshrc block above — once the wizard
# finishes, subsequent shells pick the config up.

log "Writing ~/.zsh_aliases..."
cat > "$HOME/.zsh_aliases" <<'ALIASEOF'
# --- Navigation ---
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."

# --- ls (eza) ---
alias ls='eza --group-directories-first --icons'
alias ll='eza -l --git --group-directories-first --icons'
alias la='eza -la --git --group-directories-first --icons'
alias lt='eza --tree --level=2 --icons'
alias tree='eza --tree --icons'

# --- bat ---
alias cat='bat --paging=never'

# --- mc: make directory and cd into it ---
mc() { mkdir -p "$1" && cd "$1"; }

# --- bw (Bitwarden CLI): unlock the vault using libsecret (gnome-keyring) ---
# Same auth model as the desktop app's "Unlock with system authentication"
# toggle: master password lives in gnome-keyring (unlocked at login by
# PAM), CLI pulls it silently to unlock the BW vault for this shell.
#
# First call in a fresh keyring prompts for the master password ONCE
# (`secret-tool store ...`) and persists it. Every subsequent shell can
# `bwu` without typing anything — the keyring is already unlocked from
# PAM at login.
#
# To wipe the stored master password (e.g. after rotating it):
#     secret-tool clear service bitwarden user master
bwu() {
    local pw session
    for attempt in 1 2; do
        # 1. Try the keyring first (silent on subsequent calls).
        if ! pw=$(secret-tool lookup service bitwarden user master 2>/dev/null); then
            # 2. Fall back to interactive prompt — using `read -rs` so
            #    we can validate non-empty BEFORE pushing into libsecret.
            #    secret-tool store's own prompt is harder to validate.
            echo -n "Bitwarden master password (one-time seed): " >&2
            IFS= read -rs pw
            echo >&2
            if [[ -z "$pw" ]]; then
                echo "bwu: empty password — aborting (re-run when ready)." >&2
                return 1
            fi
            printf '%s' "$pw" | secret-tool store \
                --label='Bitwarden master password' \
                service bitwarden user master
        fi
        session=$(BW_PASSWORD="$pw" command bw unlock --passwordenv BW_PASSWORD --raw 2>/dev/null) || true
        if [[ -n "$session" ]]; then
            export BW_SESSION="$session"
            printf '%s' "$BW_SESSION" | secret-tool store \
                --label='Bitwarden CLI session' \
                service bitwarden type session
            echo "bwu: vault unlocked." >&2
            return 0
        fi
        echo "bwu: that password didn't unlock the vault — wiping cached entry, re-prompting..." >&2
        secret-tool clear service bitwarden user master 2>/dev/null
        pw=""
    done
    echo "bwu: couldn't unlock after retry. Check: bw login --check; bw status" >&2
    return 1
}

# `bw` wrapper: transparent unlock. If vault is locked or BW_SESSION
# is missing/stale, pull the cached session from libsecret; if that's
# also stale, re-run bwu (which uses the master password in libsecret —
# silent unless the keyring has been wiped). End result: every `bw`
# command Just Works in any shell after the user has run bwu once.
#
# Cost: one `bw status` invocation per call to gate the unlock check
# (~100ms). Skip the gate when stdin isn't a TTY (scripts/CI) so we
# don't accidentally prompt during automation.
bw() {
    if [[ -t 0 ]]; then
        if [[ -z "${BW_SESSION:-}" ]]; then
            BW_SESSION=$(secret-tool lookup service bitwarden type session 2>/dev/null) && export BW_SESSION
        fi
        local status
        status=$(command bw status 2>/dev/null | jq -r .status 2>/dev/null)
        if [[ "$status" == "locked" ]] || [[ "$status" == "" ]]; then
            bwu >&2 || return $?
        fi
    fi
    command bw "$@"
}
ALIASEOF

log "Pre-building zgenom plugin cache (so first login is fast)..."
# _POSTINSTALL_NONINTERACTIVE: signals to any interactive ~/.zshrc.d/*
# planter (gh auth, bw login, etc.) that this is a warmup subshell —
# they should no-op rather than blocking postinstall on browser-based
# auth flows. The planters are designed to fire on real first logins;
# this just keeps them from firing inside postinstall itself.
_POSTINSTALL_NONINTERACTIVE=1 zsh -i -c 'echo zgenom warmup complete' 2>/dev/null \
    || warn "zgenom warmup had issues; first login will rebuild."

# ---------- 11. tmux config — handled by chezmoi (§13) ----------
# dot_tmux.conf in rhombu5/dots is the source of truth (Ctrl+a prefix, splits open
# in pane CWD for the Claude Code worktree workflow, matugen-rendered colors
# via ~/.config/tmux/colors.conf). No tpm — sesh-bin (§3 yay) covers session
# switching, and matugen replaces the catppuccin/tmux plugin's coloring.

# ---------- 12. Helix config — handled by chezmoi (§13) ----------
# dot_config/helix/config.toml in rhombu5/dots is the source of truth (theme = matugen).
# No write here.

# ---------- 13. Hyprland configs via chezmoi (bare-Hyprland design) ----------
# Switched from HyDE → bare-Hyprland 2026-04-22 (decisions.md §Q10 + §Q-K +
# desktop-requirements.md). Reasons in the memo: HyDE writes a wall of
# upstream config we don't own, contaminates /boot loader entries on
# install, and the "saves user time" value evaporated when the user said
# "Claude does the tweaking." Now: Claude-authored configs live in the
# rhombu5/dots repo, applied via chezmoi.
#
# Theme is matugen (Material You from wallpaper) — every component (waybar,
# swaync, fuzzel, ghostty, helix, hypr-colors, tmux, gtk, qt) reads colors
# from a matugen-rendered template. See dot_config/matugen/config.toml in
# the dots repo.
#
# `chezmoi init --apply` clones the repo into the configured sourceDir
# and applies in one step. Idempotent: a second run is a no-op when source
# matches dest. Requires network — we assume it's up by §13 (the user
# connected via iwctl in §0, and pacman/yay in earlier sections proved it).
#
# sourceDir override: chezmoi's default is ~/.local/share/chezmoi (XDG
# data home). User prefs lock github clones at ~/src/{repo}@{user}, so
# we write a chezmoi.toml that points sourceDir there BEFORE invoking
# `chezmoi init` — chezmoi reads the config first, then clones.
#
# Clone over HTTPS so the bootstrap doesn't depend on Bitwarden being
# unlocked yet (postinstall runs from a TTY before Hyprland comes up;
# bitwarden-desktop and its ssh-agent socket aren't available). Once the
# repo is on disk, rewrite the remote to SSH so future pushes/pulls (made
# from a logged-in Hyprland session with Bitwarden unlocked) just work.
DOTS_REPO_HTTPS="https://github.com/rhombu5/dots.git"
DOTS_REPO_SSH="git@github.com:rhombu5/dots.git"
DOTS_SRC="$HOME/src/dots@rhombu5"

# chezmoi.toml: pin sourceDir before any chezmoi invocation. Idempotent —
# overwrites with the same content on re-run.
mkdir -p "$HOME/.config/chezmoi" "$(dirname "$DOTS_SRC")"
cat > "$HOME/.config/chezmoi/chezmoi.toml" <<EOF
sourceDir = "$DOTS_SRC"
EOF

if ! command -v chezmoi >/dev/null; then
    warn "chezmoi not installed — was it dropped from §1 pacman list?"
    warn "  Skipping dotfile apply — Hyprland will start with empty config."
elif [[ -d "$DOTS_SRC/.git" ]]; then
    log "chezmoi source already present at $DOTS_SRC — pulling + applying..."
    git -C "$DOTS_SRC" remote set-url origin "$DOTS_REPO_SSH"
    git -C "$DOTS_SRC" pull --ff-only \
        || warn "git pull on chezmoi source failed — applying current checkout."
    chezmoi apply --force \
        || warn "chezmoi apply reported issues — check 'chezmoi status' and 'chezmoi diff'."
else
    log "Cloning rhombu5/dots into $DOTS_SRC and applying..."
    if chezmoi init --apply "$DOTS_REPO_HTTPS"; then
        git -C "$DOTS_SRC" remote set-url origin "$DOTS_REPO_SSH"
    else
        warn "chezmoi init --apply failed — Hyprland will start with empty config. Re-run 'chezmoi init --apply $DOTS_REPO_HTTPS' once network is up."
    fi
fi

# ---------- 13b. Plant arch-setup-bootstraps (planters) ----------
# Planters are one-shot scripts that fire on first interactive shell via
# the .zshrc.d/arch-bootstrap-runner.zsh dispatcher (chezmoi-managed in
# rhombu5/dots), do something requiring interactive auth (gh login, bw
# unlock, OAuth flows, etc.), then self-delete. They live here in
# arch-setup rather than in dots because (1) they're install-time
# scaffolding, not config; (2) chezmoi tracking conflicts with
# self-delete-on-success — chezmoi treats the missing file as
# user-deleted-managed-content and prompts on every subsequent apply.
#
# The runner stays in dots (it's pure user-shell config); arch-setup
# owns the install-time content the runner dispatches.
log "Planting arch-setup-bootstraps..."
mkdir -p "$HOME/.local/share/arch-setup-bootstraps"
install -m 0755 -t "$HOME/.local/share/arch-setup-bootstraps" \
    "$SCRIPT_DIR/planters/"*.sh \
    || warn "planter install failed — see $SCRIPT_DIR/planters/."

# Initial wallpaper render: chezmoi's run_once script downloads from callisto;
# theme-toggle's first run picks one and renders matugen. Triggered manually
# here so the first Hyprland launch has a complete palette.
if command -v matugen >/dev/null && [[ -d "$HOME/Pictures/Wallpapers" ]]; then
    log "Seeding initial matugen palette..."
    if [[ -x "$HOME/.local/bin/wallpaper-rotate" ]]; then
        "$HOME/.local/bin/wallpaper-rotate" --first \
            || warn "wallpaper-rotate --first failed — Hyprland may start with default colors."
    fi
fi

# Enable user systemd timer for wallpaper rotation (every 6h).
if [[ -f "$HOME/.config/systemd/user/wallpaper-rotate.timer" ]]; then
    log "Enabling wallpaper-rotate.timer..."
    systemctl --user daemon-reload
    systemctl --user enable --now wallpaper-rotate.timer 2>/dev/null \
        || warn "wallpaper-rotate.timer enable failed — re-run inside a graphical session."
fi

# Enable user-level tablet-mode-watcher (the angle-polling daemon — see §1d).
# Shipped via chezmoi from rhombu5/dots:
#   dot_local/bin/executable_tablet-mode-watcher
#   dot_config/systemd/user/tablet-mode-watcher.service
if [[ -f "$HOME/.config/systemd/user/tablet-mode-watcher.service" ]]; then
    log "Enabling tablet-mode-watcher.service..."
    systemctl --user daemon-reload
    systemctl --user enable --now tablet-mode-watcher.service 2>/dev/null \
        || warn "tablet-mode-watcher.service enable failed — re-run inside a graphical session (or systemctl --user enable --now tablet-mode-watcher.service manually)."
fi

# Hyprland plugins via hyprpm — eager build, lazy enable.
#
# Design (rewritten 2026-04-30 after a Hyprspace HEAD crash sent the
# compositor to safe mode every login):
#   - EAGER (here): `hyprpm update` + `hyprpm add <repo>` for each plugin.
#     `update` runs `sudo make installheaders` to compile against the
#     installed Hyprland version, so it needs sudo (we're warm — see the
#     keeper at top of this script). `add` clones the plugin repo and
#     builds the .so. Neither needs a Hyprland session, so we can do
#     them from a TTY here.
#   - LAZY (on first login): ~/.local/bin/hypr-plugins-on-login (shipped
#     by chezmoi from rhombu5/dots, called from exec.conf) does the
#     `hyprpm enable` + post-plugins.d/ sourcing. `enable` writes state
#     and calls `hyprctl plugin load` — the latter needs HYPRLAND_INSTANCE_
#     SIGNATURE, hence the deferral. `enable` does NOT need sudo, so
#     this never re-prompts TPM-PIN on a fresh shell.
#
# Hyprspace is INTENTIONALLY skipped here. HEAD (12ddde0, master 2026-04-30)
# aborts in onKeyPress on the first keystroke after load, sending Hyprland
# straight into safe mode on every login. Re-introduce after bisecting
# for a working revision (or wait for an upstream fix). When you do, add
# both an `hyprpm add` here and an entry in dot_local/bin/executable_hypr-
# plugins-on-login (rhombu5/dots).
if command -v hyprpm >/dev/null; then
    log "Building Hyprland plugins (eager — sudo warm, build output visible)..."
    log "  hyprpm update (compiles headers against installed Hyprland)..."
    if ! hyprpm update; then
        warn "hyprpm update failed — Hyprland plugin DSOs are likely out-of-sync with installed Hyprland. Re-run after fixing the underlying header build, or run 'hyprpm update' manually from a logged-in shell."
    fi
    # Scrolling layout is intentionally NOT installed as a plugin.
    # Hyprland 0.54 absorbed it into core (algorithm/tiled/scrolling/
    # ScrollingAlgorithm.cpp). Setting general:layout = scrolling
    # works natively; bindings live in dot_config/hypr/scrolling.conf
    # in rhombu5/dots, sourced from hyprland.conf. The journey:
    #   - dawsers/hyprscroller — abandoned 2024 ("Last commit :-(", pinned at 0.48.1)
    #   - hyprwm/hyprscrolling — also fails to build on 0.54.x
    #     (#includes the obsolete IHyprLayout.hpp header)
    #   - core scrolling layout — works since 0.54.0, no plugin needed
    # Hyprspace TODO — see plugins.conf in rhombu5/dots. Don't reintroduce blindly.
fi

# Ghostty config is matugen-themed via the rhombu5/dots chezmoi tree (§13).
# greetd-regreet system config is installed by install.sh from
# phase-3-arch-postinstall/system-files/greetd/. greetd itself is
# disabled by §1f — login is bare TTY — but the config + matugen-rendered
# CSS stay current so the fallback is ready if re-enabled.

# ---------- 16. Snapper: baseline snapshot of / ----------
# NOTE: install.sh already created the @snapshots subvolume and mounted it at
# /.snapshots. `snapper create-config /` would try to create ANOTHER .snapshots
# subvolume on top of that mount and fail with "subvolume already exists" or
# "not a valid subvolume". We write the config by hand instead (same result,
# no filesystem tampering).
if command -v snapper >/dev/null && [[ ! -f /etc/snapper/configs/root ]]; then
    log "Writing snapper config for / (handmade, avoids .snapshots conflict)..."
    sudo install -d -m 750 /etc/snapper/configs
    # snapper moved its default template from /etc/ to /usr/share/ in recent
    # releases. Probe both so this works on old and new package versions.
    snapper_tmpl=""
    for candidate in /usr/share/snapper/config-templates/default /etc/snapper/config-templates/default; do
        if [[ -f "$candidate" ]]; then snapper_tmpl="$candidate"; break; fi
    done
    if [[ -z "$snapper_tmpl" ]]; then
        warn "snapper installed but no default template found — skipping config."
    else
        sudo cp "$snapper_tmpl" /etc/snapper/configs/root
        sudo sed -i 's|^SUBVOLUME=.*|SUBVOLUME="/"|' /etc/snapper/configs/root
        sudo sed -i 's|^ALLOW_USERS=.*|ALLOW_USERS="tom"|' /etc/snapper/configs/root
        # Register the config name so `snapper list-configs` sees it.
        if ! grep -q '^SNAPPER_CONFIGS=.*root' /etc/conf.d/snapper 2>/dev/null; then
            echo 'SNAPPER_CONFIGS="root"' | sudo tee -a /etc/conf.d/snapper >/dev/null
        fi
        sudo chown -R :tom /.snapshots 2>/dev/null || true
        sudo chmod 750 /.snapshots
        # Baseline snapshot — safe now that config exists and .snapshots is writable.
        # --no-dbus bypasses snapperd (which caches config list at startup and
        # doesn't see our hand-written /etc/snapper/configs/root without a
        # restart). Reading config files directly makes `-c root` resolve.
        sudo snapper --no-dbus -c root create --description "clean install postinstall baseline" || \
            warn "snapper baseline failed — config is in place but no snapshot taken."
    fi
fi

# ---------- 17. USB-serial udev rules (ESP32 / Pico / FTDI / CH340) ----------
if [[ ! -f /etc/udev/rules.d/99-usb-serial.rules ]]; then
    log "Adding udev rules for ESP32, Pico, FTDI, CH340..."
    sudo tee /etc/udev/rules.d/99-usb-serial.rules > /dev/null <<'EOF'
# CP2102/CP2104 (ESP32 dev boards)
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", MODE="0666", GROUP="uucp"
# CH340 (cheap ESP32 clones)
SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", MODE="0666", GROUP="uucp"
# RP2040 (Pi Pico) — REPL
SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", ATTRS{idProduct}=="0003", MODE="0666", GROUP="uucp"
# RP2040 (Pi Pico) — MicroPython
SUBSYSTEM=="tty", ATTRS{idVendor}=="2e8a", ATTRS{idProduct}=="0005", MODE="0666", GROUP="uucp"
# FTDI (various dev boards)
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", MODE="0666", GROUP="uucp"
EOF
    sudo udevadm control --reload
    sudo usermod -aG uucp "$USER"
fi

# ---------- 18. default shell ----------
# chroot.sh already creates tom with -s /bin/zsh, so this is almost always a
# no-op. If someone manually changed the shell or the useradd flag was lost,
# use `sudo usermod` here instead of `chsh` — chsh invokes PAM auth and
# stalls the script waiting for a password with no way to pipe one in.
CURRENT_SHELL=$(getent passwd "$USER" | cut -d: -f7)
if [[ "$CURRENT_SHELL" != "$(which zsh)" ]]; then
    log "Changing login shell to zsh (via usermod — avoids chsh PAM prompt)..."
    sudo usermod -s "$(which zsh)" "$USER"
fi

# ---------- 15-windows. dockur/windows: wait for Windows install to finish ----------
# The container itself was started early in §1a-dockur so the ~15-30 min
# Windows install runs in parallel with the rest of postinstall (yay AUR
# builds, fingerprint enrollment, chezmoi apply, etc.). This block just
# blocks on the install actually finishing before postinstall returns.
#
# Wait signal: container HEALTHCHECK transitions to `healthy` once Windows
# is past OOBE and the dockur dashboard responds. RDP port opens at
# container start (before Windows is up), so it's not a usable signal.
#
# Note re: snapper §16 baseline: snapper runs while the VM install may
# still be in progress, so the baseline snapshot's view of /var/lib/docker/
# volumes/windows_data is whatever's been written by then. btrfs CoW makes
# the snapshot itself near-zero-cost, but a `snapper rollback` to baseline
# would land in a half-installed VM state — recover by deleting the volume
# and re-running `docker compose up`. Acceptable since rollback to baseline
# is rare and "VM is user data not baseline state" still holds in spirit.
#
# sudo on docker calls: tom isn't in the docker group in this shell yet
# (group adds don't propagate without re-login). sudo bypasses that.
if (( SKIP_WINDOWS_INSTALL == 1 )); then
    log "Skipping Windows install wait (--skip-windows-install)."
else
    log "Waiting for Windows install to finish (~15-30 min on first run; progress at http://127.0.0.1:8006/)..."
    deadline=$(( $(date +%s) + 45*60 ))
    health=""
    last_health=""
    while (( $(date +%s) < deadline )); do
        health=$(sudo docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' windows 2>/dev/null || echo "missing")
        if [[ "$health" == "healthy" ]]; then
            log "  Windows VM is up (container health=healthy)."
            break
        fi
        if [[ "$health" != "$last_health" ]]; then
            log "  ...container health: $health"
            last_health="$health"
        fi
        sleep 30
    done
    if [[ "$health" != "healthy" ]]; then
        warn "Windows install did not reach 'healthy' within 45 min — check 'sudo docker logs windows' or http://127.0.0.1:8006/"
    fi
fi

# ---------- 19. verify ----------
if (( SKIP_VERIFY == 1 )); then
    log "Skipping verify (--no-verify). Re-run without the flag for the full sweep."
    echo
    echo "Log out and back in (or reboot) — agetty on tty1 + ~/.zprofile auto-launches Hyprland via uwsm."
    exit 0
fi
echo
echo "=== Verify ==="
# Clear shell's command hash cache so binaries installed during this very run
# (e.g. pinutil from pinpam-git) resolve via `command -v` without a shell restart.
hash -r 2>/dev/null || true
VERIFY_PASS=0
VERIFY_FAIL=0
VERIFY_FAILED_NAMES=()
check() {
    local name="$1"; local cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        printf '  \033[1;32mOK\033[0m    %s\n' "$name"
        VERIFY_PASS=$((VERIFY_PASS+1))
    else
        printf '  \033[1;31mFAIL\033[0m  %s\n' "$name"
        VERIFY_FAIL=$((VERIFY_FAIL+1))
        VERIFY_FAILED_NAMES+=("$name")
    fi
}

echo "-- shell + core CLI --"
check "zsh"                 "command -v zsh"
check "tmux"                "command -v tmux"
check "helix"               "command -v helix || command -v hx"
check "pwsh (powershell)"   "command -v pwsh"
check "yay"                 "command -v yay"
check "mise"                "command -v mise"
check "chezmoi"             "command -v chezmoi"
check "gh (github-cli)"     "command -v gh"
check "sesh"                "command -v sesh"
check "zgenom"              "test -d $HOME/.zgenom"
check "p10k"                "test -d $HOME/.zgenom/romkatv"
check "bat/fd/rg/eza/lsd"   "command -v bat && command -v fd && command -v rg && command -v eza && command -v lsd"
check "btop/jq/fzf/zoxide"  "command -v btop && command -v jq && command -v fzf && command -v zoxide"
check "direnv/sd/yq/xh"     "command -v direnv && command -v sd && command -v yq && command -v xh"
check "tldr/pkgfile"        "command -v tldr && command -v pkgfile"
check "JetBrainsMono Nerd"  "fc-list -q 'JetBrainsMono Nerd Font'"

echo "-- mise + node + Claude CLI --"
check "mise node@lts"       "mise exec -- node --version"
check "claude (CLI)"        "command -v claude"

echo "-- desktop apps --"
check "vscode"              "command -v code"
check "edge"                "command -v microsoft-edge-stable"
check "claude-desktop"      "command -v claude-desktop-native || command -v claude-desktop"
check "bitwarden desktop"   "command -v bitwarden-desktop || command -v bitwarden"
check "bitwarden-cli"       "command -v bw"
check "remmina (RDP)"       "command -v remmina"
check "freerdp"             "command -v xfreerdp || command -v xfreerdp3"
check "nautilus"            "command -v nautilus"
check "yazi"                "command -v yazi"
check "dropbox (daemon)"    "command -v dropbox"
check "dropbox-cli"         "pacman -Q dropbox-cli"
check "rclone"              "command -v rclone"

echo "-- terminal stack --"
check "ghostty"             "command -v ghostty"
check "ghostty config"      "test -f $HOME/.config/ghostty/config && grep -q 'theme = matugen' $HOME/.config/ghostty/config"
check "tmux config (chezmoi)" "test -f $HOME/.tmux.conf && grep -q 'C-a' $HOME/.tmux.conf"

echo "-- Hyprland (bare, chezmoi-managed) --"
check "hyprland config"     "test -f $HOME/.config/hypr/hyprland.conf"
check "binds.conf src"      "grep -q 'source = ~/.config/hypr/binds.conf' $HOME/.config/hypr/hyprland.conf"
check "monitors.conf src"   "grep -q 'monitors.conf' $HOME/.config/hypr/hyprland.conf"
check "matugen colors src"  "grep -q 'colors.conf' $HOME/.config/hypr/hyprland.conf"
check "matugen config"      "test -f $HOME/.config/matugen/config.toml"
check "validate-hypr-binds" "test -x $HOME/.local/bin/validate-hypr-binds"
check "wallpaper-rotate"    "test -x $HOME/.local/bin/wallpaper-rotate"
check "theme-toggle"        "test -x $HOME/.local/bin/theme-toggle"
check "fuzzel"              "command -v fuzzel"
check "cliphist"            "command -v cliphist"
check "swaync"              "command -v swaync && command -v swaync-client"
check "satty"               "command -v satty"
check "awww (wallpaper)"    "command -v awww && command -v awww-daemon"
check "matugen (palette)"   "command -v matugen"
check "hyprshot"            "command -v hyprshot"
check "wl-copy"             "command -v wl-copy"
check "xdg-portal-gtk"      "pacman -Q xdg-desktop-portal-gtk"
check "hyprpolkitagent svc" "systemctl --user is-enabled hyprpolkitagent.service 2>/dev/null"

echo "-- 2-in-1 hardware --"
check "iio-sensor-proxy"    "pacman -Q iio-sensor-proxy"
check "iio-hyprland (AUR)"  "command -v iio-hyprland"
check "wvkbd (touch OSK)"   "command -v wvkbd-mobintl"
check "libwacom"            "pacman -Q libwacom"
check "Hyprspace plugin"    "hyprpm list 2>/dev/null | grep -qi hyprspace"
check "tablet-mode-toggle"  "test -x $HOME/.local/bin/tablet-mode-toggle"
check "tablet-mode-watcher" "test -x $HOME/.local/bin/tablet-mode-watcher"
check "tablet-mode-watcher.service" "test -f $HOME/.config/systemd/user/tablet-mode-watcher.service"

echo "-- session / login / display --"
check "NetworkManager"      "systemctl is-enabled NetworkManager"
check "greetd installed"    "pacman -Q greetd"
check "greetd-regreet"      "pacman -Q greetd-regreet"
check "greetd disabled (TTY-login mode)" "! systemctl is-enabled greetd 2>/dev/null"
check "pipewire"            "pacman -Q pipewire wireplumber"
check "bluetooth"           "systemctl is-enabled bluetooth"

echo "-- printing (Canon Pro 9000 Mk II via USB) --"
check "cups installed"      "pacman -Q cups"
check "cups.socket enabled" "systemctl is-enabled cups.socket"
check "gutenprint PPDs"     "pacman -Q gutenprint"
check "tom in lp group"     "id -nG tom | grep -qw lp"

echo "-- secrets / auth --"
check "fprintd enabled"     "systemctl is-enabled fprintd"
check "fprintd enrolled"    "fprintd-list tom 2>/dev/null | grep -q 'Fingerprints for user tom'"
check "pinutil (TPM PIN)"   "test -x /usr/bin/pinutil || command -v pinutil"
check "pinpam-fnrhombus pkg" "pacman -Q pinpam-fnrhombus"
check "libpinpam.so present" "test -f /usr/lib/security/libpinpam.so"
check "grosshack-fnrhombus pkg" "pacman -Q pam-fprint-grosshack-fnrhombus"
check "grosshack .so present" "test -f /usr/lib/security/pam_fprintd_grosshack.so"
check "PIN actually persisted" "! pinutil test < /dev/null 2>&1 | grep -q NoPinSet"
check "lid-closed helper removed" "! test -e /usr/local/bin/lid-closed"
# Unattended-sudo escape hatch (claude-askpass + sudoa) — owned by
# rhombu5/dots. Surfaces a missing chezmoi apply or a renamed Bitwarden
# entry; doesn't gate install. See ~/.claude/CLAUDE.linux.md "Two sudo
# wrappers" for the trust model + usage.
check "claude-askpass present (dots)" "test -x /home/tom/.local/bin/claude-askpass"
check "sudoa alias defined (dots)"     "grep -q '^sudoa' $HOME/.zsh_aliases"
# Concurrent fingerprint+PIN+password stack across sudo/hyprlock/polkit-1
# (per §7a, 2026-05-05 rewrite). login is checked separately below — it
# excludes libpinpam by design (cold-boot is not a PIN surface).
for _f in sudo hyprlock polkit-1; do
    check "concurrent PAM in /etc/pam.d/${_f}" "grep -q pam_fprintd_grosshack /etc/pam.d/${_f} && grep -q 'libpinpam.so use_first_pass' /etc/pam.d/${_f} && grep -q 'pam_unix.so try_first_pass' /etc/pam.d/${_f} && ! grep -q lid-closed /etc/pam.d/${_f}"
done
unset _f
check "login PAM (no PIN, cold-boot)" "grep -q pam_fprintd_grosshack /etc/pam.d/login && grep -q 'pam_unix.so try_first_pass' /etc/pam.d/login && ! grep -q libpinpam /etc/pam.d/login && ! grep -q lid-closed /etc/pam.d/login"
# physlock — TTY-based screen lock. Pkg from AUR; PAM file written in §7a.
check "physlock pkg" "pacman -Q physlock"
check "physlock setuid" "test -u /usr/bin/physlock"
check "physlock PAM stack (includes hyprlock)" "grep -qE 'include[[:space:]]+hyprlock' /etc/pam.d/physlock"
check "pam_unix in sys-auth" "grep -q pam_unix /etc/pam.d/system-auth"
check "LUKS root TPM2"      "sudo systemd-cryptenroll /dev/disk/by-partlabel/ArchRoot 2>/dev/null | awk 'NR>1 && \$2==\"tpm2\"{f=1} END{exit !f}'"
check "PCR signing keypair exists" "[[ -f /etc/systemd/tpm2-pcr-public.pem && -f /etc/systemd/tpm2-pcr-private.pem ]]"
check "btrfs swapfile present"     "test -f /swap/swapfile"
check "swap active"                "swapon --show=NAME --noheadings | grep -q /swap/swapfile"
check "ssh agent wired"     "grep -q bitwarden-ssh-agent.sock $HOME/.ssh/config"

echo "-- inbound network --"
check "sshd enabled"        "systemctl is-enabled sshd"
check "sshd listening :22"  "ss -tlnH 'sport = 22' | grep -q :22"
check "sshd PasswordAuth=no" "sudo grep -qi '^PasswordAuthentication no' /etc/ssh/sshd_config.d/10-arch-setup.conf"
check "sshd PermitRoot=no"  "sudo grep -qi '^PermitRootLogin no' /etc/ssh/sshd_config.d/10-arch-setup.conf"
check "sshd hardened conf"  "sudo test -f /etc/ssh/sshd_config.d/10-arch-setup.conf"
check "callisto authorized" "grep -q 'thoma@callisto' $HOME/.ssh/authorized_keys"
check "ufw enabled"         "sudo ufw status | grep -q 'Status: active'"
check "ufw ssh allowed"     "sudo ufw status | grep -E '^22/tcp|^22 ' | grep -q ALLOW"
check "ufw default deny in" "sudo ufw status verbose | grep -qi 'Default: deny (incoming)'"

echo "-- DDNS + Let's Encrypt --"
check "azure-cli"           "command -v az"
check "memtest86+ entry"   "sudo grep -qE '^/Memtest86\\+' /boot/limine.conf"
check "limine-snapper-sync" "pacman -Q limine-snapper-sync"
check "sbctl installed"    "command -v sbctl"
check "limine-redeploy hook" "test -x /usr/local/sbin/limine-redeploy"
check "smartd enabled"      "systemctl is-enabled smartd.service"
check "azure-ddns binary"   "test -x /usr/bin/azure-ddns"
check "azure-ddns service"  "systemctl cat azure-ddns.service >/dev/null 2>&1"
check "azure-ddns timer"    "systemctl is-enabled azure-ddns.timer"
check "azure-ddns NM hook"  "test -x /usr/lib/NetworkManager/dispatcher.d/90-azure-ddns"
check "azure-ddns env"      "sudo test -f /etc/azure-ddns.env"
check "azure-ddns env filled" "sudo grep -qE '^AZ_TENANT_ID=.+' /etc/azure-ddns.env"
check "azure-ddns last run OK" "sudo systemctl status azure-ddns.service 2>/dev/null | grep -q 'status=0/SUCCESS' || ! sudo test -f /etc/azure-ddns.env || ! sudo grep -qE '^AZ_TENANT_ID=.+' /etc/azure-ddns.env"
check "certbot"             "command -v certbot"
check "certbot azure plugin" "sudo test -d /opt/pipx/venvs/certbot && sudo ls /opt/pipx/venvs/certbot/lib/python*/site-packages 2>/dev/null | grep -q certbot_dns_azure"
check "LE cert (if issued)" "! test -d /etc/letsencrypt/live/metis.rhombus.rocks || sudo test -f /etc/letsencrypt/live/metis.rhombus.rocks/fullchain.pem"

echo "-- GPU compute (NVIDIA + Docker) --"
check "nvidia-470xx-dkms"     "pacman -Q nvidia-470xx-dkms"
check "nvidia-470xx-utils"    "pacman -Q nvidia-470xx-utils"
check "nvidia-container-toolkit" "pacman -Q nvidia-container-toolkit"
check "docker daemon.json: nvidia runtime" "sudo grep -q '\"nvidia\"' /etc/docker/daemon.json"

echo "-- VM stack (dockur/windows + WinApps) --"
check "docker enabled"       "systemctl is-enabled docker.service"
check "tom in docker grp"    "id -nG tom | grep -qw docker"
check "dockur compose file"  "sudo test -f /etc/dockur-windows/compose.yaml"
check "dockur OEM install.bat"   "sudo test -f /etc/dockur-windows/oem/install.bat"
check "dockur OEM setup.cmd"     "sudo test -f /etc/dockur-windows/oem/setup.cmd"
check "dockur OEM debloat.ps1"   "sudo test -f /etc/dockur-windows/oem/debloat.ps1"
check "dockur OEM UserOnce.ps1"  "sudo test -f /etc/dockur-windows/oem/UserOnce.ps1"
check "winapps source"       "test -d /opt/winapps/.git"
check "winapps-setup PATH"   "command -v winapps-setup"
check "winapps.conf docker"  "grep -q '^WAFLAVOR=\"docker\"' $HOME/.config/winapps/winapps.conf"
# Container may be absent if user passed --skip-windows-install — pass if
# absent OR if it exists and is currently running. sudo because tom may
# not be in the docker group yet in this shell.
check "windows VM (if present)" "! sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^windows$' || sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^windows$'"

echo "-- snapshots / udev / planters --"
check "snapper config /"    "sudo test -f /etc/snapper/configs/root"
check "udev usb-serial"     "test -f /etc/udev/rules.d/99-usb-serial.rules"
check "bootstrap dispatcher (dots)"   "test -f $HOME/.zshrc.d/arch-bootstrap-runner.zsh"
check "gh-auth bootstrap or done"     "test -f $HOME/.local/share/arch-setup-bootstraps/first-login.sh || test -f $HOME/.gitconfig.local"
check "ssh-signing bootstrap or done" "test -f $HOME/.local/share/arch-setup-bootstraps/ssh-signing.sh || grep -q allowedSignersFile $HOME/.gitconfig.local 2>/dev/null"
check "cloud-storage bootstrap or done" "test -f $HOME/.local/share/arch-setup-bootstraps/cloud-storage-auth.sh || (test -f $HOME/.dropbox/info.json && test -f $HOME/.local/state/rclone-bisync-initialized)"
check "fnpostinstall fn"    "test -f $HOME/.zshrc.d/arch-postinstall.zsh"

# Summary panel
echo
if (( VERIFY_FAIL == 0 )); then
    printf '\033[1;32m=== %d/%d checks passed — clean run ===\033[0m\n' "$VERIFY_PASS" "$((VERIFY_PASS + VERIFY_FAIL))"
else
    printf '\033[1;31m=== %d FAIL / %d total ===\033[0m\n' "$VERIFY_FAIL" "$((VERIFY_PASS + VERIFY_FAIL))"
    echo "Failed checks:"
    for n in "${VERIFY_FAILED_NAMES[@]}"; do
        printf '  - %s\n' "$n"
    done
fi

# Warnings panel — every warn() call accumulates into RUN_WARNINGS so
# anything that happened earlier (and probably scrolled past) is right
# here at the end of the run, in order.
if (( ${#RUN_WARNINGS[@]} > 0 )); then
    echo
    printf '\033[1;33m=== %d warning(s) during this run ===\033[0m\n' "${#RUN_WARNINGS[@]}"
    for w in "${RUN_WARNINGS[@]}"; do
        printf '  \033[1;33m[!]\033[0m %s\n' "$w"
    done
fi

# ---------- 20. Interactive follow-up (gh + bw + azure-ddns + certbot) ----------
# Up to this point the install has been hands-off (modulo fprintd's
# 13-swipe enrollment + the LUKS recovery key transcription). The next
# four steps NEED browser auth or device-code flows, so we batch them
# here at the very end where the user is right there, ready to click.
#
# Each block is independent and idempotent:
#   - skipped if already authed (token present, vault server set, env
#     filled, cert issued)
#   - on a non-TTY run (postinstall fired from CI / a script / the
#     zgenom warmup), the whole block is skipped — re-run from a TTY
#     to get the prompts.
#
# Order matters: gh first (small, fast, fails locally if no browser),
# then bw, then azure-ddns (which needs az login), then certbot
# (depends on /etc/letsencrypt/azure.ini which setup-azure-ddns.sh
# writes).
if [[ -t 0 ]]; then
    echo
    echo "=== Interactive follow-up ==="
    echo "The remaining steps need browser / device-code auth — quickly walking"
    echo "through gh, bw, azure-ddns, certbot. Press Ctrl+C any time to skip"
    echo "the rest; you can re-run individual commands manually later."
    echo

    # --- 20a. gh auth login ---
    if command -v gh >/dev/null; then
        if gh auth status >/dev/null 2>&1; then
            log "gh already authenticated — skipping login."
        else
            log "Running 'gh auth login'..."
            gh auth login || warn "gh auth login failed or cancelled — re-run manually."
        fi
        # Once gh is authed, the ssh-signing planter at
        # ~/.local/share/arch-setup-bootstraps/ssh-signing.sh wires
        # `git config commit.gpgsign true` + the SSH-signing key from
        # the Bitwarden agent. It self-deletes on success. No-op here
        # if the planter already ran.
        if [[ -f "$HOME/.local/share/arch-setup-bootstraps/ssh-signing.sh" ]]; then
            log "Running ssh-signing planter (writes ~/.gitconfig.local + commits sigfile)..."
            bash "$HOME/.local/share/arch-setup-bootstraps/ssh-signing.sh" || \
                warn "ssh-signing planter failed — see ~/.local/share/arch-setup-bootstraps/ssh-signing.sh."
        fi
    fi

    # --- 20b. bw login ---
    if command -v bw >/dev/null; then
        if bw login --check >/dev/null 2>&1; then
            log "bw already logged in — skipping."
        else
            log "Running 'bw login' (server already pointed at $BW_SERVER)..."
            bw login || warn "bw login failed or cancelled — re-run manually."
        fi
    fi

    # --- 20c. setup-azure-ddns.sh (Azure DNS provisioning + creds) ---
    if [[ -x "$HOME/setup-azure-ddns.sh" ]]; then
        # Check if creds are already filled in — env file present + non-empty
        # AZ_TENANT_ID means setup-azure-ddns.sh has run successfully at least once.
        if sudo grep -qE '^AZ_TENANT_ID=.+' /etc/azure-ddns.env 2>/dev/null; then
            log "Azure DDNS env already populated — skipping. (Re-run ~/setup-azure-ddns.sh manually to rotate secret.)"
        else
            log "Running setup-azure-ddns.sh (browser/device-code auth for az login)..."
            bash "$HOME/setup-azure-ddns.sh" || \
                warn "setup-azure-ddns.sh failed — re-run manually after fixing the underlying issue."
        fi
    else
        warn "~/setup-azure-ddns.sh not found — Azure DDNS not provisioned. Stage it from arch-setup/phase-3-arch-postinstall/setup-azure-ddns.sh."
    fi

    # --- 20d. certbot certonly (Let's Encrypt cert) ---
    # Only attempt if azure.ini was filled in by setup-azure-ddns.sh AND
    # we haven't already issued a cert for metis.rhombus.rocks.
    if [[ -x /usr/local/bin/certbot ]] || command -v certbot >/dev/null; then
        if sudo test -f /etc/letsencrypt/live/metis.rhombus.rocks/fullchain.pem; then
            log "Let's Encrypt cert for metis.rhombus.rocks already issued — skipping."
        elif sudo grep -qE '^dns_azure_sp_client_id\s*=\s*[^[:space:]]+' /etc/letsencrypt/azure.ini 2>/dev/null; then
            log "Issuing Let's Encrypt cert for metis.rhombus.rocks..."
            # certbot prompts for email + ToS unless --agree-tos -m are passed.
            # We use the user's gh email if available, fall back to interactive.
            ce_email=""
            if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
                gh_user=$(gh api user --jq '.login' 2>/dev/null) || gh_user=""
                gh_id=$(gh api user --jq '.id' 2>/dev/null) || gh_id=""
                if [[ -n "$gh_user" && -n "$gh_id" ]]; then
                    ce_email="${gh_id}+${gh_user}@users.noreply.github.com"
                fi
            fi
            ce_email_args=()
            if [[ -n "$ce_email" ]]; then
                ce_email_args=(--agree-tos -m "$ce_email" --no-eff-email)
            fi
            sudo certbot certonly \
                --authenticator dns-azure \
                --dns-azure-credentials /etc/letsencrypt/azure.ini \
                --dns-azure-propagation-seconds 60 \
                -d metis.rhombus.rocks \
                "${ce_email_args[@]}" \
                || warn "certbot certonly failed — see /var/log/letsencrypt/letsencrypt.log."
        else
            log "/etc/letsencrypt/azure.ini missing creds — skipping certbot. Run setup-azure-ddns.sh first."
        fi
    fi
else
    log "Non-TTY run — skipping interactive setup (gh/bw/azure-ddns/certbot)."
fi

echo
cat <<'POSTINSTALL_OUTRO'
====================================================================
  ONE-TIME ACTIONS (only matter the first time you run this)
====================================================================

[1] Reboot or log out → log back in at tty1; ~/.zprofile auto-launches
    Hyprland via `uwsm start hyprland-uwsm.desktop`. (greetd is installed
    but disabled per §1f — re-enable with `sudo systemctl enable --now
    greetd.service` if you want a graphical greeter back.)

[2] Bitwarden first launch — server URL + tray + autostart-off pre-seeded.
    Hyprland's exec-once already started bitwarden-desktop. Log in once
    with your master password (server URL is already https://hass4150.duckdns.org:7277).
    Then in Settings:
      - Security → "Unlock with system authentication" — enable. Binds to
        PAM + gnome-keyring at toggle time; can't be JSON-seeded.
      - SSH agent → enable. Creates ~/.bitwarden-ssh-agent.sock. As you
        add SSH-key vault items, set "Ask for SSH auth = Never" per key.
      - "Allow browser integration" — flag is pre-seeded, but toggle OFF
        then ON once in the GUI to write the per-browser native-messaging
        manifests under ~/.mozilla/native-messaging-hosts/ (or Edge /
        Chromium equivalent). Without that step the browser extension
        can't talk to the desktop.
    After SSH-agent is on with at least one key, vault + agent + sudo-PIN +
    fingerprint all unlock via login.

[3] gh + git identity:
      Already wired if the first-login planter ran (see ~/.gitconfig.local).
      Otherwise: open a new terminal and `gh auth login` once.

[4] Azure DDNS (metis.rhombus.rocks) — one-time wiring via setup-azure-ddns.sh:

        az login
        ~/setup-azure-ddns.sh           # idempotent; rotates secret on each run

      The script writes /etc/azure-ddns.env + /etc/letsencrypt/azure.ini and
      restarts azure-ddns. First call may 403 (role propagation, ~30s–5min)
      — just retry. Timer + NM hook take over after first success.

[5] Let's Encrypt cert for metis.rhombus.rocks (after step 4 succeeds):

        sudo certbot certonly \
            --authenticator dns-azure \
            --dns-azure-credentials /etc/letsencrypt/azure.ini \
            --dns-azure-propagation-seconds 60 \
            -d metis.rhombus.rocks \
            --agree-tos -m <your-email> --no-eff-email

      certbot-renew.timer is already enabled — it'll renew within 30d
      of expiry, twice daily, with no further action.

[6] Firewall:
      Already on (default deny in, allow out, 22/tcp ALLOW for ssh).
        sudo ufw status verbose          # confirm
        sudo ufw allow <port>/tcp        # add a rule
        sudo ufw delete allow <port>/tcp # remove
      Rules apply to BOTH IPv4 and IPv6 — ufw is dual-stack.

[7] Windows VM + WinApps (Parallels-Coherence-equivalent):

      Prereqs done by postinstall:
        - Docker installed + enabled, tom in docker group
        - dockur/windows compose at /etc/dockur-windows/compose.yaml
          (Win11, RAM 8G, 4 vCPU, 128G disk, RDP on 127.0.0.1:3389)
        - OEM first-boot scripts at /etc/dockur-windows/oem/, all adapted
          from the pre-2026-04-27 autounattend.xml minus the bare-metal
          bits (disk detection, BitLocker, Wi-Fi):
            install.bat   — winget-installs VS 2022 Enterprise IDE
            setup.cmd     — power off, long paths, RDP enabled, privacy/
                            consumer-features off, Edge OOBE skipped,
                            Defender fully disabled (services + Group
                            Policy + scheduled tasks + SmartScreen +
                            Set-MpPreference), sticky keys off, Default-
                            user-hive defaults (show file ext, hide
                            TaskView, taskbar align left, NumLock on,
                            mouse accel off, no ContentDeliveryManager
                            promos), RunOnce registered for UserOnce.ps1
            debloat.ps1   — removes consumer AppX (Bing/Maps/Xbox/etc.),
                            Print.Fax.Scan, and Recall feature
            UserOnce.ps1  — fires at first logon: Explorer→ThisPC, hide
                            taskbar searchbox, restart explorer.exe
        - WinApps cloned to /opt/winapps; winapps-setup on PATH
        - ~/.config/winapps/winapps.conf set to WAFLAVOR=docker, RDP
          creds Docker/Docker, RDP_IP=127.0.0.1
        - Unless --skip-windows-install was passed: VM brought up via
          'sudo docker compose up -d' EARLY in postinstall (§1a-dockur),
          so the ~15-30 min Windows install runs in parallel with the
          rest of postinstall (yay AUR builds, fingerprint enrollment,
          chezmoi apply, etc.). §15-windows blocks at end-of-postinstall
          waiting on container health=healthy.

      Verify the VM is up:
        docker ps                       # 'windows' container, healthy
        # OR open http://127.0.0.1:8006/ — direct VM display (noVNC).

      Configure WinApps (one-time, after VM is up):
        winapps-setup --user --setupAllOfficiallySupportedApps
        # Non-interactive — auto-detects installed Windows apps and
        # writes ~/.local/bin/winapps + ~/.local/share/applications/
        # *.desktop entries. For a guided run instead, omit the
        # --setupAllOfficiallySupportedApps flag for the wizard.

      VS Enterprise activation:
        On first launch of Visual Studio inside the VM, sign in with
        your MSDN / Visual Studio subscription account to activate the
        Enterprise license. Pick workloads via the VS Installer GUI
        (the OEM script installs the bare IDE only — workloads are
        multi-GB and best chosen interactively).

      Daily use: launch Windows apps from Fuzzel like any Linux app —
      they run inside the dockur container but appear as standalone
      Hyprland windows via FreeRDP.

      Stop / start the VM:
        docker stop windows             # release ~8G RAM when not in use
        docker start windows            # boots the existing Windows install
        # `restart: unless-stopped` in the compose means it auto-starts
        # at boot unless you manually stopped it.

[8] NVIDIA MX250 for CUDA compute (no display):

      Prereqs done by postinstall:
        - nvidia-470xx-dkms + nvidia-470xx-utils installed (AUR) — host
          driver + nvidia-smi for the MX250 (Pascal, capability 6.1)
        - Display modules (nvidia_drm, nvidia_modeset) blacklisted in
          chroot.sh; compute modules (nvidia, nvidia_uvm) load on demand
        - nvidia-container-toolkit installed; Docker runtime registered
          via 'nvidia-ctk runtime configure --runtime=docker'

      Verify after first reboot:
        sudo modprobe nvidia
        nvidia-smi                                  # should show 'GeForce MX250'
        docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi
                                                    # same output, from inside a container

      Pascal + CUDA-version note: the MX250 is Pascal, so containers must
      ship CUDA ≤11.x for actual GPU acceleration. CUDA-12 images compile
      out Pascal kernels and will run CPU-only. Pick container tags with
      11.x bases (e.g. nvidia/cuda:11.8.0-*, pytorch/pytorch:1.13.x-cuda11.x).

      Bare-metal CUDA on the host (only if a Linux app needs it directly):
        sudo pacman -S cuda                         # 12.x — Pascal-supported
                                                    # but app-specific.

====================================================================
POSTINSTALL_OUTRO
