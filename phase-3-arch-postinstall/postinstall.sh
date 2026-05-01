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
#     ~/.local/share/chezmoi and writes the bare Hyprland configs (split
#     fragments), waybar, swaync, fuzzel, ghostty, yazi, helix, qt5/6ct,
#     matugen pipeline + templates, helper scripts.
#   - 2-in-1 touch: iio-sensor-proxy / iio-hyprland (rotation), wvkbd (OSK),
#     hyprgrass plugin (touch gestures), libwacom (Wacom AES stylus)
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
for arg in "$@"; do
    case "$arg" in
        --no-verify|--skip-verify) SKIP_VERIFY=1 ;;
        -h|--help)
            cat <<USAGE
Usage: postinstall.sh [--no-verify]

  --no-verify    Skip the verify block at the end (faster re-runs when
                 you've just touched one section and don't want to wait
                 for ~70 checks to fan out).
USAGE
            exit 0 ;;
        *)
            warn "unknown arg: $arg (ignoring)" ;;
    esac
done

[[ "$(id -un)" == "tom" ]] || die "Run as user 'tom'."
ping -c1 -W3 archlinux.org >/dev/null || die "No network."

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
    inetutils \
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
    network-manager-applet pavucontrol blueman udiskie \
    nwg-look nwg-displays \
    qt5ct qt6ct papirus-icon-theme \
    imv zathura zathura-pdf-poppler \
    iio-sensor-proxy libwacom \
    mission-center \
    remmina freerdp \
    ufw \
    azure-cli lego \
    memtest86+ memtest86+-efi \
    smartmontools \
    sbctl \
    mise chezmoi github-cli \
    docker docker-compose docker-buildx \
    snapper snap-pac \
    cmake cpio \
    qemu-full virt-manager libvirt edk2-ovmf swtpm dnsmasq iptables-nft

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

# ---------- 1a-virt. KVM/libvirt for Windows VM + WinApps ----------
# qemu-full + virt-manager + libvirt + edk2-ovmf + swtpm + dnsmasq are
# the standard "Windows-in-a-VM" stack on Arch. WinApps (AUR §3) talks
# to a libvirt-managed Win11 VM via RDP to surface individual Windows
# apps as Linux-native windows (Parallels-Coherence-equivalent).
#
# tom needs libvirt + kvm group membership to run virt-manager without
# sudo. libvirtd.socket starts the daemon on demand when virt-manager /
# WinApps connects.
log "Enabling libvirtd socket and adding tom to libvirt + kvm groups..."
sudo systemctl enable --now libvirtd.socket
if ! id -nG tom | grep -qw libvirt; then
    sudo usermod -aG libvirt tom
    warn "Added tom to libvirt group — log out and back in for it to take effect."
fi
if ! id -nG tom | grep -qw kvm; then
    sudo usermod -aG kvm tom
    warn "Added tom to kvm group — log out and back in for it to take effect."
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
    pinpam-git
    sesh-bin
    wvkbd
    iio-hyprland-git
    powershell-bin
    awww-bin
    matugen-bin
    overskride
    wleave
    bibata-cursor-theme
    pacseek
    limine-snapper-sync
    # azure-ddns intentionally NOT here — see §4d below. We build the
    # versioned aur/azure-ddns/PKGBUILD from the source tree (no yay
    # cache hop) so the install is hermetic to the repo checkout.
    # NVIDIA compute-only stack for the MX250 (Pascal, compute capability 6.1).
    # Display modules are blacklisted in chroot.sh; these pull in the kernel
    # driver + nvidia-smi/CUDA runtime libs. Apps like Meshroom or COLMAP can
    # then use the dGPU for photogrammetry/ML without ever touching display.
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

# ---------- 3-winapps. WinApps from upstream (winapps-org/winapps) ----------
# WinApps lets you launch Windows apps from a KVM/QEMU Win11 VM as native
# Hyprland windows via RDP — the Parallels-Coherence equivalent. The KVM
# stack (qemu-full, virt-manager, libvirt, edk2-ovmf, swtpm, dnsmasq) is
# already in the pacman §1 list above.
#
# WinApps is NOT on AUR (the prior `winapps-git` package referenced
# Fmstrat/winapps which has migrated to winapps-org/winapps). We install
# from upstream source: clone to /opt/winapps, symlink the setup script
# onto PATH. Configuration (which requires a running Win11 VM) is deferred
# to Phase 4 — see §22 for the runbook entry.
#
# Idempotent: subsequent runs `git pull` to refresh; the symlink is
# unconditional (ln -sf).
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
    log "  WinApps installed. Run 'winapps-setup --user' once your Win11 VM is configured."
