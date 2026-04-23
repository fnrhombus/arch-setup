# Arch Linux Dual-Boot Setup — Decisions & Notes

## System
- **Laptop**: Dell Inspiron 7786 (17" 2-in-1 convertible)
- **CPU**: Intel i7-8565U (4c/8t, Whiskey Lake)
- **RAM**: 16GB DDR4-2400 (Dell spec; i7-8565U's official DDR4 ceiling is 2400 anyway)
- **GPU**: NVIDIA GeForce MX250 (2GB) + Intel UHD 620 (Optimus)
- **Target Drive**: Samsung SSD 840 PRO 512GB (currently D: + V:)
- **WiFi**: Dell Wireless 1801 (Qualcomm Atheros) + BT 4.0
- **Display**: Integrated touch + external Vizio via USB DisplayLink dock
- **Boot**: UEFI, GPT. *Current BIOS state*: Secure Boot ON, SATA in RAID mode. *Before phase 1 runs*: flip SATA → **AHCI** (RAID hides the NVMe from every Linux installer + the Windows setup USB), disable **Secure Boot** (systemd-boot + unsigned initramfs = easier path; can re-enable later with `sbctl` signing if wanted).
- **Peripherals**: Touchscreen, touchpad, fingerprint reader, active pen
- **Battery**: NONE *currently* — the internal battery is dead / removed; user plans to replace it. Laptop is always on AC power, lives stashed under a desk. Downstream consequences:
  - Lid-close "hibernate on battery" branch in `logind.conf` is dead code today (no battery state for logind to see). Configured anyway for forward-compat — fires automatically when a battery returns, no reconfig.
  - **Hibernation is enabled** (S4) on Linux. Reverses the prior "disabled" decision; the cited dual-boot/BitLocker risk doesn't apply (Linux swap is on the Netac, Windows can't see LUKS or btrfs). Until the battery is replaced, hibernate is **user-invoked** (`Super+Shift+H`) since AC removal is an instant hard-cut. Swap sized 16 GB to match RAM. Persistent LUKS swap, TPM2-keyfile-sealed (mirrors cryptvar). See `docs/desktop-requirements.md` §Hibernate for the full plan.
  - Abrupt shutdowns (power cable kick) are the norm. btrfs COW handles this well — no `fsync` required for metadata integrity. Good argument for btrfs over ext4 on root.
  - The greeter is the primary moment of the day where the user authenticates (no suspend/resume cycles → no lock screens) — fingerprint at the greeter is therefore load-bearing, not cosmetic.

## Requirements
- [x] Fingerprint scanner support (fprintd + libfprint). **Device: Goodix `27c6:538c`** — supported only via the AUR `libfprint-goodix-53xc` package (older Dell OEM blob, pre-v0.0.11) riding on `libfprint-tod-git`. Current upstream AUR `libfprint-2-tod1-goodix` / `-v2` ship a **550A-only** blob that does NOT cover 538C. `libfprint-tod-git` must be built with `!lto` in PKGBUILD options — LTO strips ABI symbol versioning and breaks the link. `postinstall.sh` pre-flights this automatically. Enrollment on a bare TTY needs `sudo fprintd-enroll -f <finger> tom` (polkit denies unprivileged enroll without a graphical session).
- [x] Lid close: no sleep/shutdown on AC power (logind.conf) — wired by phase-2 `chroot.sh` via `/etc/systemd/logind.conf.d/10-lid.conf` (`HandleLidSwitchExternalPower=ignore`).
- [ ] Wacom Intuos pen tablet support — built-in Wacom AES digitizer driven by
  the kernel `wacom` module (in-tree linuxwacom). `libwacom` installed via
  `postinstall.sh` for tablet metadata. Pressure/tilt expected to work under
  Wayland; eraser-end may need a udev quirk if not auto-detected. **Verify on
  hardware**: actual VID/PID and whether it's Wacom-AES vs Goodix on this
  specific 7786 revision (`dmesg | grep -i -E 'wacom|goodix|hid-multitouch'`
  after first boot).
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
- **Hyprland** — eye-candy king, GPU-accelerated animations, blur, rounding
- **Dotfiles: HyDE-Project/HyDE** (switched from end-4/illogical-impulse on 2026-04-20).
  - Why HyDE: bootloader-agnostic (we keep systemd-boot — see §A), ships
    Catppuccin-Mocha as a bundled theme, works as an overlay on existing Arch
    + Hyprland, has a `theme-switch` CLI for one-shot theme application.
  - Why not Omarchy (the closer fit on opinionatedness + Ghostty defaults +
    keyboard-ninja UX): Omarchy mandates the **`limine` bootloader** via a hard
    preflight guard, which would require redoing phase 2. Defer until/unless
    the bootloader migration is on the table.
  - Why not stay on end-4: the end-4 first-launch wizard requires the user to
    answer multiple prompts and the dotfiles do not bundle a theme switcher;
    Catppuccin Mocha alignment is manual. HyDE's `theme-switch.sh` makes the
    theme idempotent under postinstall.
  - HyDE clobbers `~/.config/hypr/`, `~/.config/waybar/`, etc. on install,
    but backs the prior tree up to `~/.config/cfg_backups/<timestamp>/` first.
    Do NOT layer HyDE over end-4 — pick one.
  - HyDE's default terminal is **kitty**, not Ghostty. `postinstall.sh`
    13a sed-rewrites the `$term` / `$TERMINAL` / `$terminal` variable in
    `hyprland.conf` + `keybindings.conf` to ghostty.

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
- Plugins (managed by tpm): tmux-sensible, catppuccin/tmux. Session switching lives in `sesh` (installed via pacman), not a plugin. Worktree-per-session is a workflow, not a plugin — one sesh entry per worktree.

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
[EFI 512MB FAT32] [MSR 16MB] [Windows 160GB NTFS] [Linux ~316GB btrfs]
```

**Netac 128GB SSD (secondary — non-speed-critical):**
```
[Arch recovery ISO ~1.5GB] [swap 16GB] [/var/log + /var/cache ~110GB ext4]
```
- Recovery partition: Arch live ISO written to partition, bootable via systemd-boot entry
- Replaces need for live USB after initial install

- **btrfs subvolumes**: @, @home, @snapshots
- **Mount options**: `noatime,compress=zstd:3,space_cache=v2,ssd` (level-3 zstd is the Arch-wiki default — good ratio, negligible CPU cost; `space_cache=v2` + `ssd` are the modern defaults for SATA SSDs).
- /var/log and /var/cache on Netac — keeps them off btrfs snapshots and off the main SSD's endurance budget.
- Windows partition mounted read-only at `/mnt/windows` for media access (read-only avoids the NTFS-fuse write-corruption risk).
- **Resize strategy (Linux → Windows)**: `phase-6-grow-windows.sh` adds a new btrfs device at the tail of the Samsung, runs `btrfs device add`+`remove` to migrate data, then deletes the original partition — free space ends up **directly adjacent to Windows** so Disk Management's Extend Volume works. Swap lives on the *Netac*, so nothing sits between Windows and the new free space.
- Disable Windows Fast Startup + hibernation for clean dual-boot (baked into `autounattend.xml` via `Specialize.ps1`).

### Q10: Other Needs

#### A) Bootloader: systemd-boot
- Simplest, fastest, already part of systemd
- Arch recovery ISO written to a dedicated 1.5 GB partition on the Netac; systemd-boot entry points at it, so it boots straight from the menu without hunting for a USB stick.
- USB is only needed for the *initial* Windows + Arch install. All later rescue work (including `phase-6-grow-windows.sh`, which must run from a live environment with the btrfs unmounted) can boot the recovery entry instead.
- **Why not limine** (Omarchy's required bootloader, considered 2026-04-20):
  - Limine *would* gain us first-class snapper-snapshot rollback in the boot
    menu (`limine-snapper-sync` + `limine-mkinitcpio-hook`) and a branded
    splash. systemd-boot has neither — snapshot rollback today requires booting
    the recovery ISO and `arch-chroot`-ing to manage subvolumes manually.
  - Cost: migration is a 30–60 min btrfs-aware exercise (`pacman -S limine`,
    `cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/`, write `limine.conf`
    with `rootflags=subvol=@`, add an `efibootmgr` NVRAM entry, optionally
    `bootctl remove`) — recoverable as long as the systemd-boot NVRAM entry is
    kept until the limine boot succeeds.
  - Trade-off: systemd-boot is in the `systemd` package (zero AUR), wider
    ArchWiki coverage, and auto-discovers the Windows EFI loader for dual-boot.
    Limine needs an explicit `/EFI/Microsoft/Boot/bootmgfw.efi` chainload stanza.
  - Verdict: the only motivating use case is enabling Omarchy. Migration is
    NOT worth it just to run a dotfiles distro — HyDE achieves 80 % of
    Omarchy's UX without touching the bootloader. Revisit if one-keystroke
    snapshot rollback becomes load-bearing.

#### B) AUR helper: yay
- Less strict about PKGBUILD review prompts, better fit for user who won't read them

#### C) Terminal emulator: Ghostty
- GPU-accelerated, great defaults, Kitty graphics protocol support
- Pairs with tmux for splits/sessions
- **`foot` stays installed** as a fallback / minimal Wayland-native terminal
  for cases where Ghostty hasn't started yet (TTY-launched recovery, theme
  reset). Originally added as an end-4 wizard shim; retained on the HyDE swap
  because it costs ~2 MB and is a useful safety net when Ghostty config is in
  flux. HyDE's default is **kitty** which we sed-out, so `foot` is the only
  pre-Ghostty fallback that lives in pacman `[extra]`.
- **Ghostty theme config gotcha**: the bundled theme file name is `Catppuccin Mocha` (capital C, literal space), not `catppuccin-mocha`. `theme = "Catppuccin Mocha"` in `~/.config/ghostty/config`.

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
- Firefox **not installed by default** — Edge covers the daily driver need; add with `sudo pacman -S firefox` when a Wayland-native backup is useful.

#### O) RDP client: Remmina + FreeRDP
- Full-featured GUI, connection manager, Wayland-native (`remmina`).
- FreeRDP backend (`freerdp`) provides the actual RDP protocol implementation
  — Remmina is the GUI shell on top.
- For accessing Windows 10 machine. Installed by `postinstall.sh` §1.

#### Q-file) File manager: yazi (primary) + nautilus (GUI fallback)
- **yazi** — terminal file manager, keyboard-first, vim-style keybinds, Rust-native, rich previews (images/PDF/code). Fits the terminal-heavy workflow (tmux/helix/ghostty). Daily driver.
- **nautilus** — GTK4 GUI file manager, Wayland-tested, picks up the Catppuccin GTK theme for free, minimal-friction for drag/drop, network mounts (smb://, sftp://). The deliberate polar opposite of yazi for "sit back, click around" mode.
- **Not Dolphin/Nemo/Thunar/PCManFM**: Dolphin adds a Qt/KDE theming tax while being philosophically the same dense-power-user tool as yazi; Thunar's Wayland support is X11-first; PCManFM is a low-RAM pick we don't need; Nemo's maintenance velocity lags Nautilus.

#### Desktop component picks (locked 2026-04-22, validation pass)

Rapid-fire small picks. All recommended by the validation research agent
and accepted on the "clean-slate, no bias" principle. See
`docs/desktop-requirements.md` for full component list.

- **OSD popups**: SwayOSD — GTK4, in extra; volume/brightness/caps-lock; CSS themed via matugen.
- **Network UI**: nm-connection-editor for full config + a custom waybar nmcli module for at-a-glance state. Skip nm-applet (the tray icon is redundant).
- **Bluetooth UI**: overskride (AUR) — GTK4/libadwaita, Wayland-native. Blueman is the GTK3 fallback.
- **Audio mixer GUI**: pwvucontrol — PipeWire-native (no PulseAudio shim). pavucontrol is the legacy fallback.
- **Color picker**: hyprpicker — Wayland-native, magnifier loupe, autocopy.
- **Power menu**: wleave (AUR) — GTK4 fork of wlogout, themes via matugen.
- **Image viewer**: imv — fast, reliable, modal keys. (Loupe rejected: libadwaita ignores GTK theming, won't follow matugen.)
- **PDF viewer**: zathura + zathura-pdf-poppler — Xwayland but the modal-keys UX wins. Sioyek is the Wayland-native alternative if Xwayland ever bites.
- **GTK theme manager**: nwg-look (GTK3/libadwaita settings; matugen overwrites the resulting CSS).
- **Qt theme manager**: qt6ct + qt5ct, with `QT_QPA_PLATFORMTHEME=qt6ct`. Matugen ships a Qt template.
- **Cursor**: Bibata-Modern-Classic in **hyprcursor** format (~6.6 MB vs 44 MB Xcursor). Phinger is the alternative if Bibata feels too neutral.
- **Icon theme**: Papirus-Dark — best app coverage. Tela is the runner-up if a more uniform "modern" feel matters more than coverage.
- **Resource monitor (GUI)**: mission-center (AUR) — one piece the per-tool launcher genuinely misses; complements btop in the terminal.

#### P) Installer password handoff: pre-hashed via mode-600 file
- `phase-2-arch-install/install.sh` reads the root + `tom` passwords once at the top of the run, hashes them immediately with `openssl passwd -6` (SHA-512), and hands the hashes to `chroot.sh` via a mode-600 file under `/mnt/tmp/`. The plaintext values never touch disk.
- **Caveat**: while the installer is still running, the `openssl passwd` invocation does briefly appear in `ps` (as the process argument) on the live ISO. The live environment is single-user and ephemeral, so this is acceptable — but don't run the installer on a shared/networked machine. After chroot finishes, the hash file is deleted and only the hashed values remain in `/etc/shadow`.

### Q13: HyDE-Project/HyDE config layout (observed)
- **Install root**: clone to `~/HyDE` (we use `~/HyDE`, the upstream-recommended path), installer at `~/HyDE/Scripts/install.sh`.
- **Helper binaries**: HyDE drops its own scripts into `~/.local/share/bin/`
  (`theme-switch.sh`, `Hyde.sh`) and a shared lib into `~/.local/lib/hyde/`.
  These are the postinstall idempotency markers — if either exists, we skip
  re-running `install.sh`.
- **Hyprland config root**: `~/.config/hypr/` — `hyprland.conf` is the entry
  point, but HyDE splits binds and animations into `~/.config/hypr/keybindings.conf`
  and friends, all sourced from `hyprland.conf`.
- **Terminal variable**: HyDE's keybinds reference a variable for the terminal
  (commonly `$term` or `$TERMINAL`) defaulting to `kitty`. `postinstall.sh`
  §13a sed-rewrites it to `ghostty` across both `hyprland.conf` and
  `keybindings.conf`. If a future HyDE rev changes the variable name, the
  pattern stops matching and the rewrite becomes a no-op — sanity check
  `hyprctl getoption -j misc:disable_hyprland_logo` and the visible Super+Return
  behaviour after install.
- **Bar**: HyDE uses **Waybar** (multi-themed); no `quickshell` involved.
- **Theme switcher**: `~/.local/share/bin/theme-switch.sh -s "Catppuccin-Mocha"`
  (idempotent — re-run is a no-op if the theme is already active). `Ctrl+Super+T`
  cycles through bundled themes.
- **Backups**: every install run snapshots prior configs to `~/.config/cfg_backups/<timestamp>/`.
- **Reload after edit**: `hyprctl reload` (no logout needed).

### Q12: HyDE-Project/HyDE runtime dependencies

HyDE's `Scripts/install.sh` pulls most of its own runtime deps via pacman/yay
during install, but `postinstall.sh` pre-installs the keys ones from `[extra]`
ahead of time so the verify block can prove them present and so the network
churn is front-loaded.

**Packages HyDE expects (and which we explicitly install):**
- **Authentication agent**: `hyprpolkitagent` — must be activated via
  `systemctl --user enable --now hyprpolkitagent.service` (the unit's preset
  is `enabled` but doesn't auto-activate on a fresh install; without it
  Bitwarden's "Unlock with system keyring" stays grayed out).
- **Terminal**: Ghostty (daily driver, §Q10-C). HyDE's default is **kitty**;
  postinstall §13a sed-rewrites the `$term` / `$TERMINAL` variable.
- **File manager**: yazi (primary) + nautilus (GUI), §Q10-Q-file.
- **Notification daemon**: `mako` (§Q10-E).
- **Wallpaper**: `swww` (HyDE expects it for theme switches).
- **XDG Desktop Portal**: `xdg-desktop-portal-hyprland` (phase 2 pacstrap) +
  `xdg-desktop-portal-gtk` (phase 3 postinstall).
- **Application launcher**: `fuzzel` (HyDE itself defaults to rofi but accepts
  fuzzel; we keep §Q10-F).
- **Clipboard**: `wl-clipboard` (§Q10-H).
- **Pipewire**: §Q10-I.

**2-in-1 hardware additions (new, postinstall §1):**
- `iio-sensor-proxy` — pacman; reads accelerometer.
- `iio-hyprland` — AUR; bridges accelerometer → `hyprctl monitor` transforms.
- `wvkbd` — pacman; provides `wvkbd-mobintl` on-screen keyboard for tablet mode.
- `libwacom` — pacman; tablet metadata (pressure curves, button maps).
- **hyprgrass** — Hyprland plugin (installed via `hyprpm add` in postinstall §13a)
  for long-press, edge swipes, and OSK-toggle gestures beyond Hyprland's
  built-in 3-finger workspace swipe.

**The wizard's color legend**: red = not installed, green = installed but not running, blue = installed AND running. Hover on each component to see its accepted-package list. `postinstall.sh` bakes the above list into sections 1 (pacman) + 3 (yay) + 1b (systemctl --user enable hyprpolkitagent).

### Q11: Full-Disk Encryption (LUKS2 + TPM2 autounlock)

Parity with Windows BitLocker on the same machine. "Stolen laptop" becomes "brick" — data is readable only with the passphrase or an intact boot chain sealed to TPM2 PCRs 0+7.

**Scope of encryption:**
- **Samsung `ArchRoot`** (btrfs + @ / @home / @snapshots subvolumes) — LUKS2 container named `cryptroot`. Passphrase slot + TPM2 slot (PCRs 0+7).
- **Netac `ArchVar`** (ext4 — /var/log + /var/cache) — LUKS2 container named `cryptvar`. Passphrase slot + keyfile slot reading from `/etc/cryptsetup-keys.d/cryptvar.key` on the (TPM-unlocked) cryptroot.
- **Netac `ArchSwap`** — plain dm-crypt with a random `/dev/urandom` key generated per boot (`cryptswap`). Swap never needs to survive reboots, so a persistent LUKS header is pointless.
- **Netac `ArchRecovery`** — **unencrypted by design.** It's a raw Arch ISO meant to be bootable from F12 when the main install is hosed; encrypting it would defeat that purpose and there's nothing sensitive on it.
- **Samsung EFI** — unencrypted (UEFI spec requires the ESP to be FAT32 and unencrypted). The kernel + initramfs on it are public data, same as any normal install.

**Key management:**
- One passphrase set at install time (Phase 2d `install.sh`) unlocks both LUKS containers. Stored in a bash variable in install.sh, never touches disk. Used for `luksFormat` both volumes and `luksAddKey` for the cryptvar keyfile; then `unset` at end of install.
- TPM2 enrollment happens in Phase 3 (`systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7`). After that, `cryptroot` unseals silently unless the boot chain changes.
- The passphrase is **the recovery mechanism.** Stash it in Bitwarden parallel to the BitLocker key.

**PCR choice — 0+7:**
- PCR 0 = UEFI firmware code. PCR 7 = Secure Boot policy (on/off + key hashes).
- Both are stable across reboots with the same bootloader config, but change when firmware updates or Secure Boot state is toggled — exactly the "boot chain was tampered with" signal we want.
- PCRs 4/5/8/9 (bootloader + kernel measurements) change every kernel upgrade, which would force a passphrase prompt after every `pacman -Syu`. Rejected.
- This matches BitLocker's default PCR profile on the Windows side, so the security properties mirror each other across dual-boot.

**crypttab layout:**
- `/etc/crypttab.initramfs` — baked into initramfs by mkinitcpio's `sd-encrypt` hook. Contains cryptroot only.
- `/etc/crypttab` — read post-init by systemd-cryptsetup generators. Contains cryptvar (keyfile) + cryptswap (random key).

**mkinitcpio HOOKS ordering:** `sd-encrypt` sits between `block` and `filesystems`. Without this, initramfs can't open cryptroot before trying to mount `/`.

**Kernel cmdline:** `root=/dev/mapper/cryptroot rootflags=subvol=@` in all three systemd-boot loader entries (arch.conf, arch-fallback.conf, arch-lts.conf). No `rd.luks.name=` needed — crypttab.initramfs is the single source of truth.

**Known limitations:**
- Secure Boot stays off until post-phase-3 `sbctl` wiring. PCR 7 still has a consistent hash for "Secure Boot off," so the TPM seal is stable — but re-enabling Secure Boot later will invalidate the seal and require a re-enrollment.
- Recovery partition on Netac is unencrypted. A motivated attacker with physical access could swap the raw ISO for a malicious one. Mitigated by physical security of the laptop (no battery, stashed under a desk, no shared network access).
- If the TPM is reset (firmware reset, motherboard replacement), the sealed slot is dead and the passphrase is the only way in. Hence the "stash in Bitwarden" step is mandatory, not optional.
