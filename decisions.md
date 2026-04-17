# Arch Linux Dual-Boot Setup — Decisions & Notes

## System
- **Laptop**: Dell Inspiron 7786 (17" 2-in-1 convertible)
- **CPU**: Intel i7-8565U (4c/8t, Whiskey Lake)
- **RAM**: 16GB DDR4 2667MHz
- **GPU**: NVIDIA GeForce MX250 (2GB) + Intel UHD 620 (Optimus)
- **Target Drive**: Samsung SSD 840 PRO 512GB (currently D: + V:)
- **WiFi**: Dell Wireless 1801 (Qualcomm Atheros) + BT 4.0
- **Display**: Integrated touch + external Vizio via USB DisplayLink dock
- **Boot**: UEFI, Secure Boot ON, GPT, SATA in RAID mode
- **Peripherals**: Touchscreen, touchpad, fingerprint reader, active pen
- **Battery**: NONE — the internal battery is dead / removed. Laptop is always on AC power, lives stashed under a desk. Downstream consequences:
  - Lid-close "suspend on battery" branch in `logind.conf` is dead code (systemd-logind never sees battery state). Harmless; left in for portability if a battery ever returns.
  - Hibernation is disabled (dual-boot + BitLocker would make it risky anyway) — swap sized for pressure relief only, not hibernate-to-disk. Could shrink from 16 GB → 4 GB in a future pass if `/var` on Netac runs tight.
  - Abrupt shutdowns (power cable kick) are the norm. btrfs COW handles this well — no `fsync` required for metadata integrity. Good argument for btrfs over ext4 on root.
  - SDDM is the primary moment of the day where the user authenticates (no suspend/resume cycles → no lock screens) — fingerprint at SDDM is therefore load-bearing, not cosmetic.

## Requirements
- [ ] Fingerprint scanner support (fprintd + libfprint)
- [ ] Lid close: no sleep/shutdown on AC power (logind.conf)
- [ ] Wacom Intuos pen tablet support
- [ ] Touch gestures (touchpad + tablet mode):
  - Two-finger drag → scroll
  - Three-finger tap → middle click
  - Three-finger left/right swipe → back/forward
  - Single-finger double-tap+drag → drag/drop
- [ ] Auto-rotation (2-in-1 tablet mode, iio-sensor-proxy)
- [ ] Bitwarden (self-hosted: https://hass4150.duckdns.org:7277/)
- [ ] RDP client for accessing Windows 10 machine
- [ ] Photogrammetry (uses 3DF Zephyr on Windows; Meshroom or Metashape for Linux later)
- [ ] Python + Jupyter notebooks
- [ ] (nice-to-have) CursorWrap — mouse wraps around monitor edges (no native Hyprland support yet; may need custom script/plugin)

## Decisions

### Q1: Primary Use Case
- **Primary dev**: TypeScript+React (client), C# (server), Electron, Node
- **Android**: React Native (future, will research when needed)
- **Embedded**: ESP32, Raspberry Pi Pico (C++, CircuitPython, ESPHome)
- **Tools**: VSCode, Docker. No vim experience.
- **AI/ML**: Not now, but wants the option in the future
- **General productivity**: Yes — this will be primary machine. Windows dual-boot is a safety net; goal is eventually Linux-only.
- **Audio creation**: Former big hobby (Ableton, Bitwig, Traktor). Dormant but wants it available.
- **Tinkering philosophy**: Does NOT enjoy endless config tweaking. Loves having an awesome system. Doing Arch now because Claude can get it configured correctly with minimal effort.

### Q2: Desktop Experience
- **Tiling Window Manager** — keyboard-driven, no overlapping windows

### Q3: Compositor
- **Hyprland** — eye-candy king, GPU-accelerated animations, blur, rounding
- Will use **end-4/illogical-impulse** dotfiles as a starting point

### Q4: DisplayLink / External Monitor
- **Monitor via HDMI** direct to laptop (bypasses DisplayLink video — avoids Wayland issues)
- **Keep using dock** for ethernet + USB hub (standard USB passthrough, no special drivers)
- DisplayLink video issues are display-only; hub/ethernet work natively on Linux

### Q5: NVIDIA
- **Intel UHD 620 only** — blacklist NVIDIA modules, disable MX250
- MX250 requires nvidia-470xx driver which lacks GBM (no Wayland support at all)
- HDMI port is wired to Intel iGPU — external monitor works without NVIDIA
- Saves battery, eliminates driver maintenance

### Q6: Editor & IDE
- **VSCode** (`visual-studio-code-bin` from AUR) — primary IDE, familiar, productive day one
- **Helix** — terminal editor for quick edits, zero-config, built-in LSP/treesitter/autocomplete
- Select-then-act model (Kakoune-inspired), more intuitive than vim for newcomers

### Q7: Terminal Multiplexer
- **tmux** — required for Claude Code worktree support (Zellij not yet supported)
- Worktree workflow: one session per worktree, fuzzy-switch via sesh/fzf
- Plugins: tpm (plugin manager), sesh (session manager), tmux-worktree

### Q8: Shell
- **zsh** with zgenom plugin manager (same setup as fnwsl, adapted for Arch)
- **powerlevel10k** prompt
- Plugins: fast-syntax-highlighting, autosuggestions, history-substring-search, zsh-completions, fzf-zsh-plugin, fzf-tab
- OMZ: sudo, colored-man-pages, extract, command-not-found (pkgfile on Arch), docker, docker-compose, npm, pip, dotnet
- Tools: mise, zoxide, direnv, keychain, bat, fd, rg, eza, lsd, btop, jq, sd, yq, xh, tldr, gh
- Aliases & settings carried from fnwsl (eza cascade, navigation, mc function, history opts)
- tmux config carried from fnwsl (Ctrl+a prefix, mouse, sensible splits)

### Q9: Partition Plan

**Samsung 512GB SSD (main):**
```
[EFI 512MB FAT32] [MSR 16MB] [Windows 160GB NTFS] [Linux ~316GB btrfs]
```

**Netac 128GB SSD (secondary — non-speed-critical):**
```
[Arch recovery ISO ~1.5GB] [swap 16GB] [/var/log + /var/cache ~110GB ext4]
```
- Recovery partition: Arch live ISO written to partition, bootable via systemd-boot entry
- Replaces need for live USB after initial install

- **btrfs subvolumes**: @, @home, @snapshots
- **Mount options**: compress=zstd,noatime
- /var/log and /var/cache on Netac — keeps them off btrfs snapshots and off NVMe
- Windows partition mounted read-only at /mnt/windows for media access
- Resize strategy: shrink Linux left → grow Windows right (no swap in the way)
- Disable Windows Fast Startup + hibernation for clean dual-boot
- Switch SATA from RAID to AHCI before install

### Q10: Other Needs

#### A) Bootloader: systemd-boot
- Simplest, fastest, already part of systemd
- Arch recovery ISO on Netac partition (bootable via systemd-boot entry)
- USB still needed for initial install only

#### B) AUR helper: yay
- Less strict about PKGBUILD review prompts, better fit for user who won't read them

#### C) Terminal emulator: Ghostty
- GPU-accelerated, great defaults, Kitty graphics protocol support
- Pairs with tmux for splits/sessions

#### D) Login screen: SDDM
- Wayland-native, themeable, fingerprint integration

#### E) Notifications: swaync
- Notification center with history panel, DND toggle, Waybar integration

#### F) App launcher: fuzzel
- Wayland-native, lightweight, fuzzy matching
- Also used as the picker for clipboard history (cliphist)
- **Upgrade path**: rofi-wayland if you want scripting, custom modes (calculator, emoji, SSH picker, window switcher)

#### G) Screenshots: grimblast + satty
- grimblast: capture region/window/screen to file or clipboard
- satty: annotate (arrows, boxes, blur, text) after capture

#### H) Clipboard: wl-clipboard + cliphist
- Clipboard history (text + images), fuzzel as picker via keybind

#### I) Audio: PipeWire + WirePlumber
- Handles desktop audio, Bluetooth, and JACK (pro audio) compatibility
- Bitwig-ready if audio production hobby returns

#### J) Fonts: JetBrains Mono Nerd Font (default)
- Install all: JetBrains Mono, FiraCode, CascadiaCode, Hack, MesloLGS (all Nerd Font variants)
- Configure JetBrains Mono as default in Ghostty, Helix, VSCode, Waybar, SDDM
- Others available for swapping

#### K) Theme: Catppuccin Mocha
- Applied across: Ghostty, Helix, VSCode, Waybar, GTK, Qt, SDDM, browser, btop, tmux

#### L) Dotfiles: chezmoi
- Template-based, git-backed, Bitwarden integration for secrets
- Can unify fnwsl + Arch configs in one repo with machine-specific templates

#### M) System monitor: btop
- Already familiar from fnwsl

#### N) Browser: Edge (default) + Firefox
- Edge (`microsoft-edge-stable-bin` AUR) as default for sync continuity with Windows
- Firefox installed as backup / best native Wayland experience

#### O) RDP client: Remmina
- Full-featured GUI, connection manager, Wayland-native
- For accessing Windows 10 machine
