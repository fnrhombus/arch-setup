#!/usr/bin/env bash
# phase-3-arch-postinstall/postinstall.sh
#
# Run as user `tom` after first login on the freshly-installed Arch system.
# Network required. Idempotent — safe to re-run.
#
#   chmod +x ~/postinstall.sh && ~/postinstall.sh
#
# What it does (all per decisions.md):
#   - Bootstraps yay (AUR helper, §Q10.B)
#   - Installs AUR apps: VSCode, Edge, Ghostty, fuzzel, cliphist, swaync,
#     satty, grimblast, mise
#   - Installs zgenom + powerlevel10k + plugin list (§Q8)
#   - Drops the end-4/dots-hyprland configs into ~/.config (§Q3)
#   - Catppuccin Mocha theme across the stack (§K)
#   - tmux + helix basic configs (§Q6/§Q7)
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

# ---------- 1. pacman core tooling ----------
log "Installing pacman packages..."
sudo pacman -Syu --noconfirm --needed \
    base-devel git curl wget \
    zsh tmux helix \
    bat fd ripgrep eza lsd btop jq fzf zoxide direnv \
    man-db man-pages pkgfile tldr \
    wl-clipboard grim slurp \
    xdg-user-dirs pipewire pipewire-pulse pipewire-jack wireplumber \
    noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd ttf-firacode-nerd

sudo pkgfile -u

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

# ---------- 3. AUR apps ----------
log "Installing AUR apps (VSCode, Edge, Ghostty, ...)..."
yay -S --noconfirm --needed \
    visual-studio-code-bin \
    microsoft-edge-stable-bin \
    ghostty \
    fuzzel \
    cliphist \
    swaync \
    satty \
    hyprshot \
    mise \
    bitwarden \
    bitwarden-cli \
    pinpam-git

# ---------- 3a. fprintd enrollment ----------
if [[ -z "${SKIP_FPRINT:-}" ]]; then
    log "Enrolling fingerprint (you'll be prompted to touch the reader 5x)..."
    fprintd-enroll || warn "fprintd-enroll failed; you can retry later manually."
fi

# ---------- 3b. pinpam TPM-PIN setup ----------
# pinutil setup asks for a fresh PIN and stores it in TPM NVRAM.
# Configured as 'sufficient' in PAM so your Linux password stays as fallback.
if command -v pinutil >/dev/null; then
    if [[ -z "${SKIP_PIN:-}" ]]; then
        log "Setting up TPM-backed PIN (follow prompt; 6+ chars recommended)..."
        sudo pinutil setup || warn "pinutil setup failed; skipping PIN wiring."
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

# ---------- 3c. Bitwarden SSH agent: ssh config ----------
log "Wiring Bitwarden SSH agent into ~/.ssh/config..."
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
if ! grep -q bitwarden-ssh-agent.sock "$HOME/.ssh/config" 2>/dev/null; then
    cat >> "$HOME/.ssh/config" <<'EOF'

Host *
    IdentityAgent ~/.bitwarden-ssh-agent.sock
EOF
fi

# ---------- 4. zgenom + zsh config ----------
if [[ ! -d "$HOME/.zgenom" ]]; then
    log "Cloning zgenom..."
    GIT_TEMPLATE_DIR="" git clone https://github.com/jandamm/zgenom.git "$HOME/.zgenom"
fi

log "Writing ~/.zshrc..."
cat > "$HOME/.zshrc" <<'ZSHEOF'
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

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

eval "$(mise activate zsh)"
eval "$(zoxide init zsh)"
eval "$(direnv hook zsh)"

alias ls='eza --group-directories-first --icons'
alias ll='eza -l --git --group-directories-first --icons'
alias la='eza -la --git --group-directories-first --icons'
alias lt='eza --tree --level=2 --icons'
alias cat='bat --paging=never'
alias grep='rg'
alias cd='z'

[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
ZSHEOF

# Trigger zgenom plugin build now (so first login is fast)
log "Pre-building zgenom plugin cache..."
zsh -i -c 'echo zgenom warmup complete' || warn "zgenom warmup had issues; first login will rebuild"

# ---------- 5. tmux config ----------
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

# Sensible splits
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"

# tpm
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'catppuccin/tmux#v2.1.3'
set -g @catppuccin_flavor 'mocha'
run '~/.tmux/plugins/tpm/tpm'
TMUXEOF

if [[ ! -d "$HOME/.tmux/plugins/tpm" ]]; then
    GIT_TEMPLATE_DIR="" git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
fi
"$HOME/.tmux/plugins/tpm/scripts/install_plugins.sh" || warn "tpm install deferred to first tmux run"

# ---------- 6. Helix config ----------
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

# ---------- 7. Hyprland dotfiles (end-4/illogical-impulse) ----------
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

# ---------- 8. Ghostty Catppuccin ----------
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

# ---------- 9. SDDM Catppuccin theme (best-effort) ----------
if yay -Qi catppuccin-sddm-theme-mocha >/dev/null 2>&1 || \
   yay -S --noconfirm --needed catppuccin-sddm-theme-mocha 2>/dev/null; then
    sudo mkdir -p /etc/sddm.conf.d
    echo -e "[Theme]\nCurrent=catppuccin-mocha" | sudo tee /etc/sddm.conf.d/theme.conf >/dev/null
fi

# ---------- 10. default shell ----------
if [[ "$SHELL" != "$(which zsh)" ]]; then
    log "Changing login shell to zsh..."
    chsh -s "$(which zsh)"
fi

# ---------- 11. verify ----------
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
check "zgenom"              "test -d $HOME/.zgenom"
check "p10k"                "test -d $HOME/.zgenom/sources/romkatv/powerlevel10k-master"
check "bat / fd / rg / eza" "command -v bat && command -v fd && command -v rg && command -v eza"
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
check "dotfiles staged"     "test -d $HOME/dotfiles/dots-hyprland"
check "hyprland config"     "test -f $HOME/.config/hypr/hyprland.conf"
check "bitwarden desktop"   "command -v bitwarden"
check "bitwarden-cli"       "command -v bw"
check "pinutil (TPM PIN)"   "command -v pinutil"
check "pinpam in sudo"      "grep -q pam_pinpam /etc/pam.d/sudo"
check "fprintd enrolled"    "fprintd-list tom 2>/dev/null | grep -q 'Fingerprints for user tom'"
check "ssh agent wired"     "grep -q bitwarden-ssh-agent.sock $HOME/.ssh/config"

echo
echo "Log out and back in (or reboot) to start Hyprland via SDDM."
echo "Then, one-time Bitwarden setup:"
echo "  1. Launch Bitwarden desktop, log in once with your master password."
echo "  2. Settings -> Security -> enable 'Unlock with system keyring'."
echo "  3. Settings -> SSH agent -> enable. Import your keys as SSH key vault items."
echo "After that, vault + agent + sudo-PIN + fingerprint all unlock via your login."
