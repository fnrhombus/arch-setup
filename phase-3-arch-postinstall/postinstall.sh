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
#   - Claude Code CLI + bash completion
#   - Goodix-aware fingerprint enrollment (VID 27C6 detected → detailed diag on fail)
#   - pinpam TPM-PIN + PAM wiring for sudo/polkit/hyprlock
#   - Bitwarden SSH agent in ~/.ssh/config
#   - gh identity + signing key registration (first-login planter if no token yet)
#   - zgenom + p10k + the full fnwsl plugin set (history/completion/PATH dedup
#     brought in from fnwsl; WSL-specific pieces dropped)
#   - end-4/illogical-impulse Hyprland dotfiles
#   - Catppuccin Mocha across Ghostty/SDDM/tmux/Helix
#   - Snapper baseline snapshot
#   - USB-serial udev rules (ESP32/Pico)
#
# The verify block at the end enumerates every tool as FAIL/OK.

set -euo pipefail

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(id -un)" == "tom" ]] || die "Run as user 'tom'."
ping -c1 -W3 archlinux.org >/dev/null || die "No network."

export HOME="/home/tom"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export PATH="$HOME/.local/bin:$PATH"
cd "$HOME"

# ---------- 1. pacman: repo packages (signed, fast) ----------
log "Installing pacman packages from official repos..."
sudo pacman -Syu --noconfirm --needed \
    base-devel git curl wget openssh \
    zsh tmux helix \
    bat fd ripgrep eza lsd btop jq fzf zoxide direnv \
    sd yq xh \
    man-db man-pages pkgfile tldr \
    wl-clipboard grim slurp \
    xdg-user-dirs pipewire pipewire-pulse pipewire-jack wireplumber \
    noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd ttf-firacode-nerd \
    bitwarden bitwarden-cli \
    ghostty fuzzel cliphist mako satty hyprshot \
    foot nautilus yazi \
    hyprpolkitagent swww xdg-desktop-portal-gtk \
    mise chezmoi github-cli \
    docker docker-compose docker-buildx \
    snapper snap-pac

sudo pkgfile -u

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
# a fresh install — end-4's first-launch wizard can't see the auth agent
# until it's registered on the session D-Bus, which requires the service
# to be started at least once. Idempotent: --now starts it here, enable
# persists across logins.
systemctl --user enable --now hyprpolkitagent.service 2>/dev/null || \
    warn "hyprpolkitagent.service enable failed — end-4 wizard may flag auth agent as Missing."

# ---------- 2. yay bootstrap ----------
if ! command -v yay >/dev/null; then
    log "Bootstrapping yay from AUR..."
    TMP=$(mktemp -d)
    GIT_TEMPLATE_DIR="" git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$TMP/yay-bin"
    pushd "$TMP/yay-bin" >/dev/null
    makepkg -si --noconfirm
    popd >/dev/null
    rm -rf "$TMP"
fi

# ---------- 3. AUR: only what's not in extra ----------
log "Installing AUR-exclusive apps (VSCode, Edge, pinpam-git, SDDM theme, quickshell)..."
yay -S --noconfirm --needed \
    visual-studio-code-bin \
    microsoft-edge-stable-bin \
    catppuccin-sddm-theme-mocha \
    pinpam-git \
    sesh \
    quickshell-git

# ---------- 4. (no local SSH keygen — Bitwarden SSH agent holds keys) ----------
# Keys live in the Bitwarden vault as "SSH key" items and surface via
# ~/.bitwarden-ssh-agent.sock once Bitwarden desktop is running with the
# SSH-agent toggle enabled. Public keys are readable via `ssh-add -L`.
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"

