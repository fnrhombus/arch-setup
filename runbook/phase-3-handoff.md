# Arch Linux Handoff Guide — Learning & Configuration

This document is meant to be fed to Claude Code once you're inside Arch Linux. It contains everything Claude needs to know about your system, your decisions, and what you need help learning.

## Who You Are
- Primary dev: TypeScript+React, C#, Node, Electron, embedded (ESP32/Pico)
- Coming from Windows + VSCode + Docker
- No vim/terminal editor experience — willing to learn
- Doesn't enjoy endless config tweaking, but wants an awesome system
- Goal: eventually Linux-only (Windows dual-boot is a safety net)
- GitHub username: fnrhombus
- Has an existing WSL zsh/tmux setup (fnwsl repo) — carry over patterns where appropriate

## System Hardware
- Dell Inspiron 7786 (17" 2-in-1 convertible, touchscreen)
- Intel i7-8565U, 16GB DDR4-2400 (single channel — consider adding second stick)
- Intel UHD 620 only (NVIDIA MX250 blacklisted — incompatible with Wayland)
- Samsung SSD 840 PRO 512GB — SATA SSD, ~540 MB/s (dual-boot: Windows + Arch)
- Netac SSD 128GB — SATA SSD (Windows C: from previous install, may repurpose)
- External monitor via HDMI direct (DisplayLink dock used only for ethernet + USB hub, not video)
- Wacom Intuos pen tablet
- Dell Wireless 1801 WiFi (Qualcomm Atheros) + BT 4.0
- Fingerprint reader

---

## Installed Stack (teach me these)

### Hyprland (Window Manager)
- **What it is**: Tiling Wayland compositor — windows auto-arrange, keyboard-driven
- **Config location**: `~/.config/hypr/hyprland.conf`
- **Using end-4/illogical-impulse dotfiles** as the base
- **Teach me**:
  - Core keybindings (move focus, move windows, resize, workspaces)
  - How to open/close/float windows
  - How workspaces work
  - How to use the scratchpad
  - How to configure monitors (laptop + external HDMI)
  - Touch gestures setup

### Ghostty (Terminal Emulator)
- **What it is**: GPU-accelerated terminal — where zsh/tmux/helix run
- **Config location**: `~/.config/ghostty/config`
- **Theme**: Catppuccin Mocha
- **Font**: JetBrains Mono Nerd Font
- **Teach me**: Ghostty-specific features (if any beyond basic terminal use)

### tmux (Terminal Multiplexer)
- **What it is**: Lets you split terminals into panes, manage sessions, persist work
- **Config location**: `~/.tmux.conf`
- **Prefix key**: Ctrl+a (remapped from Ctrl+b, carried from fnwsl)
- **Why I have it**: Claude Code uses tmux for worktree workflows
- **Teach me**:
  - The prefix key concept (Ctrl+a, then the command key)
  - Creating/splitting panes: `|` for horizontal, `-` for vertical
  - Navigating between panes: Alt+arrow keys (no prefix needed)
  - Sessions: creating, switching, detaching, reattaching
  - The worktree workflow: one session per worktree, fuzzy-switch with sesh/fzf
  - Copy mode (selecting/copying text from terminal output)
  - How to use with Claude Code's worktree features

### Helix (Terminal Editor)
- **What it is**: Modal terminal editor — select-then-act model (NOT vim keybindings)
- **Config location**: `~/.config/helix/config.toml`
- **Why I have it**: Quick terminal edits; zero-config LSP/autocomplete
- **Teach me**:
  - Normal mode vs Insert mode (how to switch)
  - The select-then-act paradigm: you select text FIRST, then choose what to do with it
  - Basic movement (hjkl or arrow keys, word, line, file)
  - Selecting text (w for word, x for line, % for file)
  - Editing (d delete, c change, y yank/copy, p paste)
  - Space menu (the main command palette — press Space to see options)
  - File picker (Space+f), buffer picker (Space+b)
  - Search (/)
  - Multiple cursors (the killer feature — C to add cursor, select then split)
  - LSP features: go-to-definition, references, rename, diagnostics
  - How it differs from vim (so I don't get confused by online tutorials)

### zsh (Shell)
- **What it is**: POSIX-compatible shell with extensive plugin ecosystem
- **Config location**: `~/.zshrc` (managed by zgenom plugin manager)
- **Prompt**: powerlevel10k
- **Already familiar from fnwsl** — same plugin stack, adapted for Arch
- **Key plugins**:
  - autosuggestions (right arrow to accept ghost suggestions)
  - fast-syntax-highlighting (red = typo, green = valid)
  - fzf-tab (fuzzy tab completion)
  - history-substring-search (up/down searches by what you've typed)
  - Esc-Esc to prepend sudo (omz/sudo)
- **Arch differences from WSL**:
  - `command-not-found` uses `pkgfile` instead of apt
  - Package management via `pacman`/`yay` instead of `apt`
  - No WSL interop aliases needed
- **Teach me**: Arch-specific workflow differences only (already know zsh basics)

### VSCode
- Already know this — just need Linux-specific setup
- **Teach me**:
  - Wayland-native mode vs XWayland
  - Any Hyprland-specific window rules needed

### Waybar (Status Bar)
- **Config location**: `~/.config/waybar/`
- Part of illogical-impulse dotfiles — may need customization
- **Teach me**: How to add/remove/configure modules

### Docker
- Already know Docker basics from Windows
- **Teach me**: Linux-specific differences (no Docker Desktop, systemd service, user groups)

---

## Touch & Input Devices

### Touchpad Gestures
- Two-finger drag → scroll
- Three-finger tap → middle click
- Three-finger left/right swipe → back/forward
- Single-finger double-tap+drag → drag/drop

### Wacom Intuos Tablet
- Needs libwacom + Hyprland tablet config
- Should work for drawing/input in supported apps

### Touchscreen
- Should work via libinput
- Auto-rotation via iio-sensor-proxy when in tablet mode

### Fingerprint Reader
- fprintd + libfprint
- Integrate with: login (SDDM), sudo, screen lock

---

## System Configuration

### Lid Behavior
- Do NOT sleep/shutdown when lid is closed on AC power
- Config: `/etc/systemd/logind.conf` → `HandleLidSwitchExternalPower=ignore`

### NVIDIA
- MX250 is blacklisted (incompatible with Wayland/Hyprland — nvidia-470xx lacks GBM)
- Running Intel UHD 620 only
- HDMI port is wired to Intel iGPU — external monitor works without NVIDIA
- If nvidia modules are loading, check `/etc/modprobe.d/blacklist-nvidia.conf`

### Dual Boot
- Windows and Arch share the EFI partition on Samsung 512GB SSD
- Bootloader: systemd-boot
- Samsung layout: [EFI 512MB] [MSR 16MB] [Windows 160GiB] [Linux ~316GiB btrfs with @, @home, @snapshots]
- Netac 128GB: [Arch recovery ISO] [swap 16GB] [/var/log + /var/cache ext4]
- SATA mode: switched from RAID to AHCI
- Windows Fast Startup and hibernation disabled
- Windows partition mounted read-only at /mnt/windows for media access

### Browsers
- Edge (default) — sync with Windows side. Installed from AUR (`microsoft-edge-stable-bin`).
- Firefox — **not installed by default**. Add with `sudo pacman -S firefox` if you want a Wayland-native fallback.

### Audio
- PipeWire + WirePlumber
- Bluetooth audio supported
- JACK compatibility for potential future Bitwig/audio production

### Theme & Appearance
- Catppuccin Mocha across all apps
- JetBrains Mono Nerd Font (default), with FiraCode, CascadiaCode, Hack, MesloLGS also installed
- SDDM login screen with Catppuccin theme

---

## Software Inventory

Everything listed below is installed automatically by the phase-2 + phase-3 scripts. This section is a reference for what's on the machine when `postinstall.sh` finishes; don't re-run these by hand.

### Base (pacstrap, phase-2-arch-install/install.sh)
- base, base-devel, linux, linux-firmware, linux-headers, linux-lts, linux-lts-headers, intel-ucode
- btrfs-progs, e2fsprogs, dosfstools
- networkmanager, iwd, wpa_supplicant, openssh
- sudo, git, vim, helix, zsh, tmux, efibootmgr
- man-db, man-pages, texinfo
- pipewire, pipewire-pulse, pipewire-jack, wireplumber
- sddm, hyprland, xdg-desktop-portal-hyprland, polkit
- noto-fonts, noto-fonts-emoji, ttf-jetbrains-mono-nerd
- mesa, intel-media-driver, vulkan-intel, libva-intel-driver
- bluez, bluez-utils, fprintd
- snapper

### From official repos (pacman, phase-3 postinstall.sh)
- Core CLI: bat, fd, ripgrep, eza, lsd, btop, jq, fzf, zoxide, direnv, sd, yq, xh, pkgfile, tldr, github-cli
- Screenshots/clipboard: wl-clipboard, grim, slurp, cliphist, satty, hyprshot
- Desktop extras: ghostty, fuzzel, swaync
- Password/vault: bitwarden, bitwarden-cli
- Version manager: mise
- Dotfile manager: chezmoi
- Virtualization: docker, docker-compose, docker-buildx
- Snapshots: snap-pac
- Session manager: sesh (tmux session picker)
- Fonts: ttf-firacode-nerd
- Misc: xdg-user-dirs

### From AUR (yay, phase-3 postinstall.sh)
- visual-studio-code-bin
- microsoft-edge-stable-bin
- catppuccin-sddm-theme-mocha
- pinpam-git (PAM module used by fprintd login stack)

### Via mise (tool version manager, phase-3 postinstall.sh)
- `node@lts` — installed globally (`mise use -g node@lts`). Other runtimes (python, pnpm, dotnet, etc.) are installed per-project via `.mise.toml`, not globally.

### Via npm global (installed through mise-managed node)
- `@anthropic-ai/claude-code` — installed by postinstall.sh via `mise exec -- npm install -g`; NOT a mise plugin

### Other (git clones, phase-3 postinstall.sh)
- zgenom (zsh plugin manager — `~/.zgenom`)
- tpm (tmux plugin manager — `~/.tmux/plugins/tpm`)

### Known deferred (phase-3.5 hardware handoff)
- Wacom pen/tablet stack: `libwacom`, `xf86-input-wacom` — only installed if the pen stylus enumerates on real hardware.
- Auto-rotation: `iio-sensor-proxy` — deferred for the same reason.
- Jupyter, extra Python scientific libs: install on demand once the machine is in use.
- Firefox: deliberately not installed — Edge is the default browser. Add with `sudo pacman -S firefox` if you want it.
- dotnet SDK: not installed by default. Add per-project via `mise use dotnet@lts` when needed.

---

## Things to Set Up Together
1. Hyprland basics — navigate with confidence
2. Ghostty + tmux — terminal workflow
3. tmux sessions + worktree workflow with sesh/fzf
4. Helix — basic editing fluency
5. zsh — verify plugins work, learn Arch-specific differences
6. Git worktree workflow with Claude Code + tmux
7. Dev environment (Docker, Node, .NET, Python, Jupyter)
8. Touch gestures + Wacom tablet
9. Fingerprint auth (SDDM, sudo, screen lock)
10. Audio (PipeWire + Bluetooth)
11. Auto-rotation for tablet mode
12. Clipboard history (cliphist + fuzzel keybind)
13. Screenshots (hyprshot + satty keybinds)
14. chezmoi — import configs into managed dotfiles
15. Edge + Firefox browser setup + Bitwarden extension

## Upgrade Paths (for later)
- **fuzzel → rofi-wayland**: When you want scripting, custom modes (calculator, emoji picker, SSH, window switcher)
- **Helix → Neovim**: If you outgrow Helix's built-ins and want infinite extensibility
- **btop → glances**: If you want remote web-based system monitoring
- **stow → chezmoi**: Already done — chezmoi is the plan
- **Single channel → Dual channel RAM**: Add matching 16GB DDR4-2400 SODIMM stick
