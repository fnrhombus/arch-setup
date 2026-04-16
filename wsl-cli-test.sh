#!/bin/bash
set -e

# Force correct HOME (WSL may inherit Windows USERPROFILE)
export HOME="/home/$(whoami)"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
cd "$HOME"

echo "=== Arch WSL CLI Test Setup ==="
echo "Running as: $(whoami)"
echo "HOME: $HOME"
echo "PATH: $PATH"

# --- Ensure ~/.local/bin is on PATH ---
export PATH="$HOME/.local/bin:$PATH"

# --- Install mise tools ---
echo ""
echo "=== Installing tools via mise ==="
mise use -g sd
mise use -g yq
mise use -g xh
mise use -g gh
mise use -g zoxide

# --- Install zgenom (zsh plugin manager) ---
if [[ ! -d ~/.zgenom ]]; then
  echo ""
  echo "=== Installing zgenom ==="
  GIT_TEMPLATE_DIR="" git clone https://github.com/jandamm/zgenom.git ~/.zgenom
fi

# --- Install chezmoi ---
if ! command -v chezmoi &>/dev/null; then
  echo ""
  echo "=== Installing chezmoi ==="
  sudo pacman -S --noconfirm chezmoi
fi

# --- Install tldr ---
if ! command -v tldr &>/dev/null; then
  echo ""
  echo "=== Installing tldr ==="
  sudo pacman -S --noconfirm tldr
fi

# --- Install pkgfile (command-not-found for Arch) ---
if ! command -v pkgfile &>/dev/null; then
  echo ""
  echo "=== Installing pkgfile ==="
  sudo pacman -S --noconfirm pkgfile
  sudo pkgfile -u
fi

# --- Copy zsh config from fnwsl (adapted for Arch) ---
echo ""
echo "=== Setting up zsh config ==="
cat > ~/.zshrc << 'ZSHEOF'
# --- Powerlevel10k instant prompt (must be near top) ---
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# --- Zgenom plugin manager ---
ZGEN_DIR="${HOME}/.zgenom"
if [[ ! -d "$ZGEN_DIR" ]]; then
  git clone https://github.com/jandamm/zgenom.git "$ZGEN_DIR"
fi
source "${ZGEN_DIR}/zgenom.zsh"

if ! zgenom saved; then
  # --- Plugins ---
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
  zgenom load unixorn/fzf-zsh-plugin
  zgenom load Aloxaf/fzf-tab
  zgenom load romkatv/powerlevel10k powerlevel10k

  zgenom save
fi

# --- History ---
HISTFILE=~/.zsh_history
HISTSIZE=100000
SAVEHIST=100000
setopt APPEND_HISTORY
setopt SHARE_HISTORY
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_FIND_NO_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_SAVE_NO_DUPS
setopt HIST_REDUCE_BLANKS

# --- Shell options ---
setopt NO_BEEP
setopt INTERACTIVE_COMMENTS
setopt MULTIOS

