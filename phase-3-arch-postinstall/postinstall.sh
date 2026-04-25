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
#   - metis-ddns: bash + systemd timer that keeps metis.rhombus.rocks A+AAAA
#     in sync with this host's public IPs against Azure DNS (no maintained
#     off-the-shelf option exists). Stubs /etc/metis-ddns.env on first run
#     — fill in SP creds once, then enable the timer.
#   - Claude Code CLI + bash completion
#   - Goodix-aware fingerprint enrollment (VID 27C6 detected → detailed diag on fail)
#   - pinpam TPM-PIN + PAM wiring for sudo/polkit/hyprlock
#   - Bitwarden SSH agent in ~/.ssh/config
#   - gh identity + signing key registration (first-login planter if no token yet)
#   - zgenom + p10k + the full fnwsl plugin set (history/completion/PATH dedup
#     brought in from fnwsl; WSL-specific pieces dropped). p10k config itself
#     is authored by the user via `p10k configure` on first shell launch —
#     no pre-shipped ~/.p10k.zsh.
#   - chezmoi apply against /root/arch-setup/dotfiles — writes the bare
#     Hyprland configs (split fragments), waybar, swaync, fuzzel, ghostty,
#     yazi, helix, qt5/6ct, matugen pipeline + templates, helper scripts.
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
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

# retry <cmd> [args...] — 4 attempts, exponential backoff (2/4/8s between).
# For network ops that flap (AUR, GitHub, PyPI). pacman/yay are already
# multi-mirror so they don't need this.
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
    zsh tmux helix \
    bat fd ripgrep eza lsd btop jq fzf zoxide direnv \
    sd go-yq xh \
    man-db man-pages pkgfile tldr \
    wl-clipboard grim slurp \
    xdg-user-dirs pipewire pipewire-pulse pipewire-jack wireplumber \
    noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd ttf-firacode-nerd \
    bitwarden bitwarden-cli \
    ghostty fuzzel cliphist satty hyprshot \
    nautilus yazi \
    hyprland hyprlock hypridle hyprpolkitagent hyprpicker \
    waybar swaync swayosd \
    xdg-desktop-portal-gtk xdg-desktop-portal-hyprland \
    network-manager-applet pavucontrol \
    nwg-look nwg-displays \
    qt5ct qt6ct papirus-icon-theme \
    imv zathura zathura-pdf-poppler \
    iio-sensor-proxy libwacom \
    mission-center \
    remmina freerdp \
    ufw \
    azure-cli certbot python-pipx \
    memtest86+ memtest86+-efi \
    smartmontools \
    sbctl \
    mise chezmoi github-cli \
    docker docker-compose docker-buildx \
    snapper snap-pac

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
yay -S --noconfirm --needed \
    visual-studio-code-bin \
    microsoft-edge-stable-bin \
    claude-desktop-native \
    pinpam-git \
    sesh-bin \
    wvkbd \
    iio-hyprland-git \
    powershell-bin \
    awww-bin \
    matugen-bin \
    overskride \
    wleave \
    bibata-cursor-theme \
    pacseek \
    limine-snapper-sync

# ---------- 3a. certbot-dns-azure plugin (pipx — not packaged for Arch) ----------
# certbot-dns-azure is PyPI-only: not in extra, not in AUR, not community-
# repackaged. Arch's system python blocks `pip install` via PEP 668, so we
# install certbot + the plugin into an isolated pipx venv at /opt/pipx, then
# override certbot-renew.service to run the pipx binary so renewals see the
# plugin. The pacman certbot package stays installed (it ships the systemd
# units we override). /usr/local/bin/certbot wins PATH precedence over
# /usr/bin/certbot so the interactive `sudo certbot certonly ...` call from
# runbook §3e-ter picks up the plugin-equipped binary.
log "Installing certbot-dns-azure plugin via pipx (not packaged for Arch)..."
if ! sudo test -x /opt/pipx/bin/certbot; then
    sudo install -d -m 755 /opt/pipx
    retry sudo env PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/opt/pipx/bin \
        pipx install certbot
fi
if ! sudo test -d /opt/pipx/venvs/certbot/lib/python*/site-packages/certbot_dns_azure; then
    retry sudo env PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/opt/pipx/bin \
        pipx inject certbot certbot-dns-azure