fi

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
    "DefaultBrowserSettingEnabled": false,
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
# succeeds first try. 538C → libfprint-goodix-53xc (older Dell blob via TOD).
# libfprint-tod-git fails to build with LTO (strips ABI symbol versioning),
# so we pre-build it with !lto before letting yay pull it as a dep.
if [[ -z "${SKIP_FPRINT:-}" ]] && command -v lsusb >/dev/null && lsusb | grep -qi '27c6:538c'; then
    # Skip the libfprint-tod-git build path entirely if fingerprints are
    # already enrolled — that means stock libfprint already supports the
    # reader and we'd just be wasting cycles on a build that fails (the
    # libfprint-tod-git PKGBUILD has a recurring 'no symbol version
    # section for versioned symbol' linker error against current stock
    # libfprint, and the fallback isn't needed when stock works).
    if command -v fprintd-list >/dev/null && sudo fprintd-list tom 2>/dev/null | grep -qi 'finger'; then
        log "Goodix 538C detected, but fingerprints already enrolled via stock libfprint — skipping libfprint-tod-git fallback."
    else
        log "Goodix 538C detected — installing libfprint-goodix-53xc (older Dell blob via TOD)..."
        if ! pacman -Q libfprint-tod-git >/dev/null 2>&1; then
            # libfprint-tod-git replaces stock libfprint; pull stock first.
            if pacman -Q libfprint >/dev/null 2>&1; then
                sudo pacman -Rdd --noconfirm libfprint || warn "Could not remove stock libfprint."
            fi
            tmpd=$(mktemp -d) && (
                cd "$tmpd" \
                && yay -G libfprint-tod-git \
                && cd libfprint-tod-git \
                && sed -i 's|^options=(|options=(!lto |' PKGBUILD \
                && makepkg -si --noconfirm
            ) || warn "libfprint-tod-git build failed — fingerprint will not work."
            rm -rf "$tmpd"
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
        # If libfprint-tod-git is already in (e.g. 538C path above), libfprint-git
        # would conflict — skip the fallback and surface a manual diagnostic hint.
        if pacman -Q libfprint-tod-git >/dev/null 2>&1; then
            warn "libfprint-tod-git is installed (Goodix-specific path) — skipping libfprint-git fallback."
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
# Three surfaces — see docs/reinstall-planning.md §5.
# greetd: PIN intentionally excluded (cold-boot wants full credential
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
# Design invariant: fingerprint is ALWAYS an option and NEVER required.
# User's finger can only physically reach the reader at cold boot (the
# laptop goes under the desk after login). Primary auth at sudo/hyprlock
# is therefore PIN (fast, one-handed, works docked); fingerprint is still
# wired in as a second-position sufficient module with a short timeout so
# a user who did leave a finger within reach can still use it — but PIN
# prompts first, so the common case never sees a blocking finger prompt.
#
#   sudo     : PIN → fingerprint(5s) → password. PIN primary; finger as a
#              5s-timeout shortcut; pam_unix via system-auth as fallback.
#   hyprlock : PIN → fingerprint(5s) → password. Same shape; `login`
#              include provides pam_unix fallback.
#
# Module name quirk: pinpam-git ships its module as `libpinpam.so` (not
# the expected `pam_pinpam.so`). PAM resolves bare names against
# `/usr/lib/security/`, so we reference `libpinpam.so` literally — the
# old `pam_pinpam.so` reference dlopen-failed silently and PAM treated
# it as a faulty module, which is what kept PIN auth from ever working
# pre-2026-04-22 even when `pinutil setup` had succeeded.
#
# pinpam returns AUTHINFO_UNAVAIL when no PIN is provisioned, so
# 'sufficient' falls through cleanly to pam_fprintd/pam_unix — first-boot
# (pre-`pinutil setup`) still works.
#
# pam_fprintd options: `max-tries=5` = up to five swipes per auth
# attempt (a finger can land funny on the first couple tries and
# still recover without falling through to password);
# `timeout=20` at sudo/hyprlock = give up after 20s of no finger and
# fall through to the password prompt. 20s is comfortable on the
# Inspiron 7786 (fingerprint reader is in the power button — needs a
# moment to reach for); shorter values felt rushed in real use.
#
# Lid-state escape hatch: when the laptop lid is closed (i.e. docked
# under a desk, fingerprint reader physically unreachable), we want
# password auth IMMEDIATELY rather than burning 20s waiting for a
# finger that can't get there. /usr/local/bin/lid-closed exits 0 when
# closed; with PAM control `[success=1 default=ignore]` PAM jumps one
# line forward on success (skipping pam_fprintd entirely) and just
# continues normally on failure (lid open → try fprintd as usual).
#
# NEVER remove pam_unix from the stack via `system-auth`/`system-login`/
# `login` includes — that's the last-resort password path.
#
# Fully idempotent: tee overwrites with identical bytes on re-run.
log "Writing /usr/local/bin/lid-closed (PAM helper for dock-aware fprintd skip)..."
sudo tee /usr/local/bin/lid-closed >/dev/null <<'LIDEOF'
#!/bin/sh
# Exit 0 iff the laptop lid is closed (read /proc/acpi/button/lid/*/state).
# PAM uses the exit code to decide whether to skip pam_fprintd.
# No lid sensor on this machine? Assume open → exit 1 → fprintd tried.
LID_FILE=$(ls /proc/acpi/button/lid/*/state 2>/dev/null | head -1)
[ -z "$LID_FILE" ] && exit 1
state=$(awk '{print $NF}' "$LID_FILE")
[ "$state" = closed ] && exit 0 || exit 1
LIDEOF
sudo chmod 755 /usr/local/bin/lid-closed

log "Writing PAM stacks (lid-aware: fprintd if open, PIN if closed, password fallback)..."

# Design (rewritten 2026-04-30 per user spec): lid state determines
# which factor is primary. The "wrong" factor is SKIPPED entirely —
# not attempted, not even prompted for. Password is always the final
# fallback so a broken TPM or unreadable finger doesn't lock the user
# out.
#
# Behavior:
#   Lid OPEN   → fprintd primary (max-tries=3, timeout=15) → password
#   Lid CLOSED → libpinpam primary (its own retry loop)    → password
#
# Same stack across sudo / hyprlock / polkit-1 / login (any auth surface
# the user hits day-to-day). Only greetd is different — it uses its
# own template at system-files/pam.d/greetd because cold-boot wants
# password-or-fingerprint without depending on TPM (per Windows Hello
# pattern). greetd is currently disabled (§1f); template stays in case
# of revival.
#
# Control flow walk (one stack, four lines):
#   1. pam_exec /usr/local/bin/lid-closed
#        success=1   → jump 1 line forward (skip fprintd)
#        default     → ignore (lid open, fall through to fprintd)
#   2. pam_fprintd.so max-tries=3 timeout=15
#        success=done → auth complete
#        default      → jump 1 line forward (skip libpinpam, go to pam_unix)
#                       i.e. lid open + finger fail → password, NOT PIN
#   3. libpinpam.so
#        success=done → auth complete
#        default      → ignore (lid closed + PIN fail → password)
#   4. pam_unix.so try_first_pass nullok
#        required     → password is always the last word
#
# Pre-flight: ensure /usr/local/bin/lid-closed exists (created above by
# the lid-closed installer — sudo tee block earlier in §7a).
#
# Recovery: if PAM is borked and you can't sudo, log into a different
# TTY (Ctrl+Alt+F2 then `root` + install-time root password), then
# edit /etc/pam.d/<broken-file>. Test with `sudo -k && sudo true`
# from a fresh shell after every edit.

# The actual stack — emit once into a temp string, then tee to all four
# files so they stay byte-identical.
read -r -d '' LID_AWARE_STACK <<'LIDPAMEOF' || true
#%PAM-1.0
# arch-setup: lid-aware auth. Fprintd if lid open, PIN if closed,
# password fallback always. See postinstall.sh §7a for design.
auth        [success=1 default=ignore]    pam_exec.so quiet /usr/local/bin/lid-closed
auth        [success=done default=1]      pam_fprintd.so max-tries=3 timeout=15
auth        [success=done default=ignore] libpinpam.so
auth        required                       pam_unix.so try_first_pass nullok
account     include     system-auth
session     include     system-auth
LIDPAMEOF

for pam_file in sudo hyprlock polkit-1 login; do
    log "  /etc/pam.d/${pam_file}"
    printf '%s\n' "$LID_AWARE_STACK" | sudo tee "/etc/pam.d/${pam_file}" >/dev/null
done

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

# ~/.ssh/config's IdentityAgent directive is consulted by `ssh(1)` only — NOT
# by `ssh-add(1)`. The SSH-signing planter (below) calls `ssh-add -L` to
# discover the Bitwarden-surfaced pubkey, which requires $SSH_AUTH_SOCK to
# point at the Bitwarden socket. Export it for every shell session via a
# .zshrc.d drop-in. We only set it when the socket actually exists so nothing
# breaks on a fresh boot before Bitwarden desktop has started.
mkdir -p "$HOME/.zshrc.d"
cat > "$HOME/.zshrc.d/bitwarden-ssh-agent.zsh" <<'EOF'
# Route ssh-add / ssh to the Bitwarden SSH agent socket, if present.
if [[ -S "$HOME/.bitwarden-ssh-agent.sock" ]]; then
    export SSH_AUTH_SOCK="$HOME/.bitwarden-ssh-agent.sock"
fi
EOF

# ---------- 9. GitHub identity (one-shot if gh already authed) ----------
# The planter scripts that handle bw login / gh auth login / SSH-signing
# wire-up live in rhombu5/dots as
#   ~/.local/share/arch-setup-bootstraps/{first-login,ssh-signing}.sh
# applied by §13's chezmoi apply and dispatched by
#   ~/.zshrc.d/arch-bootstrap-runner.zsh
# on each interactive shell. Each script self-checks its precondition
# and self-deletes on success.
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
# `chezmoi init --apply` clones the repo into ~/.local/share/chezmoi and
# applies in one step. Idempotent: a second run is a no-op when source
# matches dest. Requires network — we assume it's up by §13 (the user
# connected via iwctl in §0, and pacman/yay in earlier sections proved it).
#
# Clone over HTTPS so the bootstrap doesn't depend on Bitwarden being
# unlocked yet (postinstall runs from a TTY before Hyprland comes up;
# bitwarden-desktop and its ssh-agent socket aren't available). Once the
# repo is on disk, rewrite the remote to SSH so future pushes/pulls (made
# from a logged-in Hyprland session with Bitwarden unlocked) just work.
DOTS_REPO_HTTPS="https://github.com/rhombu5/dots.git"
DOTS_REPO_SSH="git@github.com:rhombu5/dots.git"
DOTS_SRC="$HOME/.local/share/chezmoi"

if ! command -v chezmoi >/dev/null; then
    warn "chezmoi not installed — was it dropped from §1 pacman list?"
    warn "  Skipping dotfile apply — Hyprland will start with empty config."
elif [[ -d "$DOTS_SRC/.git" ]]; then
    log "chezmoi source already present at ~/.local/share/chezmoi — pulling + applying..."
    git -C "$DOTS_SRC" remote set-url origin "$DOTS_REPO_SSH"
    git -C "$DOTS_SRC" pull --ff-only \
        || warn "git pull on chezmoi source failed — applying current checkout."
    chezmoi apply --force \
        || warn "chezmoi apply reported issues — check 'chezmoi status' and 'chezmoi diff'."
else
    log "Cloning rhombu5/dots into ~/.local/share/chezmoi and applying..."
    if chezmoi init --apply "$DOTS_REPO_HTTPS"; then
        git -C "$DOTS_SRC" remote set-url origin "$DOTS_REPO_SSH"
    else
        warn "chezmoi init --apply failed — Hyprland will start with empty config. Re-run 'chezmoi init --apply $DOTS_REPO_HTTPS' once network is up."
    fi
fi

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
    else
        log "  hyprpm add hyprgrass (touch gestures)..."
        if ! hyprpm list 2>/dev/null | grep -qi hyprgrass; then
            hyprpm add https://github.com/horriblename/hyprgrass \
                || warn "hyprgrass build failed — touch gestures will be unavailable until you re-run 'hyprpm add https://github.com/horriblename/hyprgrass' manually."
        else
            log "  hyprgrass already added — skipping."
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
    fi
    # Hyprspace TODO — see plugins.conf in rhombu5/dots. Don't reintroduce blindly.
fi

# Ghostty config is matugen-themed via the rhombu5/dots chezmoi tree (§13).
# greetd-regreet system config is installed by install.sh from
# phase-3-arch-postinstall/system-files/greetd/. No separate §14 / §15 needed.

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

# ---------- 19. verify ----------
if (( SKIP_VERIFY == 1 )); then
    log "Skipping verify (--no-verify). Re-run without the flag for the full sweep."
    echo
    echo "Log out and back in (or reboot) to start Hyprland via greetd."
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
check "hyprgrass plugin"    "hyprpm list 2>/dev/null | grep -q hyprgrass"
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
check "pinpam .so present"   "test -f /usr/lib/security/libpinpam.so"
check "PIN actually persisted" "! pinutil test < /dev/null 2>&1 | grep -q NoPinSet"
check "lid-closed helper"    "test -x /usr/local/bin/lid-closed"
# Lid-aware stack across sudo/hyprlock/polkit-1/login (per §7a, 2026-04-30 rewrite).
for _f in sudo hyprlock polkit-1 login; do
    check "lid-aware PAM in /etc/pam.d/${_f}" "grep -q 'pam_exec.so quiet /usr/local/bin/lid-closed' /etc/pam.d/${_f} && grep -q libpinpam /etc/pam.d/${_f} && grep -q pam_fprintd /etc/pam.d/${_f} && grep -q pam_unix /etc/pam.d/${_f}"
done
unset _f
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

echo "-- VM stack (qemu/libvirt/winapps) --"
check "qemu installed"       "pacman -Q qemu-full"
check "virt-manager"         "command -v virt-manager"
check "libvirtd.socket"      "systemctl is-enabled libvirtd.socket"
check "tom in libvirt grp"   "id -nG tom | grep -qw libvirt"
check "tom in kvm grp"       "id -nG tom | grep -qw kvm"
check "winapps source"       "test -d /opt/winapps/.git"
check "winapps-setup PATH"   "command -v winapps-setup"

echo "-- snapshots / udev / planters --"
check "snapper config /"    "sudo test -f /etc/snapper/configs/root"
check "udev usb-serial"     "test -f /etc/udev/rules.d/99-usb-serial.rules"
check "bootstrap dispatcher (dots)"   "test -f $HOME/.zshrc.d/arch-bootstrap-runner.zsh"
check "gh-auth bootstrap or done"     "test -f $HOME/.local/share/arch-setup-bootstraps/first-login.sh || test -f $HOME/.gitconfig.local"
check "ssh-signing bootstrap or done" "test -f $HOME/.local/share/arch-setup-bootstraps/ssh-signing.sh || grep -q allowedSignersFile $HOME/.gitconfig.local 2>/dev/null"
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

[1] Reboot or log out → log back in via greetd to start Hyprland.

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
        - qemu-full + virt-manager + libvirt + edk2-ovmf + swtpm + dnsmasq
          installed
        - libvirtd.socket enabled
        - tom in libvirt + kvm groups (log out + back in to take effect)
        - WinApps source cloned to /opt/winapps (winapps-org/winapps);
          'winapps-setup' is on PATH. Run it once the VM is up.

      One-time Windows install via virt-manager:
        1. Download a Win11 ISO (microsoft.com/software-download/windows11)
           — install with virt-manager, name the VM 'RDPWindows' (matches
           WinApps default).
        2. Inside the VM: enable Remote Desktop, set a local user with a
           password, install your Windows apps (3DF Zephyr, Office, etc.).
        3. Snapshot the VM (virt-manager → Snapshots) before WinApps wires.

      Configure WinApps (one-time):
        winapps-setup --user --setupAllOfficiallySupportedApps
        # Non-interactive — auto-installs all officially supported app
        # launchers WinApps can detect. For a guided run instead, just
        # `winapps-setup --user` (wizard).
        # Output: ~/.local/bin/winapps + ~/.local/share/applications/
        # *.desktop entries that launch each Windows app as a Linux window.

      Daily use: launch Windows apps from Fuzzel like any Linux app —
      they run inside the VM but appear as standalone Hyprland windows.

[8] NVIDIA MX250 for CUDA compute (no display):

      Prereqs done by postinstall:
        - nvidia-470xx-dkms + nvidia-470xx-utils installed (AUR)
        - Display modules (nvidia_drm, nvidia_modeset) blacklisted
        - Compute modules (nvidia, nvidia_uvm) load on demand

      Verify after first reboot:
        sudo modprobe nvidia
        nvidia-smi                       # should show 'GeForce MX250'

      Install CUDA toolkit when needed (e.g. for Meshroom or COLMAP):
        sudo pacman -S cuda             # current 12.x — may have Pascal
                                        # caveats; check Meshroom/COLMAP
                                        # docs for the supported CUDA range
                                        # before switching.

      Photogrammetry apps NOT installed by default — pick when ready:
        Meshroom (AliceVision)  — yay -S meshroom
        COLMAP                  — sudo pacman -S colmap

====================================================================
POSTINSTALL_OUTRO
