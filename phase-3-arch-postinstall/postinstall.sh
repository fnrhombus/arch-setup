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
    ghostty fuzzel cliphist swaync satty hyprshot \
    mise chezmoi github-cli sesh \
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
log "Installing AUR-exclusive apps (VSCode, Edge, pinpam-git, SDDM theme)..."
yay -S --noconfirm --needed \
    visual-studio-code-bin \
    microsoft-edge-stable-bin \
    catppuccin-sddm-theme-mocha \
    pinpam-git

# ---------- 4. (no local SSH keygen — Bitwarden SSH agent holds keys) ----------
# Keys live in the Bitwarden vault as "SSH key" items and surface via
# ~/.bitwarden-ssh-agent.sock once Bitwarden desktop is running with the
# SSH-agent toggle enabled. Public keys are readable via `ssh-add -L`.
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"

# ---------- 5. Claude Code CLI ----------
# Claude Code is distributed via npm (@anthropic-ai/claude-code). There's no
# mise plugin named "claude-code" — that call was wrong. Route: use mise to
# install a LTS node, then `npm install -g`. npm's prefix sits under
# ~/.local/share/mise/installs/node/*/bin so it ends up on PATH once mise is
# activated by .zshrc.
if ! command -v claude >/dev/null; then
    if command -v mise >/dev/null; then
        log "Installing node@lts via mise, then Claude Code via npm..."
        mise use -g node@lts 2>&1 | tee -a /tmp/mise-node.log || warn "mise node@lts install failed — check /tmp/mise-node.log"
        # Run npm through mise so we hit the newly-installed node even in
        # this non-interactive shell where mise hasn't been sourced yet.
        mise exec -- npm install -g @anthropic-ai/claude-code 2>&1 | tee -a /tmp/mise-node.log || \
            warn "Claude Code install failed — run manually: mise use -g node@lts && npm i -g @anthropic-ai/claude-code"
    else
        warn "mise missing; skipping Claude Code CLI install."
    fi
fi
# Claude Code ships its own completions at runtime: `claude --print-completion zsh`
# is wired in .zshrc below, no fragile external download needed.

# ---------- 6. Fingerprint enrollment (Goodix-aware) ----------
if [[ -z "${SKIP_FPRINT:-}" ]]; then
    GOODIX_PRESENT=0
    if command -v lsusb >/dev/null && lsusb | grep -qi '27c6:'; then
        GOODIX_PRESENT=1
        log "Goodix fingerprint reader detected: $(lsusb | grep -i '27c6:' | head -1)"
    fi

    log "Enrolling fingerprint (you'll be prompted to touch the reader ~5x)..."
    if ! fprintd-enroll 2>&1 | tee /tmp/fprint-enroll.log; then
        warn "fprintd-enroll failed. Diagnostic:"
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
        echo "Fallback: install libfprint-git from AUR and retry. Covers newer PIDs for all vendors."
        read -rp "Install libfprint-git now and retry fprintd-enroll? [y/N] " ans
        if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
            if yay -S --noconfirm --needed libfprint-git && sudo systemctl restart fprintd; then
                fprintd-enroll || warn "libfprint-git retry also failed."
            else
                warn "libfprint-git install failed."
            fi
            echo "Supported-device reference: https://fprint.freedesktop.org/supported-devices.html"
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
            sudo pinutil setup || warn "pinutil setup failed; skipping PIN wiring."
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
if [[ -d "$HOME/dotfiles/dots-hyprland" ]]; then
    log "Installing end-4/dots-hyprland..."
    pushd "$HOME/dotfiles/dots-hyprland" >/dev/null
    if [[ -x ./install.sh ]]; then
        warn "Running end-4 installer INTERACTIVELY — answer prompts."
        ./install.sh || warn "end-4 installer exited non-zero; review manually"
    else
        warn "No install.sh in dots-hyprland; copying ./.config/* manually."
        cp -rn .config/* "$HOME/.config/" 2>/dev/null || true
    fi
    popd >/dev/null
else
    warn "Dotfiles not staged at ~/dotfiles/dots-hyprland — skipping Hyprland config."
fi

# ---------- 14. Ghostty Catppuccin ----------
log "Writing Ghostty config..."
mkdir -p "$HOME/.config/ghostty"
cat > "$HOME/.config/ghostty/config" <<'GSEOF'
font-family = "JetBrainsMono Nerd Font"
font-size = 12
theme = "catppuccin-mocha"
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
    sudo cp /etc/snapper/config-templates/default /etc/snapper/configs/root
    sudo sed -i 's|^SUBVOLUME=.*|SUBVOLUME="/"|' /etc/snapper/configs/root
    sudo sed -i 's|^ALLOW_USERS=.*|ALLOW_USERS="tom"|' /etc/snapper/configs/root
    # Register the config name so `snapper list-configs` sees it.
    if ! grep -q '^SNAPPER_CONFIGS=.*root' /etc/conf.d/snapper 2>/dev/null; then
        echo 'SNAPPER_CONFIGS="root"' | sudo tee -a /etc/conf.d/snapper >/dev/null
    fi
    sudo chown -R :tom /.snapshots 2>/dev/null || true
    sudo chmod 750 /.snapshots
    # Baseline snapshot — safe now that config exists and .snapshots is writable.
    sudo snapper -c root create --description "clean install postinstall baseline" || \
        warn "snapper baseline failed — config is in place but no snapshot taken."
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
check "helix (hx)"          "command -v hx"
check "yay"                 "command -v yay"
check "mise"                "command -v mise"
check "chezmoi"             "command -v chezmoi"
check "gh (github-cli)"     "command -v gh"
check "zgenom"              "test -d $HOME/.zgenom"
check "p10k"                "test -d $HOME/.zgenom/sources/romkatv/powerlevel10k-master"
check "bat / fd / rg / eza" "command -v bat && command -v fd && command -v rg && command -v eza"
check "mise node@lts"       "mise exec -- node --version"
check "claude (CLI)"        "mise exec -- command -v claude || command -v claude"
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
check "pipewire"            "systemctl --user is-enabled pipewire"
check "bluetooth"           "systemctl is-enabled bluetooth"
check "fprintd"             "systemctl is-enabled fprintd"
check "snapper config /"    "test -f /etc/snapper/configs/root"
check "dotfiles staged"     "test -d $HOME/dotfiles/dots-hyprland"
check "hyprland config"     "test -f $HOME/.config/hypr/hyprland.conf"
check "bitwarden desktop"   "command -v bitwarden"
check "bitwarden-cli"       "command -v bw"
check "pinutil (TPM PIN)"   "command -v pinutil"
check "pinpam in sudo"      "grep -q pam_pinpam /etc/pam.d/sudo"
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
