# GLOSSARY.md

Every tool, term, and package that shows up in [docs/decisions.md](../docs/decisions.md), [phase-3-handoff.md](phase-3-handoff.md), and [phase-3-arch-postinstall/postinstall.sh](../phase-3-arch-postinstall/postinstall.sh) that isn't obvious on sight. Each entry: **full name** — what it does — when you'd care.

Organized by category so you can skim. Nothing here is install instructions — those are in the runbook.

---

## Graphical stack

- **Wayland** — Modern display protocol replacing X11/Xorg. You care: Hyprland is Wayland-only, so every GUI app either speaks Wayland natively or falls back through `xwayland`. Apps that misbehave are usually legacy X11 apps that didn't fall back cleanly.
- **Xorg / X11** — The old display server. You care: some apps (especially older Electron builds, Wine, GIMP) still prefer it; `xwayland` runs them on Wayland.
- **Compositor** — The thing that draws windows on screen under Wayland. Hyprland is a compositor and window manager rolled into one.
- **Hyprland** — The compositor we chose. Tiling, keyboard-driven, GPU-accelerated effects. You care: *every* GUI session you have will be running in Hyprland.
- **bare-Hyprland (Claude-authored configs in chezmoi)** — Our dotfile approach. NOT a pre-built pack (no HyDE, no end-4, no Caelestia). Configs at `dot_config/hypr/*` in the [rhombu5/dots](https://github.com/rhombu5/dots) repo are split into fragments (monitors, workspaces, binds, decoration, animations, plugins, exec). You own every line; future "change X" is one prompt to Claude.
- **greetd** — Tiny "show a login UI, then start the session" daemon. **Currently disabled** (postinstall.sh §1f, 2026-04-30) — login is bare TTY → uwsm → Hyprland via `~/.zprofile`. Packages + config stay on disk as a recoverable fallback; re-enable with `sudo systemctl enable --now greetd.service`. See `decisions.md` §D.
- **ReGreet** — GTK4-based greeter UI that greetd launches. Same disabled-fallback status as greetd above.
- **uwsm** (Universal Wayland Session Manager) — Wraps a Wayland compositor in a proper systemd `graphical-session.target` lifecycle (env import, dependent-unit activation, clean shutdown). Hyprland itself prints "highly discouraged unless debugging" when launched without a session manager. Invoked from `~/.zprofile` as `uwsm start hyprland-uwsm.desktop` on tty1 login.
- **SDDM / GDM / LightDM** — Other display managers (KDE / GNOME / XFCE world). We don't use them; ignore.

## Wayland ecosystem utilities

- **Waybar** — Top/bottom bar (taskbar, clock, battery, audio). You care: it's always on screen.
- **swaync** (Sway Notification Center) — Toast notifications + a history/DND panel. You care: when a notification appears, this drew it.
- **fuzzel** — App launcher. Wayland-native, fuzzy-matching. You care: this is what opens when you hit the launcher key.
- **rofi-wayland** — More-featured alternative launcher with scripting (calculator, emoji, SSH picker). You care: not installed by default, only if fuzzel turns out too minimal.
- **hyprshot** — Screenshot tool built for Hyprland (region/window/monitor). Plays the role `grimblast` plays on sway.
- **satty** (Screenshot Annotation Tool) — Post-capture annotation: arrows, boxes, blur, text. You care: `hyprshot | satty` gives you Snipping-Tool-level UX.
- **wl-clipboard** — `wl-copy` / `wl-paste` command-line clipboard utilities. You care: scripts and Claude Code use these to read/write the clipboard.
- **cliphist** — Clipboard history daemon. Stores text + image clips, picker via fuzzel. Bound to Super+V (Win+V analog).
- **wleave** — Graphical logout/shutdown/reboot menu. GTK4 fork of the older `wlogout`; themed via matugen GTK CSS. Bound to Super+Shift+Q.
- **awww** — Wayland wallpaper daemon with smooth transitions. Continuation of `swww` (LGFae moved/renamed it on Codeberg 2025-10). Binaries: `awww-daemon` (background), `awww img <path>` (set wallpaper).
- **swayosd** — On-screen-display popups for volume/brightness/caps-lock. GTK4. Triggered by `swayosd-client --output-volume raise` etc. (which we wire to media keys).
- **hyprlock** — Hyprland-native lockscreen. Layout in `~/.config/hypr/hyprlock.conf`; PAM stack at `/etc/pam.d/hyprlock` (PIN → fingerprint → password, per postinstall.sh §7a).
- **hypridle** — Hyprland-native idle daemon. Listens for input, fires actions on timeout (DPMS off at 28 min, lock at 30 min). No idle-hibernate.
- **hyprpolkitagent** — Hyprland-native polkit agent. Pops up the auth dialog when an app needs root (Bitwarden unlock prompt, mount prompts, etc.).
- **hyprpicker** — Color picker. Magnifier loupe + autocopy. Bound to Super+P.
- **Hyprspace** — Hyprland plugin: interactive workspace overview. Bound to Super+grave (the key above Tab). Loaded via `hyprpm`. Click anywhere to drag a window; drop on another workspace tile to move (and follow) it there. Replaced hyprexpo (which is passive — click-to-switch only, no drag).
- **hyprgrass** — Hyprland plugin: touch gesture engine for the 2-in-1. Single-finger long-press, edge swipes, OSK toggle. Loaded via `hyprpm`.
- **hyprpm** — Hyprland's plugin manager. `hyprpm add <repo>`, `hyprpm enable <plugin>`, `hyprpm update`. Auto-pins plugins to your Hyprland version.
- **wvkbd** — On-screen keyboard for tablet mode. `wvkbd-mobintl --hidden` is what hyprgrass's edge-swipe-up toggles.

## Audio

- **PipeWire** — Modern audio/video server. Replaces PulseAudio + JACK. You care: all sound goes through it.
- **WirePlumber** — Session manager for PipeWire (which app gets which device, routing). You care: if a headset shows up but has no sound, this is the thing to poke.
- **PulseAudio** — Old server, deprecated. PipeWire provides a PulseAudio-compatible API so older apps still work.
- **JACK** (Audio Connection Kit) — Pro-audio server with sample-accurate latency. PipeWire also emulates this — lets you run Bitwig/Ardour without extra config.

## Shell + CLI

- **zsh** — The shell. Same role as bash, better completion + prompt.
- **zgenom** — Plugin manager for zsh. Caches compiled plugin init into `~/.zgenom/` on first login. You care: change `.zshrc`'s plugin list, run `zgenom reset`.
- **Oh-My-Zsh** (OMZ) — Framework of built-in zsh themes + plugins. Zgenom knows how to load OMZ plugins.
- **powerlevel10k** (p10k) — Fast, pretty zsh prompt. You care: shipped pre-configured (`~/.p10k.zsh`). Tweak with `p10k configure` if you want to re-style.
- **tmux** — Terminal multiplexer (sessions, splits, persistence after disconnect). Prefix `Ctrl+a`. You care: Claude Code's worktree workflow needs it.
- **sesh** — Smart tmux session switcher. Fuzzy-matches directories, turns one tmux session per worktree into a picker.
- **tpm** (Tmux Plugin Manager) — Installs tmux plugins declared in `~/.tmux.conf`.
- **helix** / `hx` — Terminal editor. Modal like vim but with selection-first (verb-last) commands; built-in LSP + treesitter; zero-config.
- **Ghostty** — Terminal emulator. GPU-accelerated, minimal-config, Kitty graphics protocol. You care: this is your default terminal.

## Modern CLI replacements

- **eza** — `ls` replacement. Git-aware, colored, tree view. `lsd` is an alternative.
- **bat** — `cat` with syntax highlighting + paging.
- **fd** — `find` replacement, faster, nicer syntax.
- **ripgrep** / `rg` — `grep` replacement, faster, respects `.gitignore`.
- **zoxide** / `z` — `cd` with memory. `z foo` jumps to whichever recent dir matches "foo".
- **fzf** — Fuzzy finder. Pipe anything into it, select interactively.
- **jq** — JSON query/transform: `curl ... | jq '.results[0].name'`.
- **yq** — Same as jq, for YAML/TOML.
- **sd** — `sed` replacement with saner regex syntax.
- **xh** — `curl` replacement (HTTPie-style). Nicer for JSON APIs.
- **tldr** — Cheat-sheet man pages. `tldr tar` shows the 5 commands you actually use.
- **btop** — Top/htop replacement. Live CPU/RAM/disk/net graphs.
- **gh** — GitHub CLI. `gh pr create`, `gh repo clone`, etc.
- **direnv** — Per-directory env vars. `cd` into a project, its `.envrc` loads automatically.
- **mise** — Tool version manager (node/python/etc per-project via `.mise.toml`). Successor to `rtx`/`asdf`.
- **chezmoi** — Dotfile manager. Templates, git-backed, can pull secrets from Bitwarden.
- **pkgfile** — Which package provides `foo`? `pkgfile foo` tells you. Backs the "command not found" handler.

## Networking

- **NetworkManager** (nmcli, nmtui) — Full-featured network stack (Wi-Fi + Ethernet + VPN). You care: this is the primary way you'll manage connections. `nmtui` from a TTY, `nmcli` for scripting; Waybar/GUI applets talk to the same daemon.
- **iwd** (iNet Wireless Daemon) — Intel's modern Wi-Fi daemon. We use it as NetworkManager's Wi-Fi backend (configured via `wifi.backend=iwd`), not standalone. Handles WPA3, faster than wpa_supplicant.
- **iwctl** — Interactive CLI for `iwd`. Fallback only — if NetworkManager is broken, stop it (`systemctl stop NetworkManager`), start `iwd`, use `iwctl`. See [SURVIVAL.md](SURVIVAL.md).
- **wpa_supplicant** — The old Wi-Fi auth daemon `iwd` replaces. Not installed.
- **systemd-resolved** — systemd's DNS resolver/cache. NetworkManager hands DNS to it.

## Boot / UEFI / disk

- **UEFI** — Modern firmware standard; replaces BIOS. You care: the laptop boots through UEFI.
- **GPT** (GUID Partition Table) — Modern partition-table format. Required for UEFI boot.
- **ESP** (EFI System Partition) — FAT32 partition where the bootloader lives. 512 MB on our Samsung.
- **MSR** (Microsoft Reserved) — 16 MB partition Windows wants. Not used by Linux.
- **limine** — UEFI bootloader. Replaces systemd-boot in this design. Reasons: snapshot-rollback boot menu (via `limine-snapper-sync`), bootable-ISO-from-disk (Netac recovery), modern actively-developed. Config: `/boot/limine.conf` (single file). UEFI binary at `/boot/EFI/BOOT/BOOTX64.EFI`.
- **limine-snapper-sync** — AUR package that auto-regenerates limine entries from snapper snapshots. Means after a bad `pacman -Syu`, you can pick yesterday's snapshot at the boot menu and reboot — no chroot rescue needed.
- **systemd-boot** — Older minimal UEFI bootloader. We used to use it; replaced by limine for snapshot-rollback. Listed for context.
- **GRUB** — The big classic bootloader. We're not using it.
- **Secure Boot** — UEFI feature that verifies signed bootloaders. Disabled for install; re-enabled later with `sbctl`.
- **sbctl** — Tool to generate keys + sign kernel/bootloader for Secure Boot. Later-phase work.
- **TPM** (Trusted Platform Module) — Chip that stores encryption keys. BitLocker and LUKS can use it.
- **PCR** (Platform Configuration Register) — TPM slot that records a hash of the boot chain. You care: changing the bootloader can invalidate the PCRs BitLocker or LUKS bound to, forcing recovery-key/passphrase prompt. We bind to PCRs 0+7 (firmware + Secure Boot policy) because those are stable across kernel upgrades.
- **LUKS** / **LUKS2** (Linux Unified Key Setup) — Disk-encryption format for block devices. Our Samsung root btrfs and Netac /var ext4 both live inside LUKS2 containers. Keys land in numbered "slots" — slot 0 is the install-time passphrase, a later slot gets the TPM2 binding.
- **cryptsetup** — CLI for LUKS. `cryptsetup luksFormat` creates a container, `cryptsetup open <dev> <name>` unlocks it to `/dev/mapper/<name>`, `cryptsetup close <name>` tears it back down.
- **sd-encrypt** — mkinitcpio hook that reads `/etc/crypttab.initramfs` inside the initramfs and opens LUKS containers before `/` is mounted. Sits between `block` and `filesystems` in the HOOKS line.
- **crypttab** / **crypttab.initramfs** — `/etc/crypttab` is read post-init by systemd to unlock non-root encrypted volumes (ours: cryptvar + cryptswap). `/etc/crypttab.initramfs` is baked into the initramfs by `sd-encrypt` to unlock the root (cryptroot). Format: `<name> <device> <key-source> <options>`.
- **systemd-cryptenroll** — Binds a LUKS2 key slot to a TPM2 (or FIDO2 / PKCS#11) credential. We enroll BOTH `ArchRoot` and `ArchSwap` (per postinstall.sh §7.5). Re-run with `--wipe-slot=tpm2 …` if PCRs drift. The pacman post-upgrade hook `/etc/pacman.d/hooks/95-tpm2-reseal.hook` automates this on linux/limine/mkinitcpio updates.
- **tpm2_pcrallocate** — Selects which PCR banks (sha1/sha256) are ACTIVE. Intel PTT firmware on this Dell ships sha1-only; chroot.sh runs `tpm2_pcrallocate sha256:all+sha1:all` BEFORE any cryptenroll so seals land in sha256. Running this on an already-enrolled system WIPES seals — only run pre-enrollment.
- **Hibernate-ready cryptswap** — Persistent LUKS2 swap unlocked via TPM2 (same pattern as cryptroot). Lives in `/etc/crypttab.initramfs` so it opens before resume runs. Replaces the older `/dev/urandom` random-key swap which made hibernation impossible. Resume= cmdline param in `/boot/limine.conf` points at `/dev/mapper/cryptswap`.
- **AHCI** — Normal SATA mode. Required for Linux to see the drives as plain block devices. Flip from RAID in BIOS before install.
- **Ventoy** — USB tool that boots any ISO dropped onto the data partition. Menu pops up at boot.
- **VTOYEFI** — Ventoy's ~32 MB companion partition (boots the menu). Sibling of the data partition on the same stick.

## Filesystems

- **btrfs** (B-tree filesystem) — Copy-on-write filesystem with snapshots and subvolumes. You care: we use it as `/`, `/home`, `/.snapshots`.
- **Subvolume** — Nested mountable namespace inside btrfs. `@` = root, `@home` = home, `@snapshots` = snapshot storage.
- **snapper** — Automatic btrfs snapshots. Before/after pacman runs, hourly/daily timelines.
- **zstd** — Fast compression algorithm. Mount option `compress=zstd:3` trades a bit of CPU for 1.5-2× disk savings on text/code.
- **ext4** — Classic Linux filesystem. We use it for `/var/log` + `/var/cache` on the Netac.
- **NTFS** — Windows filesystem. We mount the Windows partition read-only at `/mnt/windows` for media access.

## Package management

- **pacman** — Arch's package manager. `sudo pacman -S foo`. You care: every official package comes through it.
- **pacstrap** — Installs a base Arch system into a mount point (`/mnt`). Used by phase 2.
- **makepkg** — Builds a package from a PKGBUILD. AUR helpers wrap this.
- **AUR** (Arch User Repository) — Community-contributed build recipes for things not in official repos. You care: `visual-studio-code-bin`, `microsoft-edge-stable-bin`, `awww-bin`, `matugen-bin`, `pinpam-git`, `claude-desktop-native` all live here.
- **yay** — AUR helper. Wraps `makepkg` + `pacman` so `yay -S foo` works regardless of source.
- **DKMS** (Dynamic Kernel Module Support) — Rebuilds out-of-tree kernel modules on kernel upgrade. You care: NVIDIA/Wacom/other vendor drivers use it. We avoid it by not installing NVIDIA.

## Authentication / secrets

- **PAM** (Pluggable Authentication Modules) — Linux's auth stack. TTY login, sudo, hyprlock all go through `/etc/pam.d/*` (greetd's stack is also kept current for the disabled-fallback case). The active user-facing stack is lid-aware: lid OPEN → fprintd primary, lid CLOSED → libpinpam primary, password is the unconditional final fallback (per postinstall.sh §7a).
- **pinpam / libpinpam.so** — TPM-backed PIN auth module from the AUR `pinpam-git` package. The PAM module name is literally `libpinpam.so` (NOT `pam_pinpam.so`); referencing the wrong name silently dlopen-fails and PAM treats it as a faulty module. PIN itself is set up via `pinutil setup`.
- **fprintd** / **libfprint** — Fingerprint daemon + library. `fprintd-enroll` to register a finger. Goodix 538C reader on this machine via the AUR `libfprint-goodix-53xc` package.
- **matugen** — Material You palette generator. Reads a wallpaper, derives a full color palette, renders templates → waybar CSS, Hyprland color vars, Ghostty theme, GTK CSS, Qt color scheme, etc. Templates at `~/.config/matugen/templates/`. Theme switch (dark/light) via `theme-toggle` script.
- **gnome-keyring** — Secret storage (SSH keys, passwords, browser credentials). Started lazily as a systemd user service / D-Bus activation. NOT auto-unlocked at TTY login (the bare-TTY `/etc/pam.d/login` doesn't include `pam_gnome_keyring.so`); first access — typically `bwu` reading the cached Bitwarden master password — triggers gnome-keyring's own unlock prompt, after which the keyring stays unlocked for the session.
- **Bitwarden** — Password manager. We use a self-hosted instance. Desktop app can also act as an SSH agent.
- **SSH agent** — Holds decrypted SSH keys in memory. Bitwarden desktop provides one at `~/.bitwarden-ssh-agent.sock`.

## Hardware — this laptop specifically

- **Intel UHD 620** — The CPU's integrated GPU. You care: this is the *only* GPU Linux uses.
- **NVIDIA MX250** — Dedicated GPU. Blacklisted. It only works with `nvidia-470xx` which lacks GBM, so Wayland can't use it.
- **Optimus** — NVIDIA's tech for switching between iGPU and dGPU on laptops. Not used; MX250 is off.
- **GBM** (Generic Buffer Manager) — API Wayland compositors use to allocate GPU buffers. You care: any driver that lacks GBM can't run Wayland.
- **iio-sensor-proxy** — Reads accelerometer/light sensors, exposes them via D-Bus. Used for auto-rotation in 2-in-1 mode. Deferred to phase 3.5.
- **Wacom / Intuos** — Pen tablet. Supported natively by the kernel's `wacom` driver. Deferred to phase 3.5.
- **DisplayLink** — USB-to-video tech. The dock's video ports need proprietary drivers. We use the dock for **Ethernet + USB only**; the external monitor goes via HDMI direct to the laptop.

## Windows-side (phase 1)

- **autounattend.xml** — Windows' answer file. Tells Setup what to do unattended: locale, partition, local account, OOBE settings.
- **WinPE** (Windows Preinstallation Environment) — The mini-OS that runs Windows Setup. You care: our diskpart + Samsung-detection PowerShell runs here.
- **OOBE** (Out-of-Box Experience) — The purple first-run wizard Windows 11 walks you through. We skip all of it.
- **Specialize** — Pass of Windows Setup that runs right after install, before OOBE. Good place for registry tweaks.
- **diskpart** — Windows partition tool. Scripted via `/s file.txt`. WinPE uses it.
- **robocopy** — Windows bulk file copy with resume/retry. `stage-ventoy.ps1` uses it.
- **BitLocker** — Full-disk encryption for Windows. TPM-backed. Disabled during install to avoid PCR recovery-key drama.
- **Fast Startup** — Windows hybrid hibernation/shutdown. Breaks dual-boot (NTFS stays "dirty" so Linux mounts read-only). We disable it in `Specialize.ps1`.

## Dev / app tooling

- **VSCode** (Visual Studio Code) — Editor. Installed from AUR (`visual-studio-code-bin`) — the binary, not the open-source `code` fork.
- **Edge** (Microsoft Edge) — Browser. Installed from AUR (`microsoft-edge-stable-bin`) for sync continuity with Windows.
- **Firefox** — Backup browser, not installed by default. `sudo pacman -S firefox`.
- **Remmina** — RDP/VNC client. Not installed by default. `sudo pacman -S remmina freerdp` when needed.
- **FreeRDP** — RDP protocol library. Backs Remmina.
- **Docker** / **docker-compose** / **docker-buildx** — Container tooling. User is in `docker` group, service enabled.
- **Node / npm / pnpm** — JavaScript runtime + package managers. Installed via `mise use -g node@lts` + npm's own pnpm.
- **Jupyter** — Python notebooks. Not installed by default; deferred.
- **Claude Code** — Anthropic's CLI. `npm install -g @anthropic-ai/claude-code`. You care: this is the whole point of the stack.

## Theme / fonts

- **matugen / Material You** — Wallpaper-derived dynamic palette. Replaces the prior fixed Catppuccin choice. Re-rendered on every wallpaper change (every 6h via the user systemd timer, or manually via `wallpaper-rotate`). Master dark/light flip via Super+Shift+T (`theme-toggle`).
- **Catppuccin Mocha** — Older fixed palette we used to ship. Replaced by matugen. Listed for context if you find legacy references in old branches/notes.
- **Bibata-Modern-Classic** — Cursor theme. Installed as `bibata-cursor-theme` (Xcursor format) — Hyprland renders via Xcursor as the fallback. The hyprcursor-native variant has no clean AUR package as of 2026-04; if you want it, postinstall §3 has the manual git-clone recipe (LOSEARDES77/Bibata-Cursor-hyprcursor).
- **Papirus-Dark** — Icon theme. Maximum app coverage of the modern flat-style themes.
- **Nerd Font** — Any font re-packaged with ~3000 extra icon glyphs. Required for Powerlevel10k prompt, LSD, eza, etc.
- **JetBrains Mono** — Default monospace font. JetBrains Mono Nerd Font is the installed variant.
- **FiraCode** — Alternative Nerd Font, installed but not default.

## Settings GUIs (reachable from `~/.local/bin/control-panel`)

The control-panel script (Super+,) is a fuzzel-launched menu that dispatches to these so you don't have to remember tool names:

- **nwg-displays** — Display config GUI (resolution, scale, position, rotation). Wayland-native.
- **nm-connection-editor** — NetworkManager full config GUI (Wi-Fi, VPN, ethernet). From `network-manager-applet` package; we install the binary but skip the tray applet.
- **overskride** — Bluetooth pairing/management GUI. GTK4/libadwaita, Wayland-native. Replaces the older blueman.
- **pavucontrol** — Audio mixer GUI: per-app volumes, output device routing, mic levels. Originally written for PulseAudio; works against PipeWire via the `pipewire-pulse` compat shim. (The PipeWire-native equivalent `pwvucontrol` was the original pick but its AUR build is still broken on Arch's wireplumber 0.5: pwvucontrol depends on the unmaintained `arcnmx/wireplumber.rs` crate, last commit 2024-09, pinned to the 0.4.x ABI. Tracking saivert/pwvucontrol#10 — re-evaluate when that closes and pwvucontrol lands in `extra`.)
- **mission-center** — Resource monitor (Task Manager equivalent). GTK4. The one piece a per-tool launcher misses — pairs with btop in the terminal.
- **pacseek** — TUI fuzzy package installer (pacman + AUR). Searchable, pull request-style preview.
- **nwg-look** — GTK theme manager (font, GTK theme, icon theme). Run on demand only — if you click Apply after matugen has rendered, nwg-look's settings win until next theme change.
- **qt5ct** / **qt6ct** — Qt theme managers. Set `QT_QPA_PLATFORMTHEME=qt6ct` in environment so Qt apps read the matugen-generated color scheme. `style=Fusion` (NOT kvantum — that requires extra packages).

## Misc / acronyms

- **COW** (Copy-On-Write) — btrfs's write strategy. Writes go to fresh blocks; old data only freed when no snapshot references it. Makes snapshots cheap and crash-safe.
- **TTY** (teletypewriter) — Text console. `Ctrl+Alt+F3` on Linux. See [SURVIVAL.md](SURVIVAL.md).
- **LSP** (Language Server Protocol) — How editors talk to per-language analyzers for autocomplete/diagnostics/goto-def. Helix uses it.
- **D-Bus** — IPC bus every Linux desktop app uses. iio-sensor-proxy, Bitwarden, greetd, PipeWire all communicate over it.
- **systemd** — The init system + service manager + timer runner + network stack + login manager + 40 other things. If a background service exists, `systemctl status foo` tells you about it.
- **CLI** (Command Line Interface) — Things you type commands at.
- **TUI** (Text User Interface) — CLI programs with full-screen text UI (btop, helix, nmtui). As opposed to line-oriented CLI.
- **IPC** (Inter-Process Communication) — How processes talk to each other. Hyprland's `hyprctl` is an IPC client.
- **dotfiles** — Config files in `~` that start with a dot (`.zshrc`, `.config/...`). Managed by `chezmoi` here.
