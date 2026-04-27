# Arch Linux Dual-Boot Setup — Decisions & Notes

## System
- **Laptop**: Dell Inspiron 7786 (17" 2-in-1 convertible)
- **CPU**: Intel i7-8565U (4c/8t, Whiskey Lake)
- **RAM**: 16GB DDR4-2400 (Dell spec; i7-8565U's official DDR4 ceiling is 2400 anyway)
- **GPU**: NVIDIA GeForce MX250 (2GB) + Intel UHD 620 (Optimus)
- **Target Drive**: Samsung SSD 840 PRO 512GB (currently D: + V:)
- **WiFi**: Dell Wireless 1801 (Qualcomm Atheros) + BT 4.0
- **Display**: Integrated touch + external Vizio via USB DisplayLink dock
- **Boot**: UEFI, GPT. *Current BIOS state*: Secure Boot ON, SATA in RAID mode. *Before phase 1 runs*: flip SATA → **AHCI** (RAID hides the NVMe from every Linux installer + the Windows setup USB), disable **Secure Boot** (limine UEFI binary isn't signed out of the box; can re-enable later with `sbctl` signing — see `runbook/phase-3-handoff.md` Upgrade Paths).
- **Peripherals**: Touchscreen (capacitive only — NO active pen on the 17" 7786, only the 13"/15" 7000-series got AES digitizers), touchpad, fingerprint reader. External Wacom Intuos USB tablet supported when plugged in.
- **Battery**: NONE *currently* — the internal battery is dead / removed; user plans to replace it. Laptop is always on AC power, lives stashed under a desk. Downstream consequences:
  - Lid-close "hibernate on battery" branch in `logind.conf` is dead code today (no battery state for logind to see). Configured anyway for forward-compat — fires automatically when a battery returns, no reconfig.
  - **Hibernation is enabled** (S4) on Linux. Reverses the prior "disabled" decision; the cited dual-boot/BitLocker risk doesn't apply (Linux swap is on the Netac, Windows can't see LUKS or btrfs). Until the battery is replaced, hibernate is **user-invoked** (`Super+Shift+H`) since AC removal is an instant hard-cut. Swap sized 16 GB to match RAM. Persistent LUKS swap, TPM2-keyfile-sealed (mirrors cryptvar). See `docs/desktop-requirements.md` §Hibernate for the full plan.
  - Abrupt shutdowns (power cable kick) are the norm. btrfs COW handles this well — no `fsync` required for metadata integrity. Good argument for btrfs over ext4 on root.
  - The greeter is the primary moment of the day where the user authenticates (no suspend/resume cycles → no lock screens) — fingerprint at the greeter is therefore load-bearing, not cosmetic.

## Requirements
- [x] Fingerprint scanner support (fprintd + libfprint). **Device: Goodix `27c6:538c`** — supported only via the AUR `libfprint-goodix-53xc` package (older Dell OEM blob, pre-v0.0.11) riding on `libfprint-tod-git`. Current upstream AUR `libfprint-2-tod1-goodix` / `-v2` ship a **550A-only** blob that does NOT cover 538C. `libfprint-tod-git` must be built with `!lto` in PKGBUILD options — LTO strips ABI symbol versioning and breaks the link. `postinstall.sh` pre-flights this automatically. Enrollment on a bare TTY needs `sudo fprintd-enroll -f <finger> tom` (polkit denies unprivileged enroll without a graphical session).
- [x] Lid close: no sleep/shutdown on AC power (logind.conf) — wired by phase-2 `chroot.sh` via `/etc/systemd/logind.conf.d/10-lid.conf` (`HandleLidSwitchExternalPower=ignore`).
- [ ] **External** Wacom Intuos USB tablet support (only when plugged in — the 17" 7786 has NO built-in active digitizer, capacitive touch only). `libwacom` + the in-tree kernel `wacom` driver are both installed by `postinstall.sh`. Pressure/tilt work under Wayland via libinput; per-tablet pressure curves go in `dotfiles/dot_config/hypr/input.conf` `device:` blocks.
- [x] **Touchscreen** — ELAN i2c-hid (`ELAN2097:00 04F3:2666`), bound by the in-kernel `i2c-hid-acpi` → `hid-multitouch` chain. NOT Goodix — the `27c6:*` Goodix on this machine is the **fingerprint** reader. NOT IPTS either (Surface-only). Whiskey-Lake quirk: live ISO often doesn't autoload `i2c-hid-acpi` until userspace, so the touchscreen is invisible from the live ISO and visible from the installed system.
- [ ] Touch gestures (touchpad + tablet mode):
  - Two-finger drag → scroll (libinput default, no config needed)
  - Three-finger tap → middle click (libinput default)
  - Three-finger left/right swipe → workspace switch (`gestures { workspace_swipe = true; workspace_swipe_fingers = 3 }` in `hyprland.conf` — wired by postinstall §13a)
  - Single-finger long-press, edge swipes, OSK toggle → **hyprgrass** plugin (installed via `hyprpm` by postinstall)
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
- **General productivity**: Yes — this will be primary machine. Windows dual-boot is a safety net; goal is eventually Linux-only.
- **Audio creation**: Former big hobby (Ableton, Bitwig, Traktor). Dormant but wants it available.
- **Tinkering philosophy**: Does NOT enjoy endless config tweaking. Loves having an awesome system. Doing Arch now because Claude can get it configured correctly with minimal effort.

### Q2: Desktop Experience
- **Tiling Window Manager** — keyboard-driven, no overlapping windows

### Q3: Compositor
- **Hyprland** — eye-candy king, GPU-accelerated animations, blur, rounding.
- **Dotfiles: bare Hyprland + Claude-authored configs in chezmoi.** No
  pre-built dotfile pack (HyDE, end-4/illogical-impulse, Caelestia, Omarchy
  all rejected — see `docs/reinstall-planning.md` for the comparison).
  - Why not a pack: the user doesn't enjoy config tweaking, but is fine with
    Claude doing it. Once Claude becomes the editor, opinionated packs lose
    their value (saved-time argument evaporates) and add cost (you don't own
    the config; future "change X" means fighting upstream defaults).
  - Configs live at `dotfiles/dot_config/hypr/` in this repo, split into
    fragments (monitors, workspaces, binds, decoration, animations, plugins,
    exec, hypridle, hyprlock). Applied via `chezmoi apply` from postinstall §13.
  - Theme via **matugen** (Material You from wallpaper) — see §Q10-K. Every
    component (waybar, swaync, fuzzel, ghostty, helix, hypr-colors, tmux, gtk,
    qt) reads colors from a matugen-rendered template under
    `dotfiles/dot_config/matugen/templates/`.
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
- **Intel UHD 620 only** — blacklist NVIDIA + nouveau modules, effectively disabling the MX250.
- **Why not use the MX250?** It only works with the legacy `nvidia-470xx` driver branch. That branch never gained GBM support, so no Wayland compositor (Hyprland included) can run on it; the newer `nvidia` branch dropped MX250 support entirely. Choosing Wayland ≡ choosing Intel-only.
- **External monitor still works**: the laptop's HDMI port is wired to the Intel iGPU, not the NVIDIA chip — no Optimus render-bridge needed.
- **Side benefits**: longer runtime (the MX250 idles at ~0.5 W but its driver keeps the chip awake), no DKMS / signed-module churn on kernel upgrades.

### Q6: Editor & IDE
- **VSCode** (`visual-studio-code-bin` from AUR) — primary IDE, familiar, productive day one
- **Helix** — terminal editor for quick edits, zero-config, built-in LSP/treesitter/autocomplete
- Select-then-act model (Kakoune-inspired), more intuitive than vim for newcomers

### Q7: Terminal Multiplexer
- **tmux** — required for Claude Code worktree support (Zellij not yet supported)
- Worktree workflow: one session per worktree, fuzzy-switch via sesh/fzf
- Config in chezmoi at `dotfiles/dot_tmux.conf`. No tpm — colors come from a matugen-rendered template (`dotfiles/dot_config/matugen/templates/tmux-colors.conf` → `~/.config/tmux/colors.conf`, sourced by `~/.tmux.conf`); session switching lives in **`sesh`** (`sesh-bin` from AUR), which IS the worktree-per-session workflow primitive (one sesh entry per worktree, fuzzy-pick).

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

**Samsung 512GB SSD (main):**
```
[EFI 1GiB FAT32] [MSR 16MB] [Windows 160GB NTFS] [Linux ~316GB btrfs]
```

**Netac 128GB SSD (secondary — non-speed-critical):**
```
[Arch recovery ISO ~1.5GB unencrypted] [swap 16GB LUKS2] [/var/log + /var/cache ~110GB LUKS2 ext4]
```
- Recovery partition: stock Arch live ISO `dd`'d to partition, bootable from the F12 firmware menu (Dell shows the Netac's EFI boot entry directly). Replaces need for live USB after initial install.
- Swap is **persistent LUKS2** (not random-key dm-crypt) — required for hibernate. TPM2-enrolled in postinstall §7.5 so it auto-unseals at boot.
- /var/log + /var/cache also LUKS2-wrapped (cryptvar mapper); keyfile-unlocked from the TPM-unsealed cryptroot. See §Q11 for the full encryption design.

- **btrfs subvolumes**: @, @home, @snapshots
- **Mount options**: `noatime,compress=zstd:3,space_cache=v2,ssd` (level-3 zstd is the Arch-wiki default — good ratio, negligible CPU cost; `space_cache=v2` + `ssd` are the modern defaults for SATA SSDs).
- /var/log and /var/cache on Netac — keeps them off btrfs snapshots and off the main SSD's endurance budget.
- Windows partition mounted read-only at `/mnt/windows` for media access (read-only avoids the NTFS-fuse write-corruption risk).
- **Resize strategy (Linux → Windows)**: `phase-6-grow-windows.sh` adds a new btrfs device at the tail of the Samsung, runs `btrfs device add`+`remove` to migrate data, then deletes the original partition — free space ends up **directly adjacent to Windows** so Disk Management's Extend Volume works. Swap lives on the *Netac*, so nothing sits between Windows and the new free space.
- Disable Windows Fast Startup + hibernation for clean dual-boot (baked into `autounattend.xml` via `Specialize.ps1`).

### Q10: Other Needs

#### A) Bootloader: limine
- Single config file (`/boot/limine.conf`), modern actively-developed.
- Linux entries chainload UKIs via `protocol: efi_chainload` (built by mkinitcpio + ukify, signed PCR 11 predictions in `.pcrsig` PE section). Required for the BitLocker-parity LUKS seal — see `docs/tpm-luks-bitlocker-parity.md`.
- First-class snapper-snapshot rollback in the boot menu via the AUR
  `limine-snapper-sync` package (installed by postinstall §3) — pick yesterday's
  snapshot from the menu when a `pacman -Syu` breaks userspace, no chroot
  recovery dance.
- Bootable-ISO-from-disk via efi_chainload: the Netac's recovery-ISO partition
  shows up in the F12 firmware menu directly (limine doesn't have to know
  about it). `phase-6-grow-windows.sh` and any other "needs an unmounted root"
  rescue can boot from there without a USB stick.
- UEFI binary deployed to the ESP fallback path (`/boot/EFI/BOOT/BOOTX64.EFI`)
  so Windows NVRAM resets don't kill the entry — firmware always finds it.
- Pacman post-upgrade hook (`/etc/pacman.d/hooks/95-limine-redeploy.hook`)
  re-copies the binary on every limine package update, so the deployed copy
  never goes stale.
- Windows Boot Manager is registered explicitly in `/boot/limine.conf` as an
  `efi_chainload` stanza pointing at `/EFI/Microsoft/Boot/bootmgfw.efi`.
- **Switched from systemd-boot 2026-04-22**: snapshot-rollback wasn't
  available without a chroot dance, and `limine-snapper-sync` is the cleanest
  way in. systemd-boot is the boring-but-fine fallback if limine ever proves
  problematic — see `docs/reinstall-planning.md` for the swap rationale.

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
- Templates render: Hyprland colors, waybar CSS, swaync CSS, ReGreet CSS, Ghostty, GTK (3 + 4 CSS), Qt (qt5ct/qt6ct), fuzzel, helix, hyprlock, yazi, zathura, tmux. See `dotfiles/dot_config/matugen/config.toml` for the full list.
- Master dark/light switch via `~/.local/bin/theme-toggle` — three entry points: Super+Shift+T hotkey, waybar sun/moon icon, fuzzel control-panel entry.
- **Switched from Catppuccin Mocha 2026-04-22**: Catppuccin was a default-of-the-day pick, never load-bearing. The user wanted dynamic accent from wallpaper + an easy dark/light master switch — matugen delivers both natively. The script-implementation pass was completed 2026-04-23: scripts, dotfiles, and verify checks no longer reference Catppuccin anywhere (legacy mentions in `runbook/GLOSSARY.md`, this document, and `docs/reinstall-planning.md` are intentional history).

#### L) Dotfiles: chezmoi
- Template-based, git-backed, Bitwarden integration for secrets
- Can unify fnwsl + Arch configs in one repo with machine-specific templates

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

### Q13: bare-Hyprland config layout

- **Source of truth**: `dotfiles/dot_config/hypr/` in this repo. Applied to
  `~/.config/hypr/` by `chezmoi apply` (postinstall §13).
- **Entry point**: `hyprland.conf` — sources nine fragments via `source =`
  directives (one per concern):
  - `colors.conf` — matugen-rendered palette ($primary, $on_surface, etc.)
  - `monitors.conf` — eDP-1 + DP-1 placement, scaling, transforms
  - `workspaces.conf` — monitor-bound workspace assignments (1-5 → DP-1, 6-9 → eDP-1, 10 = scratch)
  - `input.conf` — keyboard layout, touchpad behavior, libinput tuning
  - `decoration.conf` — rounding, blur, shadows
  - `animations.conf` — bezier curves + per-event animation timings
  - `plugins.conf` — hyprexpo + hyprgrass (loaded via hyprpm)
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
- `hyprgrass` (hyprpm plugin) — long-press, edge swipes, OSK-toggle gestures beyond Hyprland's built-in 3-finger workspace swipe.

**Validator hook**: `dotfiles/.chezmoiscripts/run_before_validate-binds.sh.tmpl` runs `validate-hypr-binds` before every `chezmoi apply`. A keybind conflict or unknown dispatcher fails the validator → fails the apply, so a broken config can never reach `~/.config/hypr/`.

### Q11: Full-Disk Encryption (LUKS2 + TPM2 autounlock)

Parity with Windows BitLocker on the same machine. "Stolen laptop" becomes "brick" — data is readable only with the passphrase or an intact boot chain sealed against the **signed PCR 11 policy + stage-2 PCR 7 binding**. See `docs/tpm-luks-bitlocker-parity.md` for the full design.

**Scope of encryption:**
- **Samsung `ArchRoot`** (btrfs + @ / @home / @snapshots subvolumes) — LUKS2 container named `cryptroot`. Passphrase slot + TPM2 slot (signed PCR 11 policy + stage-2 PCR 7 binding).
- **Netac `ArchVar`** (ext4 — /var/log + /var/cache) — LUKS2 container named `cryptvar`. Passphrase slot + keyfile slot reading from `/etc/cryptsetup-keys.d/cryptvar.key` on the (TPM-unlocked) cryptroot.
- **Netac `ArchSwap`** — **persistent LUKS2** container named `cryptswap` with a passphrase slot + TPM2 slot (signed PCR 11 policy + stage-2 PCR 7 binding). Stage-1 enrolled at install (`install.sh` §5b); PCR 7 layered on by postinstall §7.5. Random-key swap was rejected: hibernate (S4) needs the swap contents to survive a power-off, and the kernel's `resume=` mechanism needs a stable mapper path. TPM2-sealed gives us silent unseal at boot just like cryptroot.
- **Netac `ArchRecovery`** — **unencrypted by design.** It's a raw Arch ISO meant to be bootable from F12 when the main install is hosed; encrypting it would defeat that purpose and there's nothing sensitive on it.
- **Samsung EFI** — unencrypted (UEFI spec requires the ESP to be FAT32 and unencrypted). The kernel + initramfs on it are public data, same as any normal install.

**Key management — BitLocker model:**
- **Auto-generated** at install time (Phase 2d `install.sh` `gen_and_show_luks_passphrase`): 24 bytes from `openssl rand -hex` → 48 hex chars → grouped 6-by-6 with hyphens. ~192 bits of entropy. Same shape and UX as the BitLocker recovery key.
- Displayed once in a yellow-banner panel; install.sh blocks until the user types `I HAVE THE KEY` verbatim. User photographs the screen, transcribes to Bitwarden as **"Metis LUKS recovery"** later (parallel to "Metis BitLocker recovery").
- Held in an in-memory bash variable for the rest of install.sh — used for `luksFormat` of all three volumes (cryptroot, cryptvar, cryptswap) and `luksAddKey` for the cryptvar keyfile; then `unset` at end of install. Never touches disk.
- TPM2 enrollment is two-stage: install-time `install.sh` §5b binds cryptroot + cryptswap to the **signed PCR 11 policy** (a keypair generated at install lives at `/etc/systemd/tpm2-pcr-{private,public}.pem` on the LUKS root — the private key is encrypted at rest by the very volume it gates). Phase 3 postinstall §7.5 measures the installed system's PCR 7 (stable only post-install) and re-enrolls each slot with `--tpm2-pcrs=7` *added* to the existing policy, which restores BitLocker-equivalent semantics around Secure Boot toggling. After §7.5 runs, both volumes unseal silently at boot unless the signed policy is invalidated (post-`leave-initrd`) or PCR 7 changes (SB toggle, firmware update, TPM clear).
- The recovery key is **the only fallback.** Lose the photo before transcribing to Bitwarden → encrypted disks are unrecoverable. No backdoor. Same destruction-on-loss model as BitLocker.
- If you'd prefer a memorable passphrase to the random hex string, swap key-slot 0 *after* unlocking once: `sudo cryptsetup luksChangeKey /dev/disk/by-partlabel/ArchRoot` (and same for `ArchVarLUKS`, `ArchSwapLUKS`). Stash the new passphrase in Bitwarden BEFORE rebooting.

**PCR policy — signed PCR 11 + stage-2 PCR 7:**
- **PCR 11** is the systemd boot-phase register. The UKI measures itself into PCR 11 at firmware exit, then `systemd-pcrphase` extends well-known constants at named transitions (`enter-initrd` → `leave-initrd` → `ready`). ukify (called by mkinitcpio at UKI build time) pre-computes and signs the PCR 11 prediction for the `enter-initrd` phase using the keypair at `/etc/systemd/tpm2-pcr-private.pem`. The signed prediction lands in a `.pcrsig` PE section of the UKI. The TPM unseals when the running thing produces a signature against the registered public key matching the current PCR 11 — i.e. when an authentic UKI is mid-`enter-initrd`. After `leave-initrd` extends the next constant, no signature matches → unseal impossible (BitLocker temporal scope).
- **PCR 7** = Secure Boot policy (on/off + key hashes). Layered on by postinstall §7.5 because install-time can't predict the installed system's PCR 7 reliably. Restores the "boot chain tampered" signal on SB toggling.
- Why not PCR 0+7 alone (the older approach): PCR drift between live ISO and installed first boot caused spurious passphrase prompts, and there was no signature anchor to re-bind to across firmware updates.
- This matches BitLocker's properties on the Windows side, so the security model mirrors across dual-boot.
- Full design rationale + threat model + recovery procedures: `docs/tpm-luks-bitlocker-parity.md`.

**crypttab layout:**
- `/etc/crypttab.initramfs` — baked into initramfs by mkinitcpio's `sd-encrypt` hook. Contains **both** cryptroot and cryptswap (cryptswap needs to be open before `resume=` runs, which is initramfs-time).
- `/etc/crypttab` — read post-init by systemd-cryptsetup generators. Contains cryptvar (keyfile from cryptroot).

**mkinitcpio HOOKS ordering:** `sd-encrypt` sits between `block` and `filesystems`. Without this, initramfs can't open cryptroot before trying to mount `/`.

**Kernel cmdline:** `root=/dev/mapper/cryptroot rootflags=subvol=@ resume=/dev/mapper/cryptswap rw quiet` in all three limine entries (`/Arch Linux`, `/Arch Linux (LTS)`, `/Arch Linux (Fallback)`) at `/boot/limine.conf`. No `rd.luks.name=` needed — crypttab.initramfs is the single source of truth. `resume=` enables S4 hibernate.

**Secure Boot readiness:**
- Secure Boot stays **off** at install time. The reinstall pre-installs `sbctl` (postinstall §1) and the `95-limine-redeploy.hook` is SB-aware — `/usr/local/sbin/limine-redeploy` calls `sbctl sign -s` after copy if SB is enrolled, no-op otherwise. Same for sbctl's own pacman hook (ships with the package), which auto-resigns kernels on every linux/linux-lts upgrade.
- Enabling SB later: BIOS → Setup Mode → from Arch run `sbctl create-keys && sbctl enroll-keys --microsoft && sbctl sign -s {/boot/EFI/BOOT/BOOTX64.EFI,/usr/share/limine/BOOTX64.EFI,/boot/vmlinuz-linux,/boot/vmlinuz-linux-lts}` → reboot, BIOS → User Mode (SB on) → at the LUKS prompt enter the recovery key (PCR 7 changed → TPM seal invalid) → `sudo /usr/local/sbin/tpm2-reseal-luks` → reboot, silent unlock again. Full sequence in `runbook/phase-3-handoff.md` "Upgrade Paths". Same one-time recovery-key prompt cycle on the Windows side (BitLocker also seals to PCR 7).

**Known limitations:**
- Recovery partition on Netac is unencrypted. A motivated attacker with physical access could swap the raw ISO for a malicious one. Mitigated by physical security of the laptop (no battery, stashed under a desk, no shared network access).
- If the TPM is reset (firmware reset, motherboard replacement), every sealed slot is dead and the recovery key is the only way in. Hence the "transcribe to Bitwarden" step is mandatory, not optional.