fi
sudo ln -sf /opt/pipx/bin/certbot /usr/local/bin/certbot
sudo install -d /etc/systemd/system/certbot-renew.service.d
sudo tee /etc/systemd/system/certbot-renew.service.d/override.conf >/dev/null <<'CBOVEREOF'
[Service]
ExecStart=
ExecStart=/opt/pipx/bin/certbot -q renew
CBOVEREOF
sudo systemctl daemon-reload

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

# ---------- 4d. metis-ddns: Azure DNS dynamic updater ----------
# Keeps metis.rhombus.rocks A+AAAA records pointed at this host's current
# public IPv4/IPv6. Nothing maintained off-the-shelf supports Azure DNS
# (ddclient/inadyn lack a provider), so we ship a small bash script + systemd
# timer + NM-dispatcher hook. See phase-3-arch-postinstall/metis-ddns/.
#
# The env file at /etc/metis-ddns.env (mode 600) holds the service-principal
# credentials. We stub it on first install with the template — user must
# fill in the actual TENANT/CLIENT/SECRET/SUBSCRIPTION/RG once via
# `az ad sp create-for-rbac --name metis-ddns --role "DNS Zone Contributor"
# --scopes <zone-id>` and then `sudo systemctl start metis-ddns.service`.
DDNS_DIR="$SCRIPT_DIR/metis-ddns"
if [[ -d "$DDNS_DIR" ]]; then
    log "Installing metis-ddns script + systemd unit + timer + NM hook..."
    sudo install -m 755 "$DDNS_DIR/metis-ddns"             /usr/local/bin/metis-ddns
    sudo install -m 644 "$DDNS_DIR/metis-ddns.service"     /etc/systemd/system/metis-ddns.service
    sudo install -m 644 "$DDNS_DIR/metis-ddns.timer"       /etc/systemd/system/metis-ddns.timer
    sudo install -d -m 755 /etc/NetworkManager/dispatcher.d
    sudo install -m 755 "$DDNS_DIR/90-metis-ddns"          /etc/NetworkManager/dispatcher.d/90-metis-ddns
    sudo install -m 644 "$DDNS_DIR/metis-ddns.env.template" /etc/metis-ddns.env.template
    if [[ ! -f /etc/metis-ddns.env ]]; then
        sudo install -m 600 -o root -g root "$DDNS_DIR/metis-ddns.env.template" /etc/metis-ddns.env
        warn "Stubbed /etc/metis-ddns.env — fill in service principal creds, then:"
        warn "    sudo systemctl start metis-ddns.service && sudo journalctl -u metis-ddns -n 20"
    fi
    sudo install -d -m 755 /var/lib/metis-ddns
    # Stub Let's Encrypt credentials for the dns-azure plugin (same SP works
    # for both DDNS record updates and dns-01 challenge TXT records).
    sudo install -d -m 755 /etc/letsencrypt
    sudo install -m 644 "$DDNS_DIR/letsencrypt-azure.ini.template" /etc/letsencrypt/azure.ini.template
    if [[ ! -f /etc/letsencrypt/azure.ini ]]; then
        sudo install -m 600 -o root -g root "$DDNS_DIR/letsencrypt-azure.ini.template" /etc/letsencrypt/azure.ini
    fi
    sudo systemctl daemon-reload
    # Enable the timer (don't --now: env file likely empty on first pass; the
    # timer's first tick will no-op-fail until creds are filled in, which is
    # fine — we just don't want the FAILED state to scream at first boot).
    sudo systemctl enable metis-ddns.timer
    # Enable certbot's renewal timer too — no-op until a cert exists.
    sudo systemctl enable certbot-renew.timer 2>/dev/null || true
else
    warn "metis-ddns/ sidecar dir missing — Azure DDNS not installed."
