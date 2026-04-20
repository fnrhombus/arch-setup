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
- **Battery**: NONE — the internal battery is dead / removed. Laptop is always on AC power, lives stashed under a desk. Downstream consequences:
  - Lid-close "suspend on battery" branch in `logind.conf` is dead code (systemd-logind never sees battery state). Harmless; left in for portability if a battery ever returns.
  - Hibernation is disabled (dual-boot + BitLocker would make it risky anyway) — swap sized for pressure relief only, not hibernate-to-disk. Could shrink from 16 GB → 4 GB in a future pass if `/var` on Netac runs tight.
  - Abrupt shutdowns (power cable kick) are the norm. btrfs COW handles this well — no `fsync` required for metadata integrity. Good argument for btrfs over ext4 on root.
  - SDDM is the primary moment of the day where the user authenticates (no suspend/resume cycles → no lock screens) — fingerprint at SDDM is therefore load-bearing, not cosmetic.

## Requirements
- [x] Fingerprint scanner support (fprintd + libfprint). **Device: Goodix `27c6:538c`** — supported only via the AUR `libfprint-goodix-53xc` package (older Dell OEM blob, pre-v0.0.11) riding on `libfprint-tod-git`. Current upstream AUR `libfprint-2-tod1-goodix` / `-v2` ship a **550A-only** blob that does NOT cover 538C. `libfprint-tod-git` must be built with `!lto` in PKGBUILD options — LTO strips ABI symbol versioning and breaks the link. `postinstall.sh` pre-flights this automatically. Enrollment on a bare TTY needs `sudo fprintd-enroll -f <finger> tom` (polkit denies unprivileged enroll without a graphical session).
- [x] Lid close: no sleep/shutdown on AC power (logind.conf) — wired by phase-2 `chroot.sh` via `/etc/systemd/logind.conf.d/10-lid.conf` (`HandleLidSwitchExternalPower=ignore`).
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

#### B) AUR helper: yay
- Less strict about PKGBUILD review prompts, better fit for user who won't read them

#### C) Terminal emulator: Ghostty
- GPU-accelerated, great defaults, Kitty graphics protocol support
- Pairs with tmux for splits/sessions
- **end-4 compatibility shim: also install `foot`.** end-4's first-launch wizard hardcodes its "supported terminals" list to kitty, alacritty, foot, wezterm, konsole, gnome-terminal, xterm — Ghostty is unknown to it. `foot` is the lightest Wayland-native entry in their list; it satisfies the wizard's detector while Ghostty remains the daily driver via a Super+Return remap in the end-4 Hyprland keybinds.
- **Ghostty theme config gotcha**: the bundled theme file name is `Catppuccin Mocha` (capital C, literal space), not `catppuccin-mocha`. `theme = "Catppuccin Mocha"` in `~/.config/ghostty/config`.

#### D) Login screen: SDDM
- Wayland-native, themeable, fingerprint integration

#### E) Notifications: mako
- Wayland-native, lightweight, matches the foot/fuzzel/swww profile of the rest of the stack.
- **Why not swaync**: end-4's first-launch wizard only accepts `dunst` or `mako` as the notification daemon. swaync is installed-but-invisible to end-4's detector. mako is the simpler of the two accepted options; dunst is the feature-rich alternative if mako ever feels too minimal.

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

#### O) RDP client: Remmina
- Full-featured GUI, connection manager, Wayland-native
- For accessing Windows 10 machine
- **Not installed by default** (deferred to phase-3.5 — no RDP target to validate against during a fresh install). Add with `sudo pacman -S remmina freerdp` when needed.

#### Q-file) File manager: yazi (primary) + nautilus (GUI fallback)
- **yazi** — terminal file manager, keyboard-first, vim-style keybinds, Rust-native, rich previews (images/PDF/code). Fits the terminal-heavy workflow (tmux/helix/ghostty). Daily driver.
- **nautilus** — GTK4 GUI file manager, Wayland-tested, picks up the Catppuccin GTK theme for free, minimal-friction for drag/drop, network mounts (smb://, sftp://). The deliberate polar opposite of yazi for "sit back, click around" mode. Also satisfies end-4's wizard-detected file-manager slot.
- **Not Dolphin/Nemo/Thunar/PCManFM**: Dolphin adds a Qt/KDE theming tax while being philosophically the same dense-power-user tool as yazi; Thunar's Wayland support is X11-first; PCManFM is a low-RAM pick we don't need; Nemo's maintenance velocity lags Nautilus.

#### P) Installer password handoff: pre-hashed via mode-600 file
- `phase-2-arch-install/install.sh` reads the root + `tom` passwords once at the top of the run, hashes them immediately with `openssl passwd -6` (SHA-512), and hands the hashes to `chroot.sh` via a mode-600 file under `/mnt/tmp/`. The plaintext values never touch disk.
- **Caveat**: while the installer is still running, the `openssl passwd` invocation does briefly appear in `ps` (as the process argument) on the live ISO. The live environment is single-user and ephemeral, so this is acceptable — but don't run the installer on a shared/networked machine. After chroot finishes, the hash file is deleted and only the hashed values remain in `/etc/shadow`.

### Q13: end-4/dots-hyprland config layout (observed)
- **Single primary file**: `~/.config/hypr/hyprland.conf` (no `custom/` subdir on the version we cloned in April 2026).
- **Terminal variable**: `$terminal = foot` defined at line 35. Change there to swap to Ghostty (`$terminal = ghostty`).
- **Terminal keybind**: `Super+Q` (line 245: `bind = $mainMod, Q, exec, $terminal`), NOT Super+Return.
- **Reload after edit**: `hyprctl reload` (no logout needed).
- **Status bar**: `quickshell` does NOT auto-start from end-4's vanilla config. Add `exec-once = quickshell` to hyprland.conf if the bar is missing after install.

### Q12: end-4/dots-hyprland runtime dependencies

The current `end-4/dots-hyprland` repo ships a **GUI first-launch wizard that detects components but does not install them** — older versions ran a CLI `install.sh` that auto-pulled deps; that's no longer true. `postinstall.sh` must install everything end-4 expects on the host directly.

**Required packages end-4 expects (per its first-launch detector):**
- **Authentication agent**: `hyprpolkitagent` (also accepted: `polkit-kde-agent`). **Must be activated via `systemctl --user enable --now hyprpolkitagent.service`** — the package ships the unit with preset `enabled`, but the preset does NOT auto-activate on a fresh install; `postinstall.sh` enables it explicitly.
- **Terminal**: see §Q10-C (Ghostty as daily driver + `foot` as end-4 shim).
- **File manager**: see §Q10-Q-file (`nautilus` fills end-4's slot; `yazi` is primary).
- **Notification daemon**: `mako` (§Q10-E). `swaync` is not on end-4's accepted list and shows as Missing in the wizard even when installed and running.
- **Wallpaper**: `swww`.
- **XDG Desktop Portal**: `xdg-desktop-portal-hyprland` (installed in phase 2 pacstrap) + `xdg-desktop-portal-gtk` (installed in phase 3 postinstall as the GTK backend).
- **Status bar / shell**: `quickshell-git` (AUR). end-4 replaced their earlier `ags`-based bar with quickshell.
- **Application launcher**: `fuzzel` (already decided in §Q10-F, accepted by end-4).
- **Clipboard**: `wl-clipboard` provides `wl-copy` (already in §Q10-H).
- **Pipewire**: already in §Q10-I.

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
