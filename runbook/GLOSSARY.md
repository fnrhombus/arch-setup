# GLOSSARY.md

Every tool, term, and package that shows up in [docs/decisions.md](../docs/decisions.md), [phase-3-handoff.md](phase-3-handoff.md), and [phase-3-arch-postinstall/postinstall.sh](../phase-3-arch-postinstall/postinstall.sh) that isn't obvious on sight. Each entry: **full name** — what it does — when you'd care.

Organized by category so you can skim. Nothing here is install instructions — those are in the runbook.

---

## Graphical stack

- **Wayland** — Modern display protocol replacing X11/Xorg. You care: Hyprland is Wayland-only, so every GUI app either speaks Wayland natively or falls back through `xwayland`. Apps that misbehave are usually legacy X11 apps that didn't fall back cleanly.
- **Xorg / X11** — The old display server. You care: some apps (especially older Electron builds, Wine, GIMP) still prefer it; `xwayland` runs them on Wayland.
- **Compositor** — The thing that draws windows on screen under Wayland. Hyprland is a compositor and window manager rolled into one.
- **Hyprland** — The compositor we chose. Tiling, keyboard-driven, GPU-accelerated effects. You care: *every* GUI session you have will be running in Hyprland.
- **end-4 / illogical-impulse** — A pre-built Hyprland configuration (dotfiles) that gives you a full desktop out of the box. You care: this is our starting config. All your keybinds, animations, bar, launcher, etc. come from here.
- **SDDM** (Simple Desktop Display Manager) — The login screen you see on boot. Wayland-native, themeable. You care: fingerprint login happens here.
- **GDM / LightDM** — Alternatives to SDDM from GNOME / the XFCE world. We don't use them; ignore.

## Wayland ecosystem utilities