# ---------- 5. Claude Code CLI ----------
# Claude Code is distributed via npm (@anthropic-ai/claude-code). There's no
# mise plugin named "claude-code" — that call was wrong. Route: use mise to
# install a LTS node, then `npm install -g`. The binary lands under
# ~/.local/share/mise/installs/node/<version>/bin/claude and is only on PATH
# in mise-activated shells — symlink it into /usr/local/bin so `claude` works
# from any shell, including sudo, scripts, and SDDM-launched apps.
if ! command -v claude >/dev/null; then
    if command -v mise >/dev/null; then
        log "Installing node@lts via mise, then Claude Code via npm..."
        # Bash's `cmd | tee` returns tee's exit, masking a failed install behind
        # success. Redirect to the log file directly so the `if` sees the real
        # exit status, then show the tail on failure.
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
# Configured as 'sufficient' in PAM so your Linux password stays as fallback.
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
                log "TPM PIN set."
            elif grep -q 'already has a PIN' /tmp/pinutil-setup.log; then
                log "TPM PIN already set — skipping (idempotent re-run)."
            else
                warn "pinutil setup failed; PAM PIN unlock won't work until fixed."
            fi
        else
            warn "No TTY — skipping 'pinutil setup'. Run it manually after login: sudo pinutil setup"
        fi
    fi
    log "Wiring pinpam into sudo, polkit, hyprlock PAM stacks..."
    for svc in sudo polkit-1 hyprlock; do
        f="/etc/pam.d/$svc"
        [[ -f "$f" ]] || continue
        if ! sudo grep -q pam_pinpam "$f"; then
            sudo sed -i '1i auth       sufficient   pam_pinpam.so' "$f"
        fi
    done
else
    warn "pinutil not found; skipping TPM-PIN setup."
fi

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
# Only cryptroot is TPM-enrolled. cryptvar auto-unlocks from a keyfile on
# the (TPM-unlocked) cryptroot filesystem — a second TPM slot would burn
# LUKS budget without adding at-rest protection.
if [[ -c /dev/tpm0 || -c /dev/tpmrm0 ]] && [[ -z "${SKIP_TPM_LUKS:-}" ]]; then
    dev="/dev/disk/by-partlabel/ArchRoot"
    if [[ -b "$dev" ]]; then
        # systemd-cryptenroll with no action flag prints "SLOT TYPE" header
        # plus one line per key slot. Check for an existing tpm2 slot so a
        # re-run is idempotent (otherwise a second enroll adds a second
        # tpm2 slot, wastes LUKS slot budget, and silently succeeds).
        if sudo systemd-cryptenroll "$dev" 2>/dev/null | awk 'NR>1 && $2=="tpm2"{f=1} END{exit !f}'; then
            log "TPM2 already enrolled on ArchRoot — skipping."
        else
            log "Enrolling TPM2 autounlock for ArchRoot (enter the LUKS passphrase when prompted)..."
            sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 "$dev" \
                || warn "TPM enroll failed — boot still works with passphrase."
        fi
    else
        warn "$dev not found — skipping TPM enroll."
    fi
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

# Phase A planter — only if gh isn't already authed
if gh auth status &>/dev/null; then
    log "Configuring GitHub identity (gh already authed)..."
    gh_user=$(gh api user --jq '.login' 2>/dev/null) || gh_user=""
    gh_id=$(gh api user --jq '.id' 2>/dev/null) || gh_id=""
    if [[ -n "$gh_user" && -n "$gh_id" ]]; then
        gh_email="${gh_id}+${gh_user}@users.noreply.github.com"
        cat > "$HOME/.gitconfig.local" <<GITEOF
[user]
    name = ${gh_user}
    email = ${gh_email}
GITEOF
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
      cat > ~/.gitconfig.local <<GITEOF
[user]
    name = ${_gh_user}
    email = ${_gh_email}
GITEOF
      echo "arch: git identity = ${_gh_user} <${_gh_email}>"
    fi
    unset _gh_user _gh_id _gh_email
    rm -f ~/.zshrc.d/arch-first-login.zsh
  fi
fi
AUTHEOF
fi

# ---------- 9a. fnpostinstall shell function ----------
# Convenience wrapper for re-running postinstall from HEAD of the feature
# branch, piped through tee so you always have a log to grep. Written to
# a .zshrc.d fragment so it lands on $PATH via the .zshrc loop at line 576.
cat > "$HOME/.zshrc.d/arch-postinstall.zsh" <<'FNEOF'
# arch-setup: re-run the latest postinstall from GitHub, logging to /tmp.
fnpostinstall() {
    local log="/tmp/postinstall-$(date +%Y%m%d-%H%M%S).log"
    echo "Logging to $log"
    {
        gh api 'repos/fnrhombus/arch-setup/contents/phase-3-arch-postinstall/postinstall.sh?ref=claude/fix-linux-boot-issue-9ps2s' --jq .content \
            | base64 -d > ~/postinstall.sh \
            && chmod +x ~/postinstall.sh \
            && bash ~/postinstall.sh
    } 2>&1 | tee "$log"
}
FNEOF