fi

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
    yay -S --noconfirm --needed libfprint-goodix-53xc || \
        warn "libfprint-goodix-53xc install failed — see AUR comments."
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
    log "Enrolling ${#FINGERS_TO_ENROLL[@]} fingerprints (~5 taps each)..."
    fp_any_success=0
    for finger in "${FINGERS_TO_ENROLL[@]}"; do
        if sudo fprintd-list tom 2>/dev/null | grep -q "$finger"; then
            log "  $finger: already enrolled — skipping."
            fp_any_success=1
            continue
        fi
        log "  $finger: touch power button ~5 times..."
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
            if yay -S --noconfirm --needed libfprint-git && sudo systemctl restart fprintd; then
                sudo fprintd-enroll -f right-index-finger tom || warn "libfprint-git retry also failed — likely unsupported reader. See https://fprint.freedesktop.org/supported-devices.html"
            else
                warn "libfprint-git install failed — see https://fprint.freedesktop.org/supported-devices.html"
            fi
        fi
    fi
fi

# ---------- 7. pinpam TPM-PIN setup ----------
# pinutil setup asks for a fresh PIN and stores it in TPM NVRAM.
# PAM wiring for PIN lives in §7a below (sudo + hyprlock only — not greetd).
if command -v pinutil >/dev/null; then
    if [[ -z "${SKIP_PIN:-}" ]]; then
        # `pinutil setup` reads the new PIN interactively from stdin. Without a
        # TTY (postinstall piped over ssh, or run from a headless systemd unit)
        # it'd block forever with no way to type. Skip and warn instead.
        if [[ -t 0 ]]; then
            log "Setting up TPM-backed PIN (follow prompt; 6+ chars recommended)..."
            # tee lets the user see pinutil's prompts while we capture output
            # for the "already has a PIN" check. The `if` wrapper disables
            # errexit (otherwise pipefail + set -e kills the script on pinutil's
            # non-zero exit before we can check for idempotency).
            if sudo pinutil setup 2>&1 | tee /tmp/pinutil-setup.log; then
                log "TPM PIN set (per pinutil)."
            elif grep -q 'already has a PIN' /tmp/pinutil-setup.log; then
                log "TPM PIN already set — skipping (idempotent re-run)."
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
                warn "  sudo pinutil delete && sudo pinutil setup"
            fi
        else
            warn "No TTY — skipping 'pinutil setup'. Run it manually after login: sudo pinutil setup"
        fi
    fi
else
    warn "pinutil not found; skipping TPM-PIN setup."
fi

# ---------- 7a. PAM stacks for sudo / hyprlock ----------
# Two surfaces, two stacks here — see docs/reinstall-planning.md §5.
# (greetd's PAM stack is installed by chroot.sh from
# phase-3-arch-postinstall/system-files/pam.d/greetd; PIN is intentionally
# excluded from greetd because cold-boot wants full credential per the
# Windows Hello pattern.)
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
# pam_fprintd options: `max-tries=1` = one finger attempt then fail;
# `timeout=5` at sudo/hyprlock = give up after 5s of no finger and move
# on to the password prompt, so Ctrl+C isn't needed.
#
# NEVER remove pam_unix from the stack via `system-auth`/`system-login`/
# `login` includes — that's the last-resort password path.
#
# Fully idempotent: tee overwrites with identical bytes on re-run.
log "Writing PAM stacks for sudo / hyprlock..."

# sudo: PIN → fingerprint(5s) → password.
sudo tee /etc/pam.d/sudo >/dev/null <<'SUDOPAMEOF'
#%PAM-1.0
# arch-setup: PIN primary, fingerprint optional (5s timeout), password fallback.
# See postinstall.sh §7a.
auth        sufficient  libpinpam.so
auth        sufficient  pam_fprintd.so              max-tries=1 timeout=5
auth        include     system-auth
account     include     system-auth
session     include     system-auth
SUDOPAMEOF

# hyprlock: PIN → fingerprint(5s) → password. Finger is unlikely to be
# reachable while the laptop is docked, but including it preserves the
# "any one of three methods" invariant and only costs a 5s timeout in
# the uncommon case where the user Ctrl+C'd past the PIN prompt.
sudo tee /etc/pam.d/hyprlock >/dev/null <<'HYPRLOCKPAMEOF'
#%PAM-1.0
# arch-setup: PIN primary, fingerprint optional (5s timeout), password fallback.
# See postinstall.sh §7a.
auth        sufficient  libpinpam.so
auth        sufficient  pam_fprintd.so              max-tries=1 timeout=5
auth        include     login
HYPRLOCKPAMEOF

