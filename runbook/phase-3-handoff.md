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
- **Config**: Bare Hyprland with **Claude-authored configs in chezmoi**. NOT HyDE, NOT end-4 — every line is owned by us, applied via `chezmoi apply`. Sources at `dotfiles/dot_config/hypr/` in this repo.
  - Entry point: `~/.config/hypr/hyprland.conf` (sources fragments)
  - Fragments: `monitors.conf`, `workspaces.conf`, `binds.conf`, `decoration.conf`, `animations.conf`, `input.conf`, `exec.conf`, `plugins.conf`, `colors.conf` (matugen-rendered)
  - Lockscreen: `hyprlock.conf` + `hyprlock.colors.conf` (matugen)
  - Idle daemon: `hypridle.conf` (30 min lock, 30 min DPMS off, no idle-hibernate)
- **Theme system**: matugen (Material You from current wallpaper) — see GLOSSARY entry. Master dark/light flip via Super+Shift+T (`~/.local/bin/theme-toggle`).
- **Workspace strategy**: static + monitor-bound (1-5 → DP-1 external Vizio, 6-9 → eDP-1 internal, 10 → scratch floating). See `docs/desktop-requirements.md`.
- **Keybinds**: ~85 rich custom bindings — printable cheat sheet at `runbook/keybinds.md` (auto-generated from `binds.conf` by `validate-hypr-binds --emit-cheatsheet`). Quick reference: Super+Return = ghostty, Super+B = browser, Super+E = VSCode, Super+C = claude, Super+Space = launcher, Super+V = clipboard picker, Super+, = settings panel, Super+grave = workspace overview.
- **Teach me**:
  - The keybind set (use `runbook/keybinds.md` as reference)
  - How to open/close/float windows
  - How workspaces work (static + monitor-bound)
  - How to use the scratch workspace (Super+0)
  - How to configure monitors — `nwg-displays` GUI writes `~/.config/hypr/monitors.conf` (sourced by `hyprland.conf`)
  - Touch gestures: `gesture = 3, horizontal, workspace` (modern Hyprland gestures API); long-press / edge swipes via the **hyprgrass** plugin
  - Lid behaviour: lid-close hibernates (when battery returns); on AC always ignored. Manual hibernate: Super+Shift+H