# ---------- 10. zgenom + zsh config (enriched from fnwsl) ----------
if [[ ! -d "$HOME/.zgenom" ]]; then
    log "Cloning zgenom..."
    GIT_TEMPLATE_DIR="" git clone https://github.com/jandamm/zgenom.git "$HOME/.zgenom"
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

# Pre-ship p10k config from fnwsl so the first shell doesn't drop into the
# `p10k configure` wizard. Sidecar file lives next to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/p10k.zsh" ]]; then
    log "Installing pre-shipped ~/.p10k.zsh from fnwsl..."
    cp "$SCRIPT_DIR/p10k.zsh" "$HOME/.p10k.zsh"
else
    warn "p10k.zsh sidecar not found next to postinstall.sh — first shell will prompt to configure."
fi

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

# ---------- 11. tmux config ----------
log "Writing ~/.tmux.conf..."
cat > "$HOME/.tmux.conf" <<'TMUXEOF'
# Ctrl+a prefix (carried from fnwsl)
unbind C-b
set -g prefix C-a
bind C-a send-prefix

set -g mouse on
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB,ghostty:RGB"

bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"

set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'catppuccin/tmux#v2.1.3'
set -g @catppuccin_flavor 'mocha'
run '~/.tmux/plugins/tpm/tpm'
TMUXEOF

if [[ ! -d "$HOME/.tmux/plugins/tpm" ]]; then
    GIT_TEMPLATE_DIR="" git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
fi
"$HOME/.tmux/plugins/tpm/scripts/install_plugins.sh" >/dev/null 2>&1 || \
    warn "tpm install deferred to first tmux run"

# ---------- 12. Helix config ----------
log "Writing Helix config..."
mkdir -p "$HOME/.config/helix"
cat > "$HOME/.config/helix/config.toml" <<'HXEOF'
theme = "catppuccin_mocha"

[editor]
line-number = "relative"
mouse = true
cursorline = true
bufferline = "multiple"
color-modes = true
true-color = true

[editor.cursor-shape]
insert = "bar"
normal = "block"
select = "underline"

[editor.indent-guides]
render = true
HXEOF

# ---------- 13. Hyprland dotfiles (end-4/illogical-impulse) ----------
# Clone fresh at run time — we get the latest dots, the repo stays lean, and
# phase 2 doesn't have to carry a snapshot on the USB. GIT_TEMPLATE_DIR="" is
# the wsl-setup-lessons.md mitigation for stale user-dir template hooks.
if [[ ! -d "$HOME/dotfiles/dots-hyprland" ]]; then
    log "Cloning end-4/dots-hyprland..."
    mkdir -p "$HOME/dotfiles"
    GIT_TEMPLATE_DIR="" git clone --depth 1 https://github.com/end-4/dots-hyprland.git \
        "$HOME/dotfiles/dots-hyprland" \
        || warn "dots-hyprland clone failed — network? Retry manually later: \
GIT_TEMPLATE_DIR=\"\" git clone --depth 1 https://github.com/end-4/dots-hyprland.git ~/dotfiles/dots-hyprland"
fi