- **Waybar** — Top/bottom bar (taskbar, clock, battery, audio). You care: it's always on screen.
- **swaync** (Sway Notification Center) — Toast notifications + a history/DND panel. You care: when a notification appears, this drew it.
- **fuzzel** — App launcher. Wayland-native, fuzzy-matching. You care: this is what opens when you hit the launcher key.
- **rofi-wayland** — More-featured alternative launcher with scripting (calculator, emoji, SSH picker). You care: not installed by default, only if fuzzel turns out too minimal.
- **hyprshot** — Screenshot tool built for Hyprland (region/window/monitor). Plays the role `grimblast` plays on sway.
- **satty** (Screenshot Annotation Tool) — Post-capture annotation: arrows, boxes, blur, text. You care: `hyprshot | satty` gives you Snipping-Tool-level UX.
- **wl-clipboard** — `wl-copy` / `wl-paste` command-line clipboard utilities. You care: scripts and Claude Code use these to read/write the clipboard.
- **cliphist** — Clipboard history daemon. Stores text + image clips, picker via fuzzel.
- **wlogout** — Graphical logout/shutdown/reboot menu. Not installed by default — end-4/dots-hyprland ships its own power menu; install `wlogout` only if you want a swap-in replacement.

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
- **systemd-boot** — Minimal UEFI bootloader. Reads `.conf` files from the ESP. You care: adding a kernel/Windows/recovery entry = dropping a file here.
- **GRUB** — The big classic bootloader. We're not using it — systemd-boot is simpler.
- **Secure Boot** — UEFI feature that verifies signed bootloaders. Disabled for install; re-enabled later with `sbctl`.
- **sbctl** — Tool to generate keys + sign kernel/bootloader for Secure Boot. Later-phase work.
- **TPM** (Trusted Platform Module) — Chip that stores encryption keys. BitLocker and LUKS can use it.
- **PCR** (Platform Configuration Register) — TPM slot that records a hash of the boot chain. You care: changing the bootloader can invalidate the PCRs BitLocker or LUKS bound to, forcing recovery-key/passphrase prompt. We bind to PCRs 0+7 (firmware + Secure Boot policy) because those are stable across kernel upgrades.
- **LUKS** / **LUKS2** (Linux Unified Key Setup) — Disk-encryption format for block devices. Our Samsung root btrfs and Netac /var ext4 both live inside LUKS2 containers. Keys land in numbered "slots" — slot 0 is the install-time passphrase, a later slot gets the TPM2 binding.
- **cryptsetup** — CLI for LUKS. `cryptsetup luksFormat` creates a container, `cryptsetup open <dev> <name>` unlocks it to `/dev/mapper/<name>`, `cryptsetup close <name>` tears it back down.
- **sd-encrypt** — mkinitcpio hook that reads `/etc/crypttab.initramfs` inside the initramfs and opens LUKS containers before `/` is mounted. Sits between `block` and `filesystems` in the HOOKS line.
- **crypttab** / **crypttab.initramfs** — `/etc/crypttab` is read post-init by systemd to unlock non-root encrypted volumes (ours: cryptvar + cryptswap). `/etc/crypttab.initramfs` is baked into the initramfs by `sd-encrypt` to unlock the root (cryptroot). Format: `<name> <device> <key-source> <options>`.
- **systemd-cryptenroll** — Binds a LUKS2 key slot to a TPM2 (or FIDO2 / PKCS#11) credential. `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/disk/by-partlabel/ArchRoot` after Phase 3 is what makes boot silent. Re-run with `--wipe-slot=tpm2` if PCRs drift.
- **Random-key swap** — `/dev/urandom` as the crypttab key source, combined with the `swap` option, re-mkswaps the mapper device with a fresh random key on every boot. Means hibernation is impossible (keys die at shutdown), which is fine here — battery is dead.
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
- **AUR** (Arch User Repository) — Community-contributed build recipes for things not in official repos. You care: `visual-studio-code-bin`, `microsoft-edge-stable-bin`, end-4 dotfiles all live here.
- **yay** — AUR helper. Wraps `makepkg` + `pacman` so `yay -S foo` works regardless of source.
- **DKMS** (Dynamic Kernel Module Support) — Rebuilds out-of-tree kernel modules on kernel upgrade. You care: NVIDIA/Wacom/other vendor drivers use it. We avoid it by not installing NVIDIA.

## Authentication / secrets

- **PAM** (Pluggable Authentication Modules) — Linux's auth stack. Login, sudo, SDDM, screen lockers all go through `/etc/pam.d/*`. You care: fingerprint integration means adding a `pam_fprintd.so` line.
- **fprintd** / **libfprint** — Fingerprint daemon + library. `fprintd-enroll` to register a finger.
- **gnome-keyring** — Secret storage (SSH keys, passwords, browser credentials). Unlocked by your login password.
- **Bitwarden** — Password manager. We use a self-hosted instance. Desktop app can also act as an SSH agent.
- **SSH agent** — Holds decrypted SSH keys in memory. Bitwarden desktop provides one at `~/.bitwarden-ssh-agent.sock`.
- **keychain** — Alternative SSH/GPG key manager. Not installed — Bitwarden's agent replaces it.

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
- **robocopy** — Windows bulk file copy with resume/retry. `stage-usb.ps1` uses it.
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

- **Catppuccin Mocha** — Color palette we apply everywhere (terminal, editor, bar, GTK, Qt, SDDM, browser). Pastel-on-dark.
- **Nerd Font** — Any font re-packaged with ~3000 extra icon glyphs. Required for Powerlevel10k prompt, LSD, eza, etc.
- **JetBrains Mono** — Default monospace font. JetBrains Mono Nerd Font is the installed variant.
- **FiraCode / Cascadia / Hack / MesloLGS** — Alternative Nerd Fonts, installed but not default.

## Misc / acronyms

- **COW** (Copy-On-Write) — btrfs's write strategy. Writes go to fresh blocks; old data only freed when no snapshot references it. Makes snapshots cheap and crash-safe.
- **TTY** (teletypewriter) — Text console. `Ctrl+Alt+F3` on Linux. See [SURVIVAL.md](SURVIVAL.md).
- **LSP** (Language Server Protocol) — How editors talk to per-language analyzers for autocomplete/diagnostics/goto-def. Helix uses it.
- **D-Bus** — IPC bus every Linux desktop app uses. iio-sensor-proxy, Bitwarden, SDDM, PipeWire all communicate over it.
- **systemd** — The init system + service manager + timer runner + network stack + login manager + 40 other things. If a background service exists, `systemctl status foo` tells you about it.
- **CLI** (Command Line Interface) — Things you type commands at.
- **TUI** (Text User Interface) — CLI programs with full-screen text UI (btop, helix, nmtui). As opposed to line-oriented CLI.
- **IPC** (Inter-Process Communication) — How processes talk to each other. Hyprland's `hyprctl` is an IPC client.
- **dotfiles** — Config files in `~` that start with a dot (`.zshrc`, `.config/...`). Managed by `chezmoi` here.