# --- Completion ---
autoload -Uz compinit
if [[ -n ~/.zcompdump(#qN.mh+24) ]]; then
  compinit
else
  compinit -C
fi

zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path ~/.zsh/cache
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

# --- Ensure ~/.local/bin is on PATH ---
export PATH="$HOME/.local/bin:$PATH"

# --- Deduplicate PATH ---
typeset -aU path

# --- SSH agent via keychain ---
[[ -f ~/.keychain ]] && rm -f ~/.keychain
if [[ -f ~/.ssh/id_ed25519 ]]; then
  eval $(keychain --eval --quiet --nogui --noask ~/.ssh/id_ed25519)
fi

# --- mise (tool version manager) ---
eval "$(mise activate zsh)"

# --- zoxide (smart cd) ---
eval "$(zoxide init zsh)"

# --- direnv (per-directory env vars) ---
eval "$(direnv hook zsh)"

# --- Aliases ---
source ~/.zsh_aliases 2>/dev/null

# --- Local overrides ---
for f in ~/.zshrc.d/*(N); do source "$f"; done

# --- Report slow commands ---
REPORTTIME=2

# --- Powerlevel10k config ---
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh
ZSHEOF

# --- Copy aliases ---
cat > ~/.zsh_aliases << 'ALIASEOF'
# --- Navigation ---
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."

# --- ls (eza > lsd > ls) ---
if command -v eza &>/dev/null; then
  alias ls="eza -F --icons"
  alias la="eza -aF --icons"
  alias ll="eza -laF --icons --git"
  alias tree="eza --tree --icons"
elif command -v lsd &>/dev/null; then
  alias ls="lsd -F"
  alias la="lsd -aF"
  alias ll="lsd -laF"
else
  alias ls="ls --color=auto -F"
  alias la="ls --color=auto -aF"
  alias ll="ls --color=auto -laF"
fi

# --- Git ---
alias gs="git status"

# --- Utilities ---
alias grep="grep --color=auto"
alias wget="wget -c"
alias myip="curl -s icanhazip.com"

# --- Arch-specific ---
alias pacup="sudo pacman -Syu"
alias pacin="sudo pacman -S"
alias pacrem="sudo pacman -Rns"
alias pacsearch="pacman -Ss"
alias yaysearch="yay -Ss"

# --- mc - make directory and cd into it ---
mc() { mkdir -p "$1" && cd "$1"; }
ALIASEOF

# --- Copy tmux config ---
cat > ~/.tmux.conf << 'TMUXEOF'
# --- Prefix: Ctrl+a (easier than Ctrl+b) ---
unbind C-b
set -g prefix C-a
bind C-a send-prefix

# --- Mouse support ---
set -g mouse on

# --- True color support ---
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB"

# --- Start windows/panes at 1, not 0 ---
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on

# --- Sensible splits (| and -) ---
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
unbind '"'
unbind %

# --- New windows keep current path ---
bind c new-window -c "#{pane_current_path}"

# --- Navigate panes with Alt+arrow (no prefix needed) ---
bind -n M-Left select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up select-pane -U
bind -n M-Down select-pane -D

# --- Resize panes with Ctrl+arrow ---
bind -r C-Left resize-pane -L 5
bind -r C-Right resize-pane -R 5
bind -r C-Up resize-pane -U 5
bind -r C-Down resize-pane -D 5

# --- History ---
set -g history-limit 50000

# --- No delay on escape (important for helix/zsh) ---
set -sg escape-time 0

# --- Status bar ---
set -g status-position bottom
set -g status-interval 5

# --- Reload config ---
bind r source-file ~/.tmux.conf \; display "Config reloaded"
TMUXEOF

# --- Set up helix config ---
mkdir -p ~/.config/helix
cat > ~/.config/helix/config.toml << 'HELIXEOF'
theme = "catppuccin_mocha"

[editor]
line-number = "relative"
mouse = true
cursorline = true
auto-save = true
bufferline = "multiple"

[editor.cursor-shape]
insert = "bar"
normal = "block"
select = "underline"

[editor.indent-guides]
render = true

[editor.lsp]
display-messages = true
display-inlay-hints = true

[editor.statusline]
left = ["mode", "spinner", "file-name", "file-modification-indicator"]
right = ["diagnostics", "selections", "position", "file-encoding", "file-line-ending", "file-type"]

[keys.normal]
C-s = ":w"
HELIXEOF

# --- Pre-build zgenom plugin cache (so first zsh launch is instant) ---
echo ""
echo "=== Pre-building zgenom plugin cache ==="
if [[ ! -f ~/.zgenom/init.zsh ]]; then
  GIT_TEMPLATE_DIR="" zsh -c '
    ZGEN_DIR="${HOME}/.zgenom"
    source "${ZGEN_DIR}/zgenom.zsh"
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
    zgenom load unixorn/fzf-zsh-plugin
    zgenom load Aloxaf/fzf-tab
    zgenom load romkatv/powerlevel10k powerlevel10k
    zgenom save
  ' 2>&1 || true
  [[ -f ~/.zgenom/init.zsh ]] && echo "  zgenom cache built OK" || echo "  WARNING: zgenom cache build failed"
else
  echo "  zgenom cache already exists, skipping"
fi

echo ""
echo "=== Verifying installation ==="
FAILURES=()

verify() {
  local label="$1"
  local check="$2"
  if eval "$check" &>/dev/null; then
    echo "  OK  $label"
  else
    echo "  FAIL  $label"
    FAILURES+=("$label")
  fi
}

# Shell
verify "zsh is default shell" "[[ \$(getent passwd tom | cut -d: -f7) == */zsh ]]"

# Tools
for cmd in zsh fzf bat fd rg eza lsd tmux jq btop keychain direnv helix chezmoi tldr pkgfile yay; do
  case "$cmd" in
    helix) verify "$cmd on PATH" "command -v hx" ;;
    *)     verify "$cmd on PATH" "command -v $cmd" ;;
  esac
done

# Mise tools
for cmd in sd yq xh gh zoxide; do
  verify "$cmd (mise)" "mise exec -- $cmd --version || mise exec -- which $cmd"
done

# Configs
verify ".zshrc exists" "[[ -f ~/.zshrc ]]"
verify ".tmux.conf exists" "[[ -f ~/.tmux.conf ]]"
verify ".zsh_aliases exists" "[[ -f ~/.zsh_aliases ]]"
verify "helix config exists" "[[ -f ~/.config/helix/config.toml ]]"
verify "zgenom cloned" "[[ -d ~/.zgenom ]]"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo ""
  echo "WARNING: ${#FAILURES[@]} check(s) failed:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
else
  echo ""
  echo "=== All checks passed ==="
fi

echo ""
echo "=== CLI test environment ready ==="
echo "Launch with: wsl -d archlinux"
echo "Then run: zsh (plugins will install on first launch)"