# ---------- 7.5 LUKS TPM2 autounlock (FDE per decisions.md §Q11) ----------
# install.sh sets the LUKS passphrase (key slot 0) at install time; this
# step binds the master key to TPM2 PCRs 0+7 as an additional slot so the
# next boot is silent. The passphrase stays as the recovery fallback —
# needed if PCR values drift (firmware update, bootloader swap, moving the
# disk to a different machine). Idempotent: skips if a TPM2 slot is already
# enrolled, so re-running postinstall doesn't pile up duplicate slots.
#
# Why PCRs 0+7:
#   PCR 0 measures UEFI firmware code.
#   PCR 7 measures the Secure Boot policy (on/off + key hashes).
# Both are stable across reboots of the same bootloader configuration but
# change when firmware is updated or Secure Boot state is toggled — exactly
# the "the boot chain was tampered with" signal we want to gate unsealing
# on. PCRs 4/5/8/9 (bootloader + kernel measurements) change every kernel
# upgrade, which would force the passphrase after every `pacman -Syu`.
# cryptroot AND cryptswap are TPM-enrolled. cryptswap is opened in the
# initramfs (crypttab.initramfs) BEFORE resume runs, so it needs a TPM
# slot or every boot prompts for the LUKS passphrase to unlock swap.
# cryptvar auto-unlocks from a keyfile on the (TPM-unlocked) cryptroot —
# a second TPM slot would burn LUKS budget without adding at-rest
# protection (the keyfile is only readable post-cryptroot-unlock).
if [[ -c /dev/tpm0 || -c /dev/tpmrm0 ]] && [[ -z "${SKIP_TPM_LUKS:-}" ]]; then
    # Enroll TPM2 on BOTH cryptroot and cryptswap — both live in
    # crypttab.initramfs (cryptswap is there so `resume=` can read the
    # hibernate image pre-pivot). cryptvar opens from a keyfile on
    # the (TPM-unlocked) cryptroot, so it doesn't need its own TPM slot.
    for partlabel in ArchRoot ArchSwap; do
        dev="/dev/disk/by-partlabel/$partlabel"
        if [[ ! -b "$dev" ]]; then
            warn "$dev not found — skipping TPM enroll for $partlabel."
            continue
        fi
        if sudo systemd-cryptenroll "$dev" 2>/dev/null | awk 'NR>1 && $2=="tpm2"{f=1} END{exit !f}'; then
            log "TPM2 already enrolled on $partlabel — skipping."
        else
            log "Enrolling TPM2 autounlock for $partlabel (enter the LUKS passphrase when prompted)..."
            sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 "$dev" \
                || warn "TPM enroll failed for $partlabel — boot still works with passphrase."
        fi
    done

    # After enrollment, flip `tpm2-device=auto` on in /etc/crypttab.initramfs
    # for each volume that now has a TPM2 slot. chroot.sh wrote both lines
    # WITHOUT that option — pre-enrollment, it blocks boot waiting for a
    # non-existent slot (systemd#39049, #36293). Idempotent: the sed only
    # matches lines still ending in `luks,discard`.
    _crypttab_changed=0
    for pair in "cryptroot:ArchRoot" "cryptswap:ArchSwap"; do
        _crypt_name="${pair%:*}"
        _partlabel="${pair#*:}"
        _dev="/dev/disk/by-partlabel/$_partlabel"
        [[ -b "$_dev" ]] || continue
        if sudo systemd-cryptenroll "$_dev" 2>/dev/null | awk 'NR>1 && $2=="tpm2"{f=1} END{exit !f}'; then
            if sudo grep -qE "^${_crypt_name} .*luks,discard$" /etc/crypttab.initramfs; then
                log "Adding tpm2-device=auto to $_crypt_name in /etc/crypttab.initramfs..."
                sudo sed -i "/^${_crypt_name} /s/luks,discard\$/luks,discard,tpm2-device=auto/" /etc/crypttab.initramfs
                _crypttab_changed=1
            fi
        fi
    done
    unset _crypt_name _partlabel _dev pair
    if (( _crypttab_changed )); then
        log "Regenerating initramfs (mkinitcpio -P) so TPM2 unlock takes effect next boot..."
        sudo mkinitcpio -P
    fi
    unset _crypttab_changed
else
    warn "No TPM device (or SKIP_TPM_LUKS set) — boot will continue to prompt for the LUKS passphrase."
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