if [[ -d "$HOME/dotfiles/dots-hyprland" ]]; then
    log "Installing end-4/dots-hyprland..."
    pushd "$HOME/dotfiles/dots-hyprland" >/dev/null
    # Installer naming history: end-4 renamed `install.sh` → `setup` (with
    # subcommands) in late 2025 / early 2026. Configs also moved from
    # ./.config/ to ./dots/.config/. Try in order: new setup, old install.sh,
    # then the corrected cp fallback.
    if [[ -x ./setup ]]; then
        warn "Running end-4 ./setup install INTERACTIVELY — answer prompts."
        ./setup install || warn "end-4 ./setup install exited non-zero; review manually"
    elif [[ -x ./install.sh ]]; then
        warn "Running end-4 ./install.sh INTERACTIVELY (legacy) — answer prompts."
        ./install.sh || warn "end-4 installer exited non-zero; review manually"
    elif [[ -d ./dots/.config ]]; then
        warn "No setup script in dots-hyprland; copying ./dots/.config/* manually."
        cp -rn ./dots/.config/* "$HOME/.config/" 2>/dev/null || true
    else
        warn "No setup script AND no ./dots/.config/ in dots-hyprland; copying ./.config/* (legacy layout)."
        cp -rn .config/* "$HOME/.config/" 2>/dev/null || true
    fi
    popd >/dev/null
else
    warn "Dotfiles not available at ~/dotfiles/dots-hyprland — Hyprland config skipped."
    warn "  Fix: GIT_TEMPLATE_DIR=\"\" git clone --depth 1 https://github.com/end-4/dots-hyprland.git ~/dotfiles/dots-hyprland"
    warn "       then re-run this script."
fi

# ---------- 13a. Hyprland customizations layered on top of end-4 ----------
# end-4's setup overwrites ~/.config/hypr/hyprland.conf on every install.
# We patch + append idempotently so re-runs restore our overrides.
HYPR_CONF="$HOME/.config/hypr/hyprland.conf"

# end-4 defaults `$terminal = foot` (line 35 at time of writing). foot stays
# installed as their first-launch-wizard shim (docs/decisions.md §Q10-C), but
# the daily-driver terminal is Ghostty — rewrite the var so every keybind that
# uses $terminal launches Ghostty. sed is inherently idempotent: once the line
# already says ghostty the pattern stops matching.
if [[ -f "$HYPR_CONF" ]]; then
    sed -i 's|^\$terminal = foot$|$terminal = ghostty|' "$HYPR_CONF"
fi

if [[ -f "$HYPR_CONF" ]] && ! grep -q '# arch-setup-customizations' "$HYPR_CONF"; then
    log "Appending arch-setup customizations to $HYPR_CONF..."
    cat >> "$HYPR_CONF" <<'HYPREOF'

# arch-setup-customizations (do not remove this marker — postinstall.sh skips re-append on its presence)
# Monitor layout: Vizio V505-G9 (4K 50") as primary at top-left; Dell Inspiron 7786
# built-in (FHD) flush-left directly below the TV. TV scaled 1.5x → logical
# 2560x1440, so laptop sits at y=1440. Mouse flows continuously across the
# shared edge within the laptop's 0–1920 horizontal span.
monitor = HDMI-A-1, 3840x2160@60, 0x0, 1.5
monitor = eDP-1,    1920x1080@60, 0x1440, 1
# Lid close → disable internal panel; lid open → re-enable at the position
# above. Laptop lives under a desk most of the time; closing the lid is the
# normal "kiosk mode" signal. Open the lid to get the internal display back.
bindl = , switch:on:Lid Switch,  exec, hyprctl keyword monitor "eDP-1, disable"
bindl = , switch:off:Lid Switch, exec, hyprctl keyword monitor "eDP-1, 1920x1080@60, 0x1440, 1"
# Auto-start quickshell (end-4's status bar) — vanilla end-4 hyprland.conf does
# NOT exec-once it, so the bar is missing on first login without this.
exec-once = quickshell
HYPREOF
fi

# ---------- 14. Ghostty Catppuccin ----------
log "Writing Ghostty config..."
mkdir -p "$HOME/.config/ghostty"
cat > "$HOME/.config/ghostty/config" <<'GSEOF'
font-family = "JetBrainsMono Nerd Font"
font-size = 12
theme = "Catppuccin Mocha"
cursor-style = block
cursor-style-blink = false
window-decoration = false
window-padding-x = 8
window-padding-y = 8
mouse-hide-while-typing = true
copy-on-select = clipboard
GSEOF

# ---------- 15. SDDM Catppuccin theme ----------
if pacman -Qi catppuccin-sddm-theme-mocha >/dev/null 2>&1; then
    sudo mkdir -p /etc/sddm.conf.d
    echo -e "[Theme]\nCurrent=catppuccin-mocha" | sudo tee /etc/sddm.conf.d/theme.conf >/dev/null
fi

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
echo
echo "=== Verify ==="
# Clear shell's command hash cache so binaries installed during this very run
# (e.g. pinutil from pinpam-git) resolve via `command -v` without a shell restart.
hash -r 2>/dev/null || true
check() {
    local name="$1"; local cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        printf '  \033[1;32mOK\033[0m    %s\n' "$name"
    else
        printf '  \033[1;31mFAIL\033[0m  %s\n' "$name"
    fi
}

check "zsh"                 "command -v zsh"
check "tmux"                "command -v tmux"
check "helix"               "command -v helix || command -v hx"
check "yay"                 "command -v yay"
check "mise"                "command -v mise"
check "chezmoi"             "command -v chezmoi"
check "gh (github-cli)"     "command -v gh"
check "zgenom"              "test -d $HOME/.zgenom"
check "p10k"                "test -d $HOME/.zgenom/romkatv"
check "bat / fd / rg / eza" "command -v bat && command -v fd && command -v rg && command -v eza"
check "mise node@lts"       "mise exec -- node --version"
check "claude (CLI)"        "command -v claude"
check "vscode"              "command -v code"
check "edge"                "command -v microsoft-edge-stable"
check "ghostty"             "command -v ghostty"
check "fuzzel"              "command -v fuzzel"
check "cliphist"            "command -v cliphist"
check "swaync"              "command -v swaync"
check "satty"               "command -v satty"
check "wl-copy"             "command -v wl-copy"
check "NetworkManager"      "systemctl is-enabled NetworkManager"
check "sddm"                "systemctl is-enabled sddm"
check "pipewire"            "pacman -Q pipewire wireplumber"
check "bluetooth"           "systemctl is-enabled bluetooth"
check "fprintd"             "systemctl is-enabled fprintd"
check "snapper config /"    "sudo test -f /etc/snapper/configs/root"
check "dotfiles staged"     "test -d $HOME/dotfiles/dots-hyprland"
check "hyprland config"     "test -f $HOME/.config/hypr/hyprland.conf"
check "bitwarden desktop"   "command -v bitwarden-desktop || command -v bitwarden"
check "bitwarden-cli"       "command -v bw"
check "pinutil (TPM PIN)"   "test -x /usr/bin/pinutil || command -v pinutil"
check "pinpam in sudo"      "grep -q pam_pinpam /etc/pam.d/sudo"
check "LUKS root TPM2"      "sudo systemd-cryptenroll /dev/disk/by-partlabel/ArchRoot 2>/dev/null | awk 'NR>1 && \$2==\"tpm2\"{f=1} END{exit !f}'"
check "cryptvar keyfile"    "sudo test -f /etc/cryptsetup-keys.d/cryptvar.key"
check "fprintd enrolled"    "fprintd-list tom 2>/dev/null | grep -q 'Fingerprints for user tom'"
check "ssh agent wired"     "grep -q bitwarden-ssh-agent.sock $HOME/.ssh/config"
check "udev usb-serial"     "test -f /etc/udev/rules.d/99-usb-serial.rules"
check "gh-auth planter or done" "test -f $HOME/.zshrc.d/arch-first-login.zsh || test -f $HOME/.gitconfig.local"
check "ssh-signing planter" "test -f $HOME/.zshrc.d/arch-ssh-signing.zsh || grep -q allowedSignersFile $HOME/.gitconfig.local 2>/dev/null"

echo
echo "Log out and back in (or reboot) to start Hyprland via SDDM."
echo "Then, one-time Bitwarden setup:"
echo "  1. Launch Bitwarden desktop, log in once with your master password."
echo "  2. Settings -> Security -> enable 'Unlock with system keyring'."
echo "  3. Settings -> SSH agent -> enable. Import your keys as SSH key vault items."
echo "After that, vault + agent + sudo-PIN + fingerprint all unlock via your login."
echo "If the first-login planter ran, gh + git identity are already wired."