### Ghostty (Terminal Emulator)
- **What it is**: GPU-accelerated terminal — where zsh/tmux/helix run
- **Config location**: `~/.config/ghostty/config` (managed by chezmoi)
- **Theme**: `theme = matugen` — points at `~/.config/ghostty/themes/matugen` which is rendered by matugen on every wallpaper change / theme-toggle. Reload via SIGUSR2.
- **Font**: JetBrains Mono Nerd Font
- **Reload config**: Ctrl+Shift+, (comma)
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
- **Binary on Arch**: `helix` (NOT `hx` — Arch's `extra/helix` package installs the full-name binary at `/usr/bin/helix`).
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
- **What it is**: Wayland status bar — workspace pills, clock, tray (Bitwarden + others via SNI), network, volume, battery, theme-toggle icon (sun/moon, click to flip dark/light), notifications icon (click to toggle swaync panel), power.
- **Package**: `waybar` (pacman, official extra)
- **Config**: `~/.config/waybar/config.jsonc` (chezmoi-managed) + `~/.config/waybar/style.css` (chezmoi) + `~/.config/waybar/colors.css` (matugen-rendered).
- **Custom modules** at `~/.config/waybar/modules/`: `network.sh` (nmcli wrapper), `theme-toggle.sh` (sun/moon emitter; click handler invokes `theme-toggle`).
- **Reload**: `pkill -SIGUSR2 waybar` (full reload) or `pkill -SIGRTMIN+8 waybar` (re-run custom modules only — used by theme-toggle to refresh the icon).
- **Teach me**: How to add/remove modules, how the matugen-rendered colors.css feeds into style.css, how to bump font sizes for the 4K TV.

### swaync (Notifications)
- **What it is**: Notification daemon + control center. Popups for transient notifications PLUS a pull-out panel showing notification history, do-not-disturb toggle, and MPRIS widget. Bound to Super+N.
- **Config**: `~/.config/swaync/config.json` + `~/.config/swaync/style.css` + `~/.config/swaync/colors.css` (matugen).
- **Reload CSS**: `swaync-client --reload-css`.
- **Teach me**: How to dismiss, mute, history vs popup behavior.

### fuzzel (Launcher / Picker)
- Bound to Super+Space (apps), Super+V (clipboard history via cliphist pipe), Super+, (control panel).
- Config: `~/.config/fuzzel/fuzzel.ini` (chezmoi) + `~/.config/fuzzel/colors.ini` (matugen).

### Docker
- Already know Docker basics from Windows
- **Teach me**: Linux-specific differences (no Docker Desktop, systemd service, user groups)

---

## Touch & Input Devices

### Touchpad Gestures
- Two-finger drag → scroll (libinput default)
- Three-finger tap → middle click (libinput default)
- Three-finger left/right swipe → workspace switch — **modern Hyprland gestures API**: `gesture = 3, horizontal, workspace` (top-level keyword; the older `workspace_swipe` + `workspace_swipe_fingers` keys were removed). Written by chezmoi via `dot_config/hypr/input.conf`.
- Long-press, edge swipes, OSK toggle — via the **hyprgrass** Hyprland plugin (loaded via `hyprpm` in postinstall §13). `hyprpm list` should show it; `hyprctl plugin list` confirms it's loaded.

### Wacom AES Stylus (built-in digitizer)
- Kernel `wacom` module (in-tree linuxwacom); `libwacom` installed for tablet metadata.
- Pressure / tilt expected to work under Wayland out of the box; no `xf86-input-wacom` needed (that's the Xorg driver).
- Quirk to test: eraser-end may need a udev rule if not auto-detected.

### Touchscreen
- Driven by `hid-multitouch` (kernel) + libinput; works out of the box.
- **Verify on hardware**: confirm panel chipset with `dmesg | grep -i -E 'wacom|goodix|hid-multitouch'` — Dell's 7786 revision can be Wacom-AES or Goodix; the touchscreen-driver assumption above is unverified until hardware says so.

### On-screen Keyboard (tablet mode)
- **wvkbd** (`wvkbd-mobintl`) — de-facto Hyprland OSK as of 2026. Toggle via a hyprgrass long-press gesture or a manual keybind.
- Maliit and squeekboard render poorly under Hyprland; do not switch without testing.

### Auto-rotation
- `iio-sensor-proxy` (pacman) reads the accelerometer.
- `iio-hyprland` (AUR) bridges the proxy to `hyprctl keyword monitor` transforms — `exec-once = iio-hyprland` is in `hyprland.conf` (postinstall §13a).
- Manual rotation override: `hyprctl keyword monitor eDP-1,preferred,auto,1,transform,1` (0=normal, 1=90°, 2=180°, 3=270°).

### Tablet-mode detection (deferred to phase-3.5)
- Kernel emits `SW_TABLET_MODE` events on a `gpio-keys` / `intel-hid` input device.
- Bind via udev + script that toggles OSK + disables keyboard/touchpad. Not wired yet.

### Fingerprint Reader
- fprintd + libfprint
- **Device**: Goodix `27c6:538c` — supported via AUR `libfprint-goodix-53xc` (older Dell OEM blob) on top of `libfprint-tod-git` built with `!lto`. See `docs/decisions.md` requirement list for the rationale. Do NOT swap to `libfprint-2-tod1-goodix` / `-v2` — those ship the 550A-only blob fork.
- **Post-install**: 5 fingers pre-enrolled by `postinstall.sh` (right-index, left-index, right-middle, left-middle, right-thumb). Use `sudo fprintd-enroll -f <finger> tom` to add more (polkit denies unprivileged enroll from bare TTY).
- Integrate with: login (greetd), sudo, screen lock (hyprlock)

---

## System Configuration

### Lid + Idle Behavior
- **AC**: Lid close ignored (`HandleLidSwitchExternalPower=ignore`).
- **Battery** (when one is installed): Lid close hibernates (`HandleLidSwitch=hibernate`). Currently dead code (battery dead/disconnected per decisions.md `Battery` bullet) — flips to live the moment a battery returns, no reconfig.
- **Idle** (hypridle): display off at 28 min, screen lock at 30 min. No idle-hibernate.
- **Manual hibernate**: Super+Shift+H (only graceful path until battery is replaced — AC removal is an instant hard-cut).
- Config: `/etc/systemd/logind.conf.d/10-lid.conf` (logind) + `~/.config/hypr/hypridle.conf` (idle daemon).

### NVIDIA
- MX250 is blacklisted (incompatible with Wayland/Hyprland — nvidia-470xx lacks GBM)
- Running Intel UHD 620 only
- HDMI port is wired to Intel iGPU — external monitor works without NVIDIA
- If nvidia modules are loading, check `/etc/modprobe.d/blacklist-nvidia.conf`

### Dual Boot
- Windows and Arch share the EFI partition on Samsung 512GB SSD
- **Bootloader**: limine (replaced systemd-boot). Config: `/boot/limine.conf`. UEFI binary at `/boot/EFI/BOOT/BOOTX64.EFI` (fallback path so Windows wiping NVRAM doesn't kill us).
- **Snapper integration**: `limine-snapper-sync` auto-generates boot menu entries from snapper snapshots — pick yesterday's snapshot at the menu to roll back a bad pacman update.
- Samsung layout: [EFI 512MB] [MSR 16MB] [Windows 160GiB] [Linux ~316GiB LUKS + btrfs with @, @home, @snapshots]
- Netac 128GB: [ArchRecovery 1.5GiB] [ArchSwap 16GiB LUKS, hibernate-ready] [ArchVar 110GiB LUKS ext4 → /var/log + /var/cache binds]
- SATA mode: AHCI (RAID hides the drives from Linux installer)
- Windows Fast Startup and hibernation: **disabled** on Windows side. Linux hibernation: **enabled** (S4) with TPM2-sealed cryptswap (per `decisions.md` Battery bullet).
- Windows partition mounted read-only at /mnt/windows for media access

### Browsers
- Edge (default) — sync with Windows side. Installed from AUR (`microsoft-edge-stable-bin`).
- Firefox — **not installed by default**. Add with `sudo pacman -S firefox` if you want a Wayland-native fallback.

### Audio
- PipeWire + WirePlumber
- Bluetooth audio supported
- JACK compatibility for potential future Bitwig/audio production

### Theme & Appearance
- **matugen** (Material You) generates a full color palette from the current wallpaper. Templates render to: waybar, swaync, fuzzel, ghostty, Hyprland colors.conf, hyprlock, GTK 3+4 CSS, qt5ct/qt6ct color schemes, yazi theme, helix theme, zathura colors, ReGreet CSS.
- Wallpaper rotation: `~/.local/bin/wallpaper-rotate` (every 6h via systemd user timer). Wallpapers live in `~/Pictures/Wallpapers/` (bootstrapped from `fnrhombus/callisto`'s `static/wallpaper/linux/` on first chezmoi apply).
- Master dark/light flip: Super+Shift+T → `~/.local/bin/theme-toggle` flips matugen mode + broadcasts via the freedesktop color-scheme portal so GTK4/Qt6.9+/Firefox/Chromium follow.
- Cursor: Bibata-Modern-Classic in hyprcursor format (~6.6 MB) + the Xcursor build for Xwayland app fallback.
- Icons: Papirus-Dark (best app coverage).
- JetBrains Mono Nerd Font (default), FiraCode also installed.
- Greeter (greetd + ReGreet): GTK CSS at `/etc/greetd/regreet.css`, rendered by matugen at install time. Live theme-following deferred — re-render manually via `sudo install -m 644 ~/.cache/matugen/regreet.css /etc/greetd/regreet.css && sudo systemctl restart greetd`.

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
- hyprland, xdg-desktop-portal-hyprland, xdg-desktop-portal-gtk, polkit
- noto-fonts, noto-fonts-emoji, ttf-jetbrains-mono-nerd
- mesa, intel-media-driver, vulkan-intel, libva-intel-driver
- bluez, bluez-utils, fprintd
- snapper

(`sddm` removed — greeter is greetd, installed by chroot.sh)

### Installed by chroot.sh (during arch-chroot)
- limine, greetd, greetd-regreet, tpm2-tss, tpm2-tools, libsecret, gnome-keyring

### From official repos (pacman, phase-3 postinstall.sh §1)
- Core CLI: bat, fd, ripgrep, eza, lsd, btop, jq, fzf, zoxide, direnv, sd, yq, xh, pkgfile, tldr, github-cli
- Screenshots/clipboard: wl-clipboard, grim, slurp, cliphist, satty, hyprshot
- Terminal: ghostty (daily driver)
- File managers: yazi (TUI primary), nautilus (GUI fallback)
- Hyprland ecosystem: hyprlock, hypridle, hyprpolkitagent, hyprpicker
- Bar / notifications / launcher / OSD: waybar, swaync, fuzzel, swayosd
- Settings GUIs: nwg-displays, nwg-look, network-manager-applet (provides nm-connection-editor), pwvucontrol
- Theme managers: qt5ct, qt6ct, papirus-icon-theme
- Daily-use viewers: imv, zathura, zathura-pdf-poppler
- 2-in-1 hardware: iio-sensor-proxy (accelerometer), wvkbd (on-screen keyboard), libwacom (Wacom AES metadata)
- Remote desktop: remmina + freerdp
- Password/vault: bitwarden, bitwarden-cli
- Version manager: mise
- Dotfile manager: chezmoi
- Virtualization: docker, docker-compose, docker-buildx
- Snapshots: snap-pac
- Fonts: ttf-firacode-nerd
- Misc: xdg-user-dirs

### From AUR (yay, phase-3 postinstall.sh §3)
- visual-studio-code-bin
- microsoft-edge-stable-bin
- claude-desktop-native (unofficial repackage of Anthropic's Windows Electron build — expect occasional breakage on Anthropic updates)
- pinpam-git (PAM module — `libpinpam.so`, NOT `pam_pinpam.so` — for TPM-backed PIN at sudo + hyprlock)
- sesh (tmux session picker)
- iio-hyprland-git (accelerometer → `hyprctl monitor` transform bridge for 2-in-1 auto-rotation)
- powershell-bin
- awww (Wayland wallpaper daemon — continuation of archived swww)
- matugen-bin (Material You palette generator from wallpaper)
- mission-center (resource monitor GUI)
- overskride (Bluetooth GUI, GTK4)
- wleave (logout/power menu, GTK4)
- bibata-cursor (Xcursor format for Xwayland fallback)
- bibata-cursor-translated (hyprcursor format, ~6.6 MB)
- pacseek (TUI fuzzy package installer)
- libfprint-goodix-53xc (Goodix 538C fingerprint blob — built on libfprint-tod-git with `!lto` workaround)

### Hyprland plugins (via `hyprpm`, phase-3 postinstall.sh §13)
- hyprexpo (Mission-Control workspace overview, bound to Super+grave)
- hyprgrass (touch gesture engine for the 2-in-1)

### Via mise (tool version manager, phase-3 postinstall.sh)
- `node@lts` — installed globally (`mise use -g node@lts`). Other runtimes (python, pnpm, dotnet, etc.) are installed per-project via `.mise.toml`, not globally.

### Via npm global (installed through mise-managed node)
- `@anthropic-ai/claude-code` — installed by postinstall.sh via `mise exec -- npm install -g`; NOT a mise plugin

### Other (git clones, phase-3 postinstall.sh)
- zgenom (zsh plugin manager — `~/.zgenom`)
- tpm (tmux plugin manager — `~/.tmux/plugins/tpm`)

### Known deferred (phase-3.5 hardware handoff)
- Tablet-mode detection (`SW_TABLET_MODE` udev rule + script that toggles OSK and disables keyboard/touchpad).
- Palm rejection tuning (`LIBINPUT_ATTR_PALM_PRESSURE_THRESHOLD` quirk).
- Wacom AES eraser-end udev quirk if it doesn't auto-detect.
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
9. Fingerprint auth (greetd, sudo, hyprlock screen lock)
10. Audio (PipeWire + Bluetooth)
11. Auto-rotation for tablet mode
12. Clipboard history (cliphist + fuzzel keybind)
13. Screenshots (hyprshot + satty keybinds)
14. chezmoi — import configs into managed dotfiles
15. Edge + Firefox browser setup + Bitwarden extension

## Upgrade Paths (for later)
- **Helix → Neovim**: If you outgrow Helix's built-ins and want infinite extensibility
- **btop → glances**: If you want remote web-based system monitoring
- **Bibata + Papirus → Quickshell-based shell** (DankMaterialShell, qsbar, etc.): The 2026 trend is full-stack shell replacements. They'd subsume waybar+swaync+fuzzel+hyprlock together — not a drop-in. Reconsider if you want a more cohesive look at the cost of less per-component flexibility.
- **fuzzel → walker / anyrun**: Other Wayland launchers if fuzzel turns out limiting (it hasn't so far for any documented user).
- **Single channel → Dual channel RAM**: Add matching 16GB DDR4-2400 SODIMM stick.
- **Replace dead battery**: Lid-close hibernate flips from dead-code to active automatically (logind config is forward-compat).
- **Secure Boot via sbctl**: Currently disabled. Enable in firmware (Setup Mode), enroll keys via `sbctl create-keys && sbctl enroll-keys --microsoft && sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI`, re-enroll TPM2 PCR slots against the new SB-on PCR state.