# Pre-seed the Bitwarden desktop app's environmentUrls so the first launch
# lands on your self-hosted server (no need to pick "Self-hosted" from the
# dropdown). Structure is documented-minimal: if Bitwarden desktop rejects
# it, just pick "Self-hosted" at the login screen and enter the URL there.
BW_DESKTOP_DIR="$HOME/.config/Bitwarden"
if [[ ! -f "$BW_DESKTOP_DIR/data.json" ]]; then
    mkdir -p "$BW_DESKTOP_DIR"
    cat > "$BW_DESKTOP_DIR/data.json" <<EOF
{
  "global": {
    "environmentUrls": {
      "base": "$BW_SERVER"
    }
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

# ---------- 9. GitHub identity + SSH-signing planter ----------
# Two-phase planter:
#   Phase A (auth):    bw login -> gh auth login -> write name/email in ~/.gitconfig.local.
#                      Self-deletes planter A once gh auth status is OK.
#   Phase B (signing): plants ~/.zshrc.d/arch-ssh-signing.zsh which checks
#                      `ssh-add -L` every shell until it returns a pubkey from
#                      the Bitwarden SSH agent. When it does, writes the
#                      allowedSignersFile + signingkey stanza and registers
#                      the pubkey with GitHub via `gh ssh-key add`. Self-deletes
#                      once allowed_signers is populated and gh accepts the key.
#
# This decouples identity setup (needs gh only) from SSH signing (needs the
# Bitwarden desktop app to be running with the SSH-agent toggle enabled and
# at least one "SSH key" vault item loaded).

mkdir -p "$HOME/.zshrc.d"

# Phase B planter — always written; it's idempotent and self-deletes on success.
cat > "$HOME/.zshrc.d/arch-ssh-signing.zsh" <<'SIGEOF'
# arch: wait for Bitwarden SSH agent to expose a key, then wire git signing (self-deleting)
# Explicitly set SSH_AUTH_SOCK to the Bitwarden socket here (rather than rely
# on .zshrc.d load order) so we never wire signing to the wrong agent's key
# if some future drop-in sets a competing SSH_AUTH_SOCK first.
if [[ -t 0 ]] && command -v gh &>/dev/null && gh auth status &>/dev/null \
   && [[ -S "$HOME/.bitwarden-ssh-agent.sock" ]]; then
  _pubkey=$(SSH_AUTH_SOCK="$HOME/.bitwarden-ssh-agent.sock" ssh-add -L 2>/dev/null | head -1)
  if [[ "$_pubkey" == ssh-* ]]; then
    _gh_user=$(gh api user --jq '.login' 2>/dev/null) || _gh_user=""
    _gh_id=$(gh api user --jq '.id' 2>/dev/null) || _gh_id=""
    if [[ -n "$_gh_user" && -n "$_gh_id" ]]; then
      _gh_email="${_gh_id}+${_gh_user}@users.noreply.github.com"
      echo "${_gh_email} ${_pubkey}" > ~/.ssh/allowed_signers
      # Append signing stanza if not already present
      if ! grep -q 'gpgsign = true' ~/.gitconfig.local 2>/dev/null; then
        cat >> ~/.gitconfig.local <<GITEOF
[gpg]
    format = ssh
[gpg "ssh"]
    allowedSignersFile = ~/.ssh/allowed_signers
    defaultKeyCommand = ssh-add -L
[commit]
    gpgsign = true
[tag]
    gpgsign = true
GITEOF
      fi
      _tmp=$(mktemp); printf '%s\n' "$_pubkey" > "$_tmp"
      gh ssh-key add "$_tmp" --title "$(hostname) - arch" --type authentication 2>/dev/null || true
      gh ssh-key add "$_tmp" --type signing 2>/dev/null || true
      rm -f "$_tmp"
      echo "arch: wired SSH signing with pubkey from Bitwarden SSH agent."
      rm -f ~/.zshrc.d/arch-ssh-signing.zsh
    fi
    unset _gh_user _gh_id _gh_email _tmp
  fi
  unset _pubkey
fi
SIGEOF

# Phase A planter — only if gh isn't already authed.
#
# CRITICAL: use `git config --file` for individual keys, NOT `cat > ~/.gitconfig.local`.
# Earlier versions did `cat >` which clobbered the whole file on every postinstall
# re-run — wiping the [commit]/gpg.ssh signing block that Phase B below appends,
# plus any hand-added user config. `git config --file` surgically updates user.name
# and user.email, leaving other sections intact.
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
    log "gh not authed yet — planting first-login auth script."
    cat > "$HOME/.zshrc.d/arch-first-login.zsh" <<'AUTHEOF'
# arch: one-time bw+gh login (self-deleting)
if [[ -t 0 ]]; then
  if command -v bw &>/dev/null && ! bw login --check &>/dev/null; then
    echo ""
    echo "=== arch: Bitwarden CLI login (for secrets scripting) ==="
    bw login || true
  fi
  if command -v gh &>/dev/null && ! gh auth status &>/dev/null; then
    echo ""
    echo "=== arch: GitHub auth ==="
    gh auth login || true
  fi
  if command -v gh &>/dev/null && gh auth status &>/dev/null; then
    _gh_user=$(gh api user --jq '.login' 2>/dev/null) || _gh_user=""
    _gh_id=$(gh api user --jq '.id' 2>/dev/null) || _gh_id=""
    if [[ -n "$_gh_user" && -n "$_gh_id" ]]; then
      _gh_email="${_gh_id}+${_gh_user}@users.noreply.github.com"
      # Surgical update via `git config --file` — do NOT `cat > ~/.gitconfig.local`;
      # that would wipe the SSH-signing block Phase B appends.
      touch ~/.gitconfig.local
      git config --file ~/.gitconfig.local user.name  "$_gh_user"
      git config --file ~/.gitconfig.local user.email "$_gh_email"
      echo "arch: git identity = ${_gh_user} <${_gh_email}>"
    fi
    unset _gh_user _gh_id _gh_email
    rm -f ~/.zshrc.d/arch-first-login.zsh
  fi
fi
AUTHEOF
fi

# ---------- 9a. fnpostinstall shell function ----------
# Convenience wrapper for re-running the latest postinstall from GitHub,
# piped through tee so there's always a log to grep. Written to a
# .zshrc.d fragment so it lands on $PATH via the .zshrc loop.
#
# Clones the whole repo to a tmpfs path instead of fetching just
# postinstall.sh — earlier versions used `gh api contents/...` for a
# single-file pull, but §4d needs the sibling `metis-ddns/` sidecar dir
# next to postinstall.sh, which a single-file fetch doesn't supply.
# Passes any args through (e.g. `fnpostinstall --no-verify`).
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
ALIASEOF

log "Pre-building zgenom plugin cache (so first login is fast)..."
zsh -i -c 'echo zgenom warmup complete' 2>/dev/null || warn "zgenom warmup had issues; first login will rebuild."

# ---------- 11. tmux config — handled by chezmoi (§13) ----------
# dotfiles/dot_tmux.conf is the source of truth (Ctrl+a prefix, splits open
# in pane CWD for the Claude Code worktree workflow, matugen-rendered colors
# via ~/.config/tmux/colors.conf). No tpm — sesh-bin (§3 yay) covers session
# switching, and matugen replaces the catppuccin/tmux plugin's coloring.

# ---------- 12. Helix config — handled by chezmoi (§13) ----------
# dotfiles/dot_config/helix/config.toml is the source of truth (theme = matugen).
# No write here.

# ---------- 13. Hyprland configs via chezmoi (bare-Hyprland design) ----------
# Switched from HyDE → bare-Hyprland 2026-04-22 (decisions.md §Q10 + §Q-K +
# desktop-requirements.md). Reasons in the memo: HyDE writes a wall of
# upstream config we don't own, contaminates /boot loader entries on
# install, and the "saves user time" value evaporated when the user said
# "Claude does the tweaking." Now: Claude-authored configs live in
# /root/arch-setup/dotfiles, applied via chezmoi.
#
# Theme is matugen (Material You from wallpaper) — every component (waybar,
# swaync, fuzzel, ghostty, helix, hypr-colors, tmux, gtk, qt) reads colors
# from a matugen-rendered template. See dotfiles/dot_config/matugen/config.toml.
#
# Idempotent: chezmoi's `apply` is a no-op when source matches dest.
DOTFILES_SRC="/root/arch-setup/dotfiles"
if [[ ! -d "$DOTFILES_SRC" ]]; then
    # Local fallback: dotfiles checkout co-located with this script
    # (works when postinstall is run from /home/tom/arch-setup/ rather than
    # the chroot-staged /root/arch-setup/).
    DOTFILES_SRC="$SCRIPT_DIR/../dotfiles"
fi

if [[ ! -d "$DOTFILES_SRC" ]]; then
    warn "dotfiles tree not found at /root/arch-setup/dotfiles or alongside this script."
    warn "  Custom-ISO install bakes it in; Ventoy install copies it via install.sh §11."
    warn "  Skipping chezmoi apply — Hyprland will start with empty config."
elif ! command -v chezmoi >/dev/null; then
    warn "chezmoi not installed — was it dropped from §1 pacman list?"
else
    log "Initializing chezmoi from $DOTFILES_SRC..."
    chezmoi init --source="$DOTFILES_SRC" >/dev/null 2>&1 \
        || warn "chezmoi init failed (already initialized? — non-fatal, continuing)."
    log "Applying chezmoi (writes ~/.config, ~/.local/bin, ~/.local/share)..."
    chezmoi apply --force \
        || warn "chezmoi apply reported issues — check 'chezmoi status' and 'chezmoi diff'."
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

# Hyprland plugins via hyprpm. hyprexpo + hyprgrass per desktop-requirements.md.
# Must run inside a Hyprland session to actually load (hyprpm enable signals
# the live compositor). On first install, the user runs this section again
# from inside Hyprland; on re-runs, the `add` is idempotent.
if command -v hyprpm >/dev/null; then
    log "Ensuring Hyprland plugins (hyprexpo + hyprgrass)..."
    hyprpm update >/dev/null 2>&1 || true
    if ! hyprpm list 2>/dev/null | grep -q hyprexpo; then
        hyprpm add https://github.com/hyprwm/hyprland-plugins \
            && hyprpm enable hyprexpo \
            || warn "hyprexpo install failed — re-run inside a Hyprland session."
    fi
    if ! hyprpm list 2>/dev/null | grep -q hyprgrass; then
        hyprpm add https://github.com/horriblename/hyprgrass \
            && hyprpm enable hyprgrass \
            || warn "hyprgrass install failed — re-run inside a Hyprland session."
    fi
fi

# Ghostty config + greetd-regreet config are now part of dotfiles/system-files
# (matugen-themed). No separate §14 / §15 needed — legacy blocks removed.

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

echo "-- session / login / display --"
check "NetworkManager"      "systemctl is-enabled NetworkManager"
check "greetd"              "systemctl is-enabled greetd"
check "greetd-regreet"      "pacman -Q greetd-regreet"
check "pipewire"            "pacman -Q pipewire wireplumber"
check "bluetooth"           "systemctl is-enabled bluetooth"

echo "-- printing (Canon Pro 9000 Mk II via USB) --"
check "cups installed"      "pacman -Q cups"
check "cups.socket enabled" "systemctl is-enabled cups.socket"
check "gutenprint PPDs"     "test -d /usr/share/cups/model/gutenprint || ls /usr/share/cups/model 2>/dev/null | grep -q gutenprint"
check "tom in lp group"     "id -nG tom | grep -qw lp"

echo "-- secrets / auth --"
check "fprintd enabled"     "systemctl is-enabled fprintd"
check "fprintd enrolled"    "fprintd-list tom 2>/dev/null | grep -q 'Fingerprints for user tom'"
check "pinutil (TPM PIN)"   "test -x /usr/bin/pinutil || command -v pinutil"
check "pinpam .so present"   "test -f /usr/lib/security/libpinpam.so"
check "PIN actually persisted" "! pinutil test < /dev/null 2>&1 | grep -q NoPinSet"
check "pinpam in sudo"       "grep -q libpinpam /etc/pam.d/sudo"
check "pinpam in hyprlock"   "grep -q libpinpam /etc/pam.d/hyprlock"
check "no pinpam in greetd"  "! grep -q libpinpam /etc/pam.d/greetd"
check "fprintd in greetd"    "grep -q 'pam_fprintd.*max-tries=1.*timeout=10' /etc/pam.d/greetd"
check "fprintd in sudo"      "grep -q 'pam_fprintd.*max-tries=1.*timeout=5' /etc/pam.d/sudo"
check "fprintd in hyprlock"  "grep -q 'pam_fprintd.*max-tries=1.*timeout=5' /etc/pam.d/hyprlock"
check "pinpam before fprintd sudo" "awk '/libpinpam/{p=NR} /pam_fprintd/{f=NR} END{exit !(p && f && p<f)}' /etc/pam.d/sudo"
check "pinpam before fprintd hyprlock" "awk '/libpinpam/{p=NR} /pam_fprintd/{f=NR} END{exit !(p && f && p<f)}' /etc/pam.d/hyprlock"
check "pam_unix in sys-auth" "grep -q pam_unix /etc/pam.d/system-auth"
check "LUKS root TPM2"      "sudo systemd-cryptenroll /dev/disk/by-partlabel/ArchRoot 2>/dev/null | awk 'NR>1 && \$2==\"tpm2\"{f=1} END{exit !f}'"
check "cryptvar keyfile"    "sudo test -f /etc/cryptsetup-keys.d/cryptvar.key"
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
check "metis-ddns binary"   "test -x /usr/local/bin/metis-ddns"
check "metis-ddns service"  "systemctl is-enabled metis-ddns.service 2>/dev/null || systemctl cat metis-ddns.service >/dev/null 2>&1"
check "metis-ddns timer"    "systemctl is-enabled metis-ddns.timer"
check "metis-ddns NM hook"  "test -x /etc/NetworkManager/dispatcher.d/90-metis-ddns"
check "metis-ddns env"      "sudo test -f /etc/metis-ddns.env"
check "metis-ddns env filled" "sudo grep -qE '^AZ_TENANT_ID=.+' /etc/metis-ddns.env"
check "metis-ddns last run OK" "sudo systemctl status metis-ddns.service 2>/dev/null | grep -q 'status=0/SUCCESS' || ! sudo test -f /etc/metis-ddns.env || ! sudo grep -qE '^AZ_TENANT_ID=.+' /etc/metis-ddns.env"
check "certbot"             "command -v certbot"
check "certbot azure plugin" "sudo test -d /opt/pipx/venvs/certbot && sudo ls /opt/pipx/venvs/certbot/lib/python*/site-packages 2>/dev/null | grep -q certbot_dns_azure"
check "LE cert (if issued)" "! test -d /etc/letsencrypt/live/metis.rhombus.rocks || sudo test -f /etc/letsencrypt/live/metis.rhombus.rocks/fullchain.pem"

echo "-- snapshots / udev / planters --"
check "snapper config /"    "sudo test -f /etc/snapper/configs/root"
check "udev usb-serial"     "test -f /etc/udev/rules.d/99-usb-serial.rules"
check "gh-auth planter or done" "test -f $HOME/.zshrc.d/arch-first-login.zsh || test -f $HOME/.gitconfig.local"
check "ssh-signing planter" "test -f $HOME/.zshrc.d/arch-ssh-signing.zsh || grep -q allowedSignersFile $HOME/.gitconfig.local 2>/dev/null"
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

echo
cat <<'POSTINSTALL_OUTRO'
====================================================================
  ONE-TIME ACTIONS (only matter the first time you run this)
====================================================================

[1] Reboot or log out → log back in via greetd to start Hyprland.

[2] Bitwarden desktop:
      - Launch, log in once with your master password.
      - Settings → Security → enable "Unlock with system keyring".
      - Settings → SSH agent → enable. Import keys as "SSH key" items.
    After that, vault + agent + sudo-PIN + fingerprint all unlock via login.

[3] gh + git identity:
      Already wired if the first-login planter ran (see ~/.gitconfig.local).
      Otherwise: open a new terminal and `gh auth login` once.

[4] Azure DDNS (metis.rhombus.rocks) — one-time wiring via setup-azure-ddns.sh:

        az login
        ~/setup-azure-ddns.sh           # idempotent; rotates secret on each run

      The script writes /etc/metis-ddns.env + /etc/letsencrypt/azure.ini and
      restarts metis-ddns. First call may 403 (role propagation, ~30s–5min)
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

See runbook/INSTALL-RUNBOOK.md (printed PDF) for the same instructions
in case this output scrolls off.
====================================================================
POSTINSTALL_OUTRO
