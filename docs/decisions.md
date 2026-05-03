# Arch Linux Dual-Boot Setup — Decisions & Notes

## System
- **Laptop**: Dell Inspiron 7786 (17" 2-in-1 convertible)
- **CPU**: Intel i7-8565U (4c/8t, Whiskey Lake)
- **RAM**: 16GB DDR4-2400 (Dell spec; i7-8565U's official DDR4 ceiling is 2400 anyway)
- **GPU**: NVIDIA GeForce MX250 (2GB) + Intel UHD 620 (Optimus)
- **Target Drive**: Samsung SSD 840 PRO 512GB (currently D: + V:)
- **WiFi**: Dell Wireless 1801 (Qualcomm Atheros) + BT 4.0
- **Display**: Integrated touch + external Vizio via USB DisplayLink dock
- **Boot**: UEFI, GPT. *Before install*: BIOS → SATA Operation = **AHCI** (RAID/Intel-RST hides the SATA controller from the Arch installer); disable **Secure Boot** for the install (limine UEFI binary isn't signed out of the box; re-enable later with `sbctl` signing — see `runbook/phase-3-handoff.md` Upgrade Paths).
- **Peripherals**: Touchscreen (capacitive only — NO active pen on the 17" 7786, only the 13"/15" 7000-series got AES digitizers), touchpad, fingerprint reader. External Wacom Intuos USB tablet supported when plugged in.
- **Battery**: NONE *currently* — the internal battery is dead / removed; user plans to replace it. Laptop is always on AC power, lives stashed under a desk. Downstream consequences:
  - Lid-close hibernate is owned by `~/.local/bin/lid-handler` from the user's Hyprland session (logind defers across the board — see Lid-close Requirement). The battery branch is therefore handler-driven and live the moment a battery returns; no reconfiguration needed.
  - **Hibernation is enabled** (S4). Until the battery is replaced, hibernate is **user-invoked** (`Super+Shift+H`) since AC removal is an instant hard-cut. Swap sized 16 GiB to match RAM, lives as a NoCOW swapfile inside the LUKS-encrypted btrfs root (subvolume `@swap`) — see §Q9 + §Q11. See `docs/desktop-requirements.md` §Hibernate for the full plan.
  - Abrupt shutdowns (power cable kick) are the norm. btrfs COW handles this well — no `fsync` required for metadata integrity. Good argument for btrfs over ext4 on root.
  - The greeter is the primary moment of the day where the user authenticates (no suspend/resume cycles → no lock screens) — fingerprint at the greeter is therefore load-bearing, not cosmetic.

## Requirements
- [x] Fingerprint scanner support (fprintd + libfprint). **Device: Goodix `27c6:538c`** — supported only via the AUR `libfprint-goodix-53xc` package (older Dell OEM blob, pre-v0.0.11) riding on `libfprint-tod-git`. Current upstream AUR `libfprint-2-tod1-goodix` / `-v2` ship a **550A-only** blob that does NOT cover 538C. `libfprint-tod-git` must be built with `!lto` in PKGBUILD options — LTO strips ABI symbol versioning and breaks the link. `postinstall.sh` pre-flights this automatically. Enrollment on a bare TTY needs `sudo fprintd-enroll -f <finger> tom` (polkit denies unprivileged enroll without a graphical session).
- [x] Lid close: hibernate, *unless* on AC with an external monitor attached — in that case disable `eDP-1` (re-enabled on lid open). On battery the rule is unconditional hibernate. All logic lives in `~/.local/bin/lid-handler` ([rhombu5/dots](https://github.com/rhombu5/dots)) wired via `binddl` on `Lid Switch` in `dot_config/hypr/binds.conf`. Logind defers entirely (`Handle*=ignore` everywhere, written by phase-2 `chroot.sh` to `/etc/systemd/logind.conf.d/10-lid.conf`); side effect at the greeter / TTY (no Hyprland) lid close is a no-op, which is fine since those states only exist with the laptop physically open.
- [ ] **External** Wacom Intuos USB tablet support (only when plugged in — the 17" 7786 has NO built-in active digitizer, capacitive touch only). `libwacom` + the in-tree kernel `wacom` driver are both installed by `postinstall.sh`. Pressure/tilt work under Wayland via libinput; per-tablet pressure curves go in `dot_config/hypr/input.conf` `device:` blocks in [rhombu5/dots](https://github.com/rhombu5/dots).
- [x] **Touchscreen** — ELAN i2c-hid (`ELAN2097:00 04F3:2666`), bound by the in-kernel `i2c-hid-acpi` → `hid-multitouch` chain. NOT Goodix — the `27c6:*` Goodix on this machine is the **fingerprint** reader. NOT IPTS either (Surface-only). Whiskey-Lake quirk: live ISO often doesn't autoload `i2c-hid-acpi` until userspace, so the touchscreen is invisible from the live ISO and visible from the installed system.
- [x] Touch gestures (touchpad + tablet mode):
  - Two-finger drag → scroll (libinput default, no config needed)
  - Three-finger tap → middle click (libinput default)
  - Three-finger left/right swipe → workspace switch (`gestures { workspace_swipe = true; workspace_swipe_fingers = 3 }` in `hyprland.conf` — wired by postinstall §13a)
  - Hyprland's native touchscreen behavior is sufficient as of 2026-05-02 — no extra plugin installed by default. **`hyprgrass`** (Hyprland touch-gesture plugin: single-finger long-press, edge swipes, OSK toggle) remains an opt-in if richer touchscreen gestures are ever wanted: `hyprpm add https://github.com/horriblename/hyprgrass`.
  - On-screen keyboard: **wvkbd** (`wvkbd-mobintl`) — de-facto OSK for Hyprland as of 2026; maliit and squeekboard render poorly under Hyprland.
- [ ] Auto-rotation (2-in-1 tablet mode): `iio-sensor-proxy` (pacman) +
  `iio-hyprland` (AUR) — iio-hyprland reads the IIO accelerometer and emits
  `hyprctl keyword monitor` transforms. Wired by postinstall as `exec-once = iio-hyprland`.
- [ ] Tablet-mode detection: kernel emits `SW_TABLET_MODE` events on a
  `gpio-keys`/`intel-hid` input device. Bind via udev rule + script that
  toggles the OSK and disables the keyboard/touchpad. Defer to phase-3.5.
- [ ] Palm rejection: enable `LIBINPUT_ATTR_PALM_PRESSURE_THRESHOLD` quirk
  (touch panel) and `input:touchpad:disable_while_typing = true` in
  `hyprland.conf`. Defer to phase-3.5.
- [ ] Bitwarden (self-hosted: https://hass4150.duckdns.org:7277/)
- [x] RDP client for accessing remote desktops. Primary target: Windows 10
  (existing use case). Should also cover any modern Windows (11, Server
  2019+) and **be capable of RDPing into a Linux machine running `xrdp`**
  (no current use case, just nice-to-have capability — the *client* must
  support it; the Linux server side is out of scope for this repo). Remmina
  speaks RDP/VNC/SSH/SPICE/X2Go, so all of the above are covered without
  swapping clients. Installed: `remmina` (GUI / connection manager) +
  `freerdp` (RDP protocol backend) — `postinstall.sh` §1.
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
- **General productivity**: Yes — this will be primary machine. Single-OS Linux install (Windows dual-boot was originally planned but dropped 2026-04-27 — see commit log).
- **Audio creation**: Former big hobby (Ableton, Bitwig, Traktor). Dormant but wants it available.
- **Tinkering philosophy**: Does NOT enjoy endless config tweaking. Loves having an awesome system. Doing Arch now because Claude can get it configured correctly with minimal effort.

### Q2: Desktop Experience
- **Tiling Window Manager** — keyboard-driven, no overlapping windows

### Q3: Compositor
- **Hyprland** — eye-candy king, GPU-accelerated animations, blur, rounding.
- **Dotfiles: bare Hyprland + Claude-authored configs in chezmoi.** No
  pre-built dotfile pack (HyDE, end-4/illogical-impulse, Caelestia, Omarchy
  all rejected).
  - Why not a pack: the user doesn't enjoy config tweaking, but is fine with
    Claude doing it. Once Claude becomes the editor, opinionated packs lose
    their value (saved-time argument evaporates) and add cost (you don't own
    the config; future "change X" means fighting upstream defaults).
  - Configs live at `dot_config/hypr/` in [rhombu5/dots](https://github.com/rhombu5/dots) (separate chezmoi repo), split into
    fragments (monitors, workspaces, binds, decoration, animations, plugins,
    exec, hypridle, hyprlock). Fetched + applied via `chezmoi init --apply rhombu5/dots` from postinstall §13.
  - Theme via **matugen** (Material You from wallpaper) — see §Q10-K. Every
    component (waybar, swaync, fuzzel, ghostty, helix, hypr-colors, tmux, gtk,
    qt) reads colors from a matugen-rendered template under
    `dot_config/matugen/templates/` in the dots repo.
  - Default terminal is **Ghostty** (set directly in `binds.conf` —
    `bind = SUPER, Return, exec, ghostty`). No kitty involved.
  - Keybindings (~85 of them, validated by `dot_local/bin/validate-hypr-binds`
    on every chezmoi apply — duplicate-MOD-KEY conflicts and unknown-dispatcher
    typos block the apply).

### Q4: DisplayLink / External Monitor
- **Monitor via HDMI** direct to laptop (bypasses DisplayLink video — avoids Wayland issues)
- **Keep using dock** for ethernet + USB hub (standard USB passthrough, no special drivers)
- DisplayLink video issues are display-only; hub/ethernet work natively on Linux

### Q5: NVIDIA
- **Display: Intel UHD 620 only** — `nvidia_drm` and `nvidia_modeset` are blacklisted in `chroot.sh`. The MX250 can't drive Wayland (legacy `nvidia-470xx` lacks GBM; newer `nvidia` branch dropped MX250 support). Hyprland and everything that composites runs on the iGPU.
- **Compute: MX250 available on demand** — `nvidia` and `nvidia_uvm` kernel modules are NOT blacklisted; they autoload when something opens `/dev/nvidia*` (`nvidia-smi`, a CUDA app, or Docker via nvidia-container-toolkit). Postinstall §3 installs `nvidia-470xx-dkms` + `nvidia-470xx-utils`; §1a-nvctk wires it into Docker. See R) and S) below.
- **nouveau**: blacklisted entirely (would conflict with `nvidia-470xx`).
- **External monitor still works**: the laptop's HDMI port is wired to the Intel iGPU, not the NVIDIA chip — no Optimus render-bridge needed.
- **Side benefits**: nvidia kernel module stays unloaded when nothing's using CUDA — the chip idles cold; no DKMS / signed-module churn on kernel upgrades for display.

### Q6: Editor & IDE
- **VSCode** (`visual-studio-code-bin` from AUR) — primary IDE, familiar, productive day one
- **Helix** — terminal editor for quick edits, zero-config, built-in LSP/treesitter/autocomplete
- Select-then-act model (Kakoune-inspired), more intuitive than vim for newcomers

### Q7: Terminal Multiplexer
- **tmux** — required for Claude Code worktree support (Zellij not yet supported)
- Worktree workflow: one session per worktree, fuzzy-switch via sesh/fzf
- Config in chezmoi at `dot_tmux.conf` in [rhombu5/dots](https://github.com/rhombu5/dots). No tpm — colors come from a matugen-rendered template (`dot_config/matugen/templates/tmux-colors.conf` → `~/.config/tmux/colors.conf`, sourced by `~/.tmux.conf`); session switching lives in **`sesh`** (`sesh-bin` from AUR), which IS the worktree-per-session workflow primitive (one sesh entry per worktree, fuzzy-pick).

### Q8: Shell
- **zsh** with zgenom plugin manager (same setup as fnwsl, adapted for Arch)
- **powerlevel10k** prompt
- Plugins: fast-syntax-highlighting, autosuggestions, history-substring-search, zsh-completions, fzf-zsh-plugin, fzf-tab
- OMZ: sudo, colored-man-pages, extract, command-not-found (pkgfile on Arch), docker, docker-compose, npm, pip, dotnet
- Tools: mise, zoxide, direnv, bat, fd, rg, eza, lsd, btop, jq, sd, yq, xh, tldr, gh
  - `keychain` removed — Bitwarden SSH agent holds keys (surfaces at `~/.bitwarden-ssh-agent.sock` once Bitwarden desktop runs with SSH-agent toggle on).
  - `docker`, `docker-compose`, `docker-buildx` also installed (user in `docker` group, service enabled).
- Aliases & settings carried from fnwsl (eza cascade, navigation, mc function, history opts)
- tmux config carried from fnwsl (Ctrl+a prefix, mouse, sensible splits)

### Q9: Partition Plan

**Single-disk install on Samsung 512GB SSD.** Other disks (Netac, future replacements) left untouched.

```
[EFI 1GiB FAT32] [LUKS2 → btrfs ~475GiB]
```

- **EFI System partition (p1, 1 GiB FAT32, mounted at `/boot`)** — holds limine + UKIs (`arch-linux.efi`, `arch-linux-lts.efi`, ~80 MB each). 1 GiB instead of the older 512 MiB to fit sbctl-signed copies after Secure Boot is enrolled.
- **LUKS2 partition (p2, rest of disk)** — single LUKS volume, mapper name `cryptroot`. Inside: btrfs with subvolumes:
  - `@` → `/`
  - `@home` → `/home`
  - `@snapshots` → `/.snapshots` (snapper target)
  - `@swap` → `/swap` (holds a 16 GiB NoCOW swapfile, hibernate-ready)
- **Mount options**: `noatime,compress=zstd:3,space_cache=v2,ssd` (Arch-wiki defaults). The `@swap` subvolume mounts WITHOUT `compress=` because btrfs swapfiles can't live on a compressed file.
- **Hibernate**: kernel cmdline carries `resume=/dev/mapper/cryptroot resume_offset=<N>`, where `<N>` is the swapfile's physical extent offset (captured by `install.sh` §8.5 via `btrfs inspect-internal map-swapfile -r`).
- **Migration to a future SSD** is one line: `dd` the LUKS partition byte-for-byte to the new drive, then `btrfs filesystem resize max /` if the destination is bigger. No second-disk dependencies, no re-keying.
- See §Q11 for the full encryption design (LUKS2 + signed-PCR-11 TPM seal + stage-2 PCR 7 binding).

### Q10: Other Needs

#### A) Bootloader: limine
- Single config file (`/boot/limine.conf`), modern actively-developed.
- Linux entries chainload UKIs via `protocol: efi_chainload` (built by mkinitcpio + ukify, signed PCR 11 predictions in `.pcrsig` PE section). Required for the BitLocker-parity LUKS seal — see `docs/tpm-luks-bitlocker-parity.md`.
- First-class snapper-snapshot rollback in the boot menu via the AUR
  `limine-snapper-sync` package (installed by postinstall §3) — pick yesterday's
  snapshot from the menu when a `pacman -Syu` breaks userspace, no chroot
  recovery dance.
- UEFI binary deployed to the ESP fallback path (`/boot/EFI/BOOT/BOOTX64.EFI`)
  so a NVRAM reset (BIOS update, CMOS clear) doesn't kill the boot path —
  firmware always falls back to that path.
- Pacman post-upgrade hook (`/etc/pacman.d/hooks/95-limine-redeploy.hook`)
  re-copies the binary on every limine package update, so the deployed copy
  never goes stale. SB-aware: re-signs via `sbctl` if Secure Boot is enrolled.
- Recovery story: keep the Arch live USB around. limine doesn't need an
  on-disk recovery slot — boot the USB from F12 if the main install is hosed.
- **Switched from systemd-boot 2026-04-22**: snapshot-rollback wasn't
  available without a chroot dance, and `limine-snapper-sync` is the cleanest
  way in. systemd-boot is the boring-but-fine fallback if limine ever proves
  problematic.

#### B) AUR helper: yay
- Less strict about PKGBUILD review prompts, better fit for user who won't read them

#### C) Terminal emulator: Ghostty
- GPU-accelerated, great defaults, Kitty graphics protocol support.
- Pairs with tmux for splits/sessions; `binds.conf` binds `Super+Return` to it directly.
- Theme: `theme = matugen` in `~/.config/ghostty/config`. The matugen pipeline
  renders to `~/.config/ghostty/themes/matugen` and SIGUSR2's Ghostty on
  every wallpaper change for live-reload.

#### D) Login screen: greetd + ReGreet
- Wayland-native, themeable via plain GTK CSS (matugen drops in directly)
- ~3 MB vs SDDM's ~21 MB; smaller surface area, no Qt
- Fingerprint integration via the same PAM stack
- **Switched from SDDM 2026-04-22**: bare-Hyprland reinstall doesn't need Plasma's greeter. SDDM's Qt theme was a separate maintenance surface; ReGreet aligns with the matugen pipeline used everywhere else.

#### E) Notifications: swaync (SwayNotificationCenter)
- Wayland-native popup daemon plus a pull-out panel for notification history + DND toggle.
- Themed via GTK CSS — drops straight into the matugen pipeline.
- **Switched from mako 2026-04-22**: the prior pick optimized for minimalism (end-4's wizard only accepted dunst/mako, then carried forward on the HyDE swap). The reinstall design favors visible state + GUI affordances; swaync's panel is the lowest-cost step in that direction. mako remains the minimal-surface alternative if the panel ever feels like overhead.

#### F) App launcher: fuzzel
- Wayland-native, lightweight, fuzzy matching
- Also used as the picker for clipboard history (cliphist)
- **Upgrade path**: rofi-wayland if you want scripting, custom modes (calculator, emoji, SSH picker, window switcher)

#### G) Screenshots: hyprshot + satty
- hyprshot: Hyprland-native region/window/screen capture (same role grimblast plays on sway — in `extra` repo, no AUR build)
- satty: annotate (arrows, boxes, blur, text) after capture

#### H) Clipboard: wl-clipboard + cliphist
- Clipboard history (text + images), fuzzel as picker via keybind

#### I) Audio: PipeWire + WirePlumber
- Handles desktop audio, Bluetooth, and JACK (pro audio) compatibility
- Bitwig-ready if audio production hobby returns

#### J) Fonts: JetBrains Mono Nerd Font (default)
- Installed via postinstall §1: `ttf-jetbrains-mono-nerd` + `ttf-firacode-nerd` (Nerd Font variants), plus `noto-fonts` + `noto-fonts-emoji` for Unicode/emoji coverage.
- Configure JetBrains Mono as default in Ghostty, Helix, VSCode, Waybar, greetd-regreet, hyprlock.
- Add `ttf-cascadia-code-nerd`, `ttf-hack-nerd`, `ttf-meslo-nerd`, etc. via pacman if you want to swap.

#### K) Theme: matugen (Material You, wallpaper-derived)
- Palette generated dynamically from the current wallpaper.
- Templates render: Hyprland colors, waybar CSS, swaync CSS, ReGreet CSS, Ghostty, GTK (3 + 4 CSS), Qt (qt5ct/qt6ct), fuzzel, helix, hyprlock, yazi, zathura, tmux. See `dot_config/matugen/config.toml` in [rhombu5/dots](https://github.com/rhombu5/dots) for the full list.
- Master dark/light switch via `~/.local/bin/theme-toggle` — three entry points: Super+Shift+T hotkey, waybar sun/moon icon, fuzzel control-panel entry.
- **Switched from Catppuccin Mocha 2026-04-22**: Catppuccin was a default-of-the-day pick, never load-bearing. The user wanted dynamic accent from wallpaper + an easy dark/light master switch — matugen delivers both natively. The script-implementation pass was completed 2026-04-23: scripts, dotfiles, and verify checks no longer reference Catppuccin anywhere (legacy mentions in `runbook/GLOSSARY.md` and this document are intentional history).

#### L) Dotfiles: chezmoi
- Template-based, git-backed, Bitwarden integration for secrets (self-hosted Vaultwarden at `https://hass4150.duckdns.org:7277`).
- Source repo: [rhombu5/dots](https://github.com/rhombu5/dots) — public, cross-platform (Arch + WSL + Windows hosts differentiated via `.chezmoi.os` / `.chezmoiignore`).
- Bootstrap on a fresh machine: `chezmoi init --apply rhombu5/dots`.

#### M) System monitor: btop
- Already familiar from fnwsl

#### N) Browser: Edge (default) + Firefox
- Edge (`microsoft-edge-stable-bin` AUR) as default for sync continuity with Windows
- Firefox **not installed by default** — Edge covers the daily driver need; add with `sudo pacman -S firefox` when a Wayland-native backup is useful.

#### O) RDP client: Remmina + FreeRDP
- Full-featured GUI, connection manager, Wayland-native (`remmina`).
- FreeRDP backend (`freerdp`) provides the actual RDP protocol implementation
  — Remmina is the GUI shell on top.
- For accessing Windows 10 machine. Installed by `postinstall.sh` §1.

#### Q-file) File manager: yazi (primary) + nautilus (GUI fallback)
- **yazi** — terminal file manager, keyboard-first, vim-style keybinds, Rust-native, rich previews (images/PDF/code). Fits the terminal-heavy workflow (tmux/helix/ghostty). Daily driver.
- **nautilus** — GTK4 GUI file manager, Wayland-tested, inherits the matugen-rendered GTK theme automatically, minimal-friction for drag/drop, network mounts (smb://, sftp://). The deliberate polar opposite of yazi for "sit back, click around" mode.
- **Not Dolphin/Nemo/Thunar/PCManFM**: Dolphin adds a Qt/KDE theming tax while being philosophically the same dense-power-user tool as yazi; Thunar's Wayland support is X11-first; PCManFM is a low-RAM pick we don't need; Nemo's maintenance velocity lags Nautilus.

#### Desktop component picks (locked 2026-04-22, validation pass)

Rapid-fire small picks. All recommended by the validation research agent
and accepted on the "clean-slate, no bias" principle. See
`docs/desktop-requirements.md` for full component list.

- **OSD popups**: SwayOSD — GTK4, in extra; volume/brightness/caps-lock; CSS themed via matugen.
- **Network UI**: nm-connection-editor for full config + a custom waybar nmcli module for at-a-glance state. Skip nm-applet (the tray icon is redundant).
- **Bluetooth UI**: overskride (AUR) — GTK4/libadwaita, Wayland-native. Blueman is the GTK3 fallback.
- **Audio mixer GUI**: pavucontrol (extra). Goes through PipeWire's pulse compat shim (already pulled in by `pipewire-pulse`). The PipeWire-native `pwvucontrol` was the original pick, but as of 2026-04 its AUR build is broken — upstream is blocked on the unmaintained `wireplumber-rs` crate (issue #10), and the AUR's only path forward is a `libwireplumber-4.0-compat` shim that itself breaks every pipewire bump. Switched to pavucontrol to get out of the AUR-babysitting business; revisit if pwvucontrol ever lands in extra.
- **Color picker**: hyprpicker — Wayland-native, magnifier loupe, autocopy.
- **Power menu**: wleave (AUR) — GTK4 fork of wlogout, themes via matugen.
- **Image viewer**: imv — fast, reliable, modal keys. (Loupe rejected: libadwaita ignores GTK theming, won't follow matugen.)
- **PDF viewer**: zathura + zathura-pdf-poppler — Xwayland but the modal-keys UX wins. Sioyek is the Wayland-native alternative if Xwayland ever bites.
- **GTK theme manager**: nwg-look (GTK3/libadwaita settings; matugen overwrites the resulting CSS).
- **Qt theme manager**: qt6ct + qt5ct, with `QT_QPA_PLATFORMTHEME=qt6ct`. Matugen ships a Qt template.
- **Cursor**: Bibata-Modern-Classic in **Xcursor** format (`bibata-cursor-theme` from AUR, ~44 MB resident). The hyprcursor-format variant (~6.6 MB) has no clean AUR package as of 2026-04 — manual install from LOSEARDES77/Bibata-Cursor-hyprcursor github if the size matters; Hyprland falls back to Xcursor automatically. Phinger is the alternative if Bibata feels too neutral.
- **Icon theme**: Papirus-Dark — best app coverage. Tela is the runner-up if a more uniform "modern" feel matters more than coverage.
- **Resource monitor (GUI)**: mission-center (now in `extra` as of early 2026 — was AUR previously) — one piece the per-tool launcher genuinely misses; complements btop in the terminal.

#### P) Installer password handoff: pre-hashed via mode-600 file
- `phase-2-arch-install/install.sh` reads the root + `tom` passwords once at the top of the run, hashes them immediately with `openssl passwd -6` (SHA-512), and hands the hashes to `chroot.sh` via a mode-600 file under `/mnt/tmp/`. The plaintext values never touch disk.
- **Caveat**: while the installer is still running, the `openssl passwd` invocation does briefly appear in `ps` (as the process argument) on the live ISO. The live environment is single-user and ephemeral, so this is acceptable — but don't run the installer on a shared/networked machine. After chroot finishes, the hash file is deleted and only the hashed values remain in `/etc/shadow`.

#### R) Windows VM: dockur/windows on Docker + WinApps
- **Why a VM**: occasional Windows-only apps (primarily Visual Studio Enterprise) surfaced as Coherence-style native Hyprland windows via WinApps + FreeRDP — they feel like Linux apps in Fuzzel + the taskbar.
- **Orchestrator: dockur/windows on Docker (chosen 2026-05-02)**. Reasons:
  - Declarative `compose.yaml` reproduces the entire VM on reinstall — no virt-manager point-and-click recipe to remember.
  - Unattended Windows install (~15-30 min hands-off, ISO downloaded from Microsoft, OEM `install.bat` winget-installs VS 2022 Enterprise IDE).
  - Docker is already installed for cloud-storage sync, so the VM is a free rider rather than a new subsystem (libvirt would have added qemu-full + virt-manager + libvirt + edk2-ovmf + swtpm + dnsmasq + a daemon).
- **Why not libvirt+QEMU**: it was the original pick when 3DF Zephyr photogrammetry was on the table (would need PCI passthrough into a Windows guest). Photogrammetry was dropped 2026-05-02; without it, libvirt's strengths (PCI passthrough, fine-grained QEMU control) don't pay off for a single VS-in-Coherence use case.
- **Tradeoff accepted**: dockur/windows is a third-party orchestration project (one GitHub repo). If it goes dormant or breaks against a future Windows ISO, migration to libvirt is straightforward — the compose file translates directly into a libvirt domain XML.
- **Implementation**:
  - Compose at `/etc/dockur-windows/compose.yaml` (Win11, RAM 8G, 4 vCPU, 128G disk; RDP bound to 127.0.0.1:3389 only — not LAN-reachable; web UI for direct VM display at `http://127.0.0.1:8006/`).
  - OEM scripts at `/etc/dockur-windows/oem/`, run by dockur during Windows OOBE finalization. All adapted from the pre-2026-04-27 autounattend.xml (which targeted a since-dropped bare-metal Windows install — the Schneegans-generated XML lives in git history); bare-metal-specific bits (Samsung-by-size disk detection, BitLocker handoff, diskpart partitioning, Wi-Fi profile injection, `$WinPEDriver$`) dropped, OS-config tweaks survive:
    - `install.bat` — winget-installs VS 2022 Enterprise IDE only; workloads picked via VS Installer GUI on first launch. Enterprise activation: MSDN/VS subscription sign-in on first launch.
    - `setup.cmd` — HKLM tweaks (power, RDP enabled, long paths, fsutil disableLastAccess, privacy/consumer-features off, Edge OOBE skipped, ExecutionPolicy RemoteSigned, /maxpwage:UNLIMITED, icacls C:\\ /remove:g "*S-1-5-11"), HKU\\.DEFAULT/StickyKeys, Default-user-hive defaults (so the Docker user inherits show-extensions, hide-TaskView, taskbar-align-left, NumLock-on, no-mouse-accel, no-ContentDeliveryManager-promos), RunOnce registration for UserOnce.ps1.
    - `debloat.ps1` — removes 26 consumer AppX (Bing/Maps/Xbox/Solitaire/etc.), the `Print.Fax.Scan` capability (just the Fax+Scan accessory app — print spooler, Print to PDF, IPP-to-CUPS still work), and Recall (the Win11 24H2 screenshot-everything feature).
    - `UserOnce.ps1` — fires once at first logon: Explorer→ThisPC, hide taskbar searchbox, remove Edge desktop shortcut, restart explorer.exe.
  - **Defender fully disabled** (Group Policy regs + service Start=4 + scheduled-task Disable + SmartScreen off + `Set-MpPreference`). Threat model = local-only dev VM behind LUKS-encrypted host, not an internet-facing server. Tamper Protection caveat: enabled by Win11 24H2 shortly after first user interaction; SetupComplete runs before that, so the writes stick. If a future ISO enables TP earlier, manual workaround = Settings > Privacy > Windows Security > Tamper Protection > Off, then re-run setup.cmd.
  - WinApps cloned to `/opt/winapps`, setup script symlinked onto PATH as `winapps-setup`, `WAFLAVOR=docker` written to `~/.config/winapps/winapps.conf`.
  - Postinstall §15-windows blocks on `docker compose up -d` + `health=healthy` (~15-30 min on first run, fast on re-runs). Skippable via `--skip-windows-install`.

#### S) NVIDIA Container Toolkit: GPU containers via Docker
- **Why**: `nvidia-container-toolkit` (extra) wires the host nvidia-470xx driver into Docker so Linux containers can `docker run --gpus all ...` against the MX250 — useful for ML/CUDA experiments without polluting the host with version-pinned Python/CUDA stacks.
- **Configured by**: `nvidia-ctk runtime configure --runtime=docker` in postinstall §1a-nvctk. Writes `/etc/docker/daemon.json` registering `"nvidia"` as a Docker runtime; daemon restart only fires when the file's hash actually changed (idempotent).
- **Pascal/CUDA caveat**: the MX250 is Pascal (compute capability 6.1). CUDA-12 container images compile out Pascal kernels and run CPU-only — pick CUDA ≤11.x base images (e.g. `nvidia/cuda:11.8.0-*`, `pytorch/pytorch:1.13.x-cuda11.x`) for actual GPU acceleration.
- **Doesn't help the Windows VM**: GPU containers are Linux-side. Giving the dockur Windows guest real NVIDIA access would need PCI passthrough (host GPU dedicated to guest), which Optimus laptops resist; deliberately not in scope.

### Q13: bare-Hyprland config layout

- **Source of truth**: `dot_config/hypr/` in [rhombu5/dots](https://github.com/rhombu5/dots) (separate repo). Applied to
  `~/.config/hypr/` by `chezmoi init --apply rhombu5/dots` (postinstall §13).
- **Entry point**: `hyprland.conf` — sources nine fragments via `source =`
  directives (one per concern):
  - `colors.conf` — matugen-rendered palette ($primary, $on_surface, etc.)
  - `monitors.conf` — eDP-1 + DP-1 placement, scaling, transforms
  - `workspaces.conf` — monitor-bound workspace assignments (1-5 → DP-1, 6-9 → eDP-1, 10 = scratch)
  - `input.conf` — keyboard layout, touchpad behavior, libinput tuning
  - `decoration.conf` — rounding, blur, shadows
  - `animations.conf` — bezier curves + per-event animation timings
  - `plugins.conf` — Hyprspace (loaded via hyprpm; hyprgrass remains opt-in, see the Touch-gestures requirement at top of file)
  - `exec.conf` — `exec-once` daemons (waybar, swaync, hypridle, awww-daemon, iio-hyprland, …)
  - `binds.conf` — ~85 keybindings; validated on every chezmoi apply
- **Helper binaries** at `~/.local/bin/` (chezmoi-managed):
  - `validate-hypr-binds` — parses every `bind = ...` line, flags
    duplicate-(MOD,KEY) pairs and unknown dispatchers; exits non-zero on
    any conflict (chezmoi pre-apply hook blocks the apply).
  - `wallpaper-rotate` — picks next wallpaper, runs `awww img`, runs
    `matugen image` so every component re-themes.
  - `theme-toggle` — flips dark/light by re-running matugen with the
    opposite mode.
  - `control-panel` — fuzzel-driven menu of system actions.
- **Reload after edit**: `chezmoi apply` re-renders all dotfiles + the
  matugen post_hooks fire (waybar SIGUSR2, swaync-client --reload-css,
  ghostty SIGUSR2, hyprctl reload, etc.). Manual `hyprctl reload` for
  one-off tweaks works too.

### Q12: bare-Hyprland runtime dependencies

The chezmoi-applied configs reference these packages; postinstall §1 (pacman)
and §3 (yay) install them explicitly so the verify block can prove them
present.

**Pacman (`extra`):**
- **Compositor + lock + idle**: `hyprland`, `hyprlock`, `hypridle`, `hyprpolkitagent`, `hyprpicker`. hyprpolkitagent must be `systemctl --user enable --now`'d (preset is enabled but doesn't auto-activate on fresh install) — without it Bitwarden's keyring unlock prompt stays grayed out.
- **Bar + notifications + launcher + OSD**: `waybar`, `swaync`, `fuzzel`, `swayosd`.
- **Screenshots + clipboard**: `hyprshot`, `satty`, `wl-clipboard`, `cliphist`.
- **XDG portals**: `xdg-desktop-portal-hyprland` (phase-2 pacstrap), `xdg-desktop-portal-gtk` (phase-3 postinstall).
- **Network + audio UIs**: `network-manager-applet` (provides nm-connection-editor), `pavucontrol`.
- **Theme tooling**: `nwg-look` (GTK3/4 settings), `qt5ct` + `qt6ct` (Qt theme), `papirus-icon-theme`.
- **Apps**: `imv` (image viewer), `zathura` + `zathura-pdf-poppler`.
- **Audio**: `pipewire`, `pipewire-pulse`, `pipewire-jack`, `wireplumber`.

**AUR (yay):**
- **Wallpaper + theme**: `awww-bin`, `matugen-bin`.
- **Bluetooth + power UIs**: `overskride`, `wleave`.
- **Cursor**: `bibata-cursor-theme` (Xcursor; hyprcursor variant unpackaged — see §Desktop component picks).
- **AUR-only utils**: `pacseek`, `wvkbd` (on-screen keyboard for tablet mode).

**2-in-1 hardware (mixed pacman + AUR + hyprpm):**
- `iio-sensor-proxy` (pacman) — accelerometer service.
- `iio-hyprland-git` (AUR) — bridges accelerometer → `hyprctl monitor` transforms; spawned via `exec-once`.
- `libwacom` (pacman) — tablet metadata.
- `wvkbd` (AUR) — `wvkbd-mobintl` on-screen keyboard.
- `hyprgrass` (hyprpm plugin) — **opt-in, not installed by default.** Native Hyprland touchscreen behavior was deemed sufficient on 2026-05-02. Adds long-press, edge swipes, OSK-toggle gestures beyond Hyprland's built-in 3-finger workspace swipe. Install on demand with `hyprpm add https://github.com/horriblename/hyprgrass`.

**Validator hook**: `.chezmoiscripts/run_before_validate-binds.sh.tmpl` in [rhombu5/dots](https://github.com/rhombu5/dots) runs `validate-hypr-binds` before every `chezmoi apply`. A keybind conflict or unknown dispatcher fails the validator → fails the apply, so a broken config can never reach `~/.config/hypr/`. The same validator runs in the dots repo's CI workflow.

### Q11: Full-Disk Encryption (LUKS2 + TPM2 autounlock)

"Stolen laptop" becomes "brick" — data is readable only with the LUKS recovery key or an intact boot chain that satisfies the **signed PCR 11 policy + stage-2 PCR 7 binding**. See `docs/tpm-luks-bitlocker-parity.md` for the full design.

**Scope of encryption:**
- **Samsung `ArchRoot`** (btrfs + @ / @home / @snapshots / @swap subvolumes) — single LUKS2 container named `cryptroot`. Passphrase slot + TPM2 slot (signed PCR 11 policy + stage-2 PCR 7 binding).
- The 16 GiB hibernate swapfile lives at `/swap/swapfile` inside the (already-unlocked) cryptroot — no separate cryptswap volume. Encrypted at rest because the underlying btrfs is.
- **Samsung EFI** — unencrypted (UEFI spec requires the ESP to be FAT32 and unencrypted). UKIs on it carry signed PCR 11 predictions in their `.pcrsig` PE section; the TPM seal verifies that signature, not the bytes themselves.

**Key management — BitLocker model:**
- **Auto-generated** at install time (Phase 2d `install.sh` `gen_and_show_luks_passphrase`): 48 numeric digits from `/dev/urandom` (~159 bits of entropy). Same shape + UX as the BitLocker recovery key.
- Displayed once in a red-banner panel; install.sh blocks until the user types `I HAVE THE KEY` verbatim. User photographs the screen, transcribes to Bitwarden as **"Metis LUKS recovery"** later.
- Held in an in-memory bash variable for the rest of install.sh — used for `luksFormat` of cryptroot — then `unset` at end of install. Never touches disk.
- TPM2 enrollment is two-stage: install-time `install.sh` §5b binds cryptroot to the **signed PCR 11 policy** (a keypair generated at install lives at `/etc/systemd/tpm2-pcr-{private,public}.pem` on the LUKS root — the private key is encrypted at rest by the very volume it gates). Phase 3 postinstall §7.5 measures the installed system's PCR 7 (stable only post-install) and re-enrolls the cryptroot slot with `--tpm2-pcrs=7` *added* to the existing policy, which restores BitLocker-equivalent semantics around Secure Boot toggling. After §7.5 runs, cryptroot unseals silently at boot unless the signed policy is invalidated (post-`leave-initrd`) or PCR 7 changes (SB toggle, firmware update, TPM clear).
- The recovery key is **the only fallback.** Lose the photo before transcribing to Bitwarden → encrypted disks are unrecoverable. No backdoor.
- If you'd prefer a memorable passphrase to the random digits, swap key-slot 0 *after* unlocking once: `sudo cryptsetup luksChangeKey /dev/disk/by-partlabel/ArchRoot`. Stash the new passphrase in Bitwarden BEFORE rebooting.

**PCR policy — signed PCR 11 + stage-2 PCR 7:**
- **PCR 11** is the systemd boot-phase register. The UKI measures itself into PCR 11 at firmware exit, then `systemd-pcrphase` extends well-known constants at named transitions (`enter-initrd` → `leave-initrd` → `ready`). ukify (called by mkinitcpio at UKI build time) pre-computes and signs the PCR 11 prediction for the `enter-initrd` phase using the keypair at `/etc/systemd/tpm2-pcr-private.pem`. The signed prediction lands in a `.pcrsig` PE section of the UKI. The TPM unseals when the running thing produces a signature against the registered public key matching the current PCR 11 — i.e. when an authentic UKI is mid-`enter-initrd`. After `leave-initrd` extends the next constant, no signature matches → unseal impossible (BitLocker temporal scope).
- **PCR 7** = Secure Boot policy (on/off + key hashes). Layered on by postinstall §7.5 because install-time can't predict the installed system's PCR 7 reliably. Restores the "boot chain tampered" signal on SB toggling.
- Why not PCR 0+7 alone (the older approach): PCR drift between live ISO and installed first boot caused spurious passphrase prompts, and there was no signature anchor to re-bind to across firmware updates.
- Full design rationale + threat model + recovery procedures: `docs/tpm-luks-bitlocker-parity.md`.

**crypttab layout:**
- `/etc/crypttab.initramfs` — baked into initramfs by mkinitcpio's `sd-encrypt` hook. Contains a single cryptroot entry. Hibernate uses a swapfile inside the (post-unlock) btrfs root, not a separate LUKS volume, so no second crypttab line is needed.

**mkinitcpio HOOKS ordering:** `sd-encrypt` sits between `block` and `filesystems`. Without this, initramfs can't open cryptroot before trying to mount `/`.

**Kernel cmdline (in `/etc/kernel/cmdline`, baked into the UKI by ukify):**
`root=/dev/mapper/cryptroot rootflags=subvol=@ resume=/dev/mapper/cryptroot resume_offset=<N> rw quiet`. The `<N>` is the swapfile's physical extent offset on the btrfs volume, captured by `install.sh` §8.5 via `btrfs inspect-internal map-swapfile -r`. No `rd.luks.name=` needed — crypttab.initramfs is the single source of truth.

**Secure Boot readiness:**
- Secure Boot stays **off** at install time. The reinstall pre-installs `sbctl` (postinstall §1) and the `95-limine-redeploy.hook` is SB-aware — `/usr/local/sbin/limine-redeploy` calls `sbctl sign -s` after copy if SB is enrolled, no-op otherwise. Same for sbctl's own pacman hook (ships with the package), which auto-resigns kernels on every linux/linux-lts upgrade.
- Enabling SB later: BIOS → Setup Mode → from Arch run `sbctl create-keys && sbctl enroll-keys --microsoft && sbctl sign -s {/boot/EFI/BOOT/BOOTX64.EFI,/usr/share/limine/BOOTX64.EFI,/boot/EFI/Linux/arch-linux.efi,/boot/EFI/Linux/arch-linux-lts.efi}` → reboot, BIOS → User Mode (SB on) → at the LUKS prompt enter the recovery key (PCR 7 changed → TPM seal invalid) → `sudo /usr/local/sbin/tpm2-reseal-luks` → reboot, silent unlock again. Full sequence in `runbook/phase-3-handoff.md` "Upgrade Paths".

**Known limitations:**
- If the TPM is reset (firmware reset, motherboard replacement), the sealed slot is dead and the recovery key is the only way in. Hence the "transcribe to Bitwarden" step is mandatory, not optional.
