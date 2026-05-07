# arch-setup

Install automation for a single-OS Arch Linux setup on a Dell Inspiron 7786
2-in-1 (codename **Metis**). The repo contains decision records, two-phase
install scripts, post-install bootstraps, and Claude-coaching runbooks — no
application code.

User-level configuration (Hyprland, shell, themes, helper scripts) lives in
the companion repo **[rhombu5/dots](https://github.com/rhombu5/dots)** and is
applied by `postinstall.sh §13` via `chezmoi init --apply rhombu5/dots`.

## Install flow

| # | Phase | Environment | Entry point |
|---|---|---|---|
| 0 | Boot-medium prep | Any machine | Arch ISO → USB (Rufus / `dd`) |
| 0.5 | CLI shakedown (optional) | `archlinux` WSL distro | [`wsl-cli-test.sh`](wsl-cli-test.sh) |
| 2 | Arch install | Arch live USB | [`phase-2-arch-install/install.sh`](phase-2-arch-install/install.sh) |
| 3 | Post-install / teaching | Booted Arch as `tom` | [`phase-3-arch-postinstall/postinstall.sh`](phase-3-arch-postinstall/postinstall.sh) |
| 3.5 | 2-in-1 hardware wiring (deferred) | Booted Arch | [`runbook/phase-3.5-hardware-handoff.md`](runbook/phase-3.5-hardware-handoff.md) |

End-to-end from bare laptop:

1. Write the Arch ISO to USB; verify against upstream `sha256sums.txt`.
2. F2 BIOS → SATA = AHCI, Secure Boot OFF. F12 → boot the USB.
3. From the live shell: `iwctl` for Wi-Fi, then
   `git clone https://github.com/fnrhombus/arch-setup /tmp/arch-setup && bash /tmp/arch-setup/phase-2-arch-install/install.sh`.
4. Reboot into Arch, log in as `tom`, run `~/postinstall.sh`.

## What gets set up

Comprehensive inventory of everything `install.sh`, `chroot.sh`, and
`postinstall.sh` configure on the target machine. User-level dotfiles applied
later by chezmoi are catalogued separately in the
[dots README](https://github.com/rhombu5/dots#readme).

### Disk, boot, and kernel

- **Partition layout** (Samsung SSD 840 PRO 512 GB only — Netac untouched)
  - EFI System Partition (1 GiB, FAT32, mounted at `/boot`)
  - LUKS2 root partition (~475 GiB, single volume — designed for `dd`-style migration)
- **btrfs subvolumes** on `cryptroot`: `@`, `@home`, `@snapshots`, `@swap`
  - Mount options: `noatime,compress=zstd:3,space_cache=v2,ssd`
  - 16 GiB NoCOW swapfile on `@swap` (hibernation-ready, `resume_offset` captured at install)
- **Bootloader: limine** (replaced systemd-boot 2026-04-22)
  - UEFI fallback at `/boot/EFI/BOOT/BOOTX64.EFI` + NVRAM entry
  - `/boot/limine.conf` chainloads UKIs; `memtest86+` entry added by postinstall
- **Unified Kernel Images** (`linux`, `linux-lts`) at `/boot/EFI/Linux/`
  - Built by `mkinitcpio` in UKI mode (`/etc/kernel/uki.conf`, `/etc/kernel/cmdline`)
  - HOOKS: `base systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck`
  - `MODULES=(btrfs)` explicit
- **Pacman hooks** for boot integrity
  - `95-limine-redeploy.hook` — re-deploy + re-sign limine on package upgrade
  - `95-tpm2-reseal.hook` — re-enroll TPM2 LUKS seal on `linux`/`mkinitcpio`/`systemd`/`limine`/`sbctl` upgrades
  - `zz-sbctl.hook` (shipped with sbctl) — keep signed binaries signed across upgrades

### Security and authentication

- **TPM2 LUKS sealing** (BitLocker-parity model — see [`docs/tpm-luks-bitlocker-parity.md`](docs/tpm-luks-bitlocker-parity.md))
  - TPM cleared at install; SHA-256 PCR bank allocated (falls back to SHA-1 on hardware that can't expose SHA-256, e.g. this Inspiron)
  - Stage 1 (install): signed PCR 11 policy (covers initrd UKI self-measurement)
  - Stage 2 (postinstall §7.5): PCR 7 binding layered on top
  - Signing keypair: `/etc/systemd/tpm2-pcr-{private,public}.pem`
  - Auto re-seals across kernel/firmware updates via the pacman hook above
- **48-digit LUKS recovery key** auto-generated, BitLocker-style display (red banner, photo-and-typeback gate)
- **Secure Boot scaffolding** (pre-staged, manual BIOS enrollment)
  - `sbctl` keypair at `/var/lib/sbctl/keys/`
  - Signed binaries: limine fallback + source copy, both UKIs
  - `.auth` files at `/boot/EFI/sbctl-keys/{PK,KEK,db}.auth` for BIOS file-load
- **PIN auth (TPM-backed)** via the `pinpam-fnrhombus` fork
  - PIN stored in TPM NVRAM; 6+ digits; user-scoped (must run `pinutil` as `tom`)
  - `libpinpam.so` wired into PAM stacks alongside fingerprint and password
- **Fingerprint auth** via `fprintd` + `libfprint-goodix-53xc` (Goodix 538C, Match-on-Chip)
  - Five fingers enrolled idempotently in §7
  - Concurrent finger / typed-input race via `pam-fprint-grosshack-fnrhombus`
- **PAM stacks** (rewritten by postinstall §7a)
  - `sudo`, `hyprlock`, `polkit-1`, `physlock` — concurrent fingerprint + PIN + password
  - `login` — fingerprint + password only (no PIN at cold-boot, per design)
- **Firewall**: `ufw` — default deny incoming, allow outgoing, `22/tcp` open
- **SSH**: `sshd_config.d` hardening — no root login, no password auth, `AllowUsers tom`, X11 forwarding off
- **Bitwarden-backed SSH agent** — keys live in self-hosted Vaultwarden;
  socket at `~/.bitwarden-ssh-agent.sock`; git commit signing via SSH

### Base system

- Hostname `metis`, locale `en_US.UTF-8`, keymap `us`, timezone `America/New_York`
- RTC = UTC (`/etc/adjtime`) — single-OS, no Windows offset
- User `tom` in `wheel,video,audio,input,storage`, login shell `zsh`
- `wheel` group has sudo (sudoers uncommented)
- Pre-seeded NetworkManager profiles for home/work Wi-Fi SSIDs
- `pacman.conf` — colour, verbose, parallel downloads, `ILoveCandy`
- Journald capped at 200 MB / 50 MB per file

### Login and desktop session

- **Login surface: bare TTY** on `tty1` (active path)
  - `~/.zprofile` execs `uwsm start hyprland-uwsm.desktop`
  - `numlock-on.service` enables NumLock before login
  - `logind.conf.d/10-lid.conf` delegates lid handling to the user session
- **greetd + ReGreet** — installed but **disabled** (kept inert as a recoverable fallback;
  see memory note `project_greetd_not_in_use.md`)
- Hyprland session entry shipped by the `hyprland` pacman package; configs come from `rhombu5/dots` via chezmoi

### Pacman packages (pacstrap + postinstall §1)

Grouped by purpose. Full list lives in `install.sh`/`chroot.sh`/`postinstall.sh`.

- **Core** — `base`, `base-devel`, `linux`, `linux-lts`, `linux-firmware`, `intel-ucode`, kernel headers
- **Storage / FS** — `btrfs-progs`, `e2fsprogs`, `dosfstools`, `snapper`, `snap-pac`, `smartmontools`
- **Boot / EFI / SB** — `efibootmgr`, `limine`, `systemd-ukify`, `python-pefile`, `sbsigntools`, `sbctl`, `efitools`, `memtest86+`, `memtest86+-efi`
- **TPM** — `tpm2-tss`, `tpm2-tools`
- **Network** — `networkmanager`, `iwd`, `wpa_supplicant`, `openssh`, `bind`, `inetutils`, `ufw`, `network-manager-applet`
- **Audio** — `pipewire`, `pipewire-pulse`, `pipewire-jack`, `wireplumber`, `pavucontrol`
- **Bluetooth** — `bluez`, `bluez-utils`, `blueman`
- **Compositor / portals** — `hyprland`, `hyprlock`, `hypridle`, `hyprpolkitagent`, `hyprpicker`, `uwsm`, `xdg-desktop-portal-hyprland`, `xdg-desktop-portal-gtk`, `polkit`
- **Desktop shell / UI** — `waybar`, `swaync`, `swayosd`, `fuzzel`, `cliphist`, `wl-clipboard`, `grim`, `slurp`, `satty`, `hyprshot`
- **File managers / viewers** — `nautilus`, `yazi`, `imv`, `zathura`, `zathura-pdf-poppler`, `vlc`
- **Terminal / editors** — `ghostty`, `helix`, `vim`, `tmux`, `zsh`
- **CLI utilities** — `bat`, `fd`, `ripgrep`, `eza`, `lsd`, `btop`, `jq`, `fzf`, `zoxide`, `direnv`, `sd`, `go-yq`, `xh`, `tldr`, `pkgfile`, `man-db`, `man-pages`
- **Fonts / icons** — `noto-fonts`, `noto-fonts-emoji`, `ttf-jetbrains-mono-nerd`, `ttf-firacode-nerd`, `ttf-material-symbols-variable`, `terminus-font`, `papirus-icon-theme`
- **Theming** — `nwg-look`, `nwg-displays`, `qt5ct`, `qt6ct`
- **2-in-1 hardware** — `iio-sensor-proxy`, `libwacom`, `wtype`
- **Containers** — `docker`, `docker-compose`, `docker-buildx`, `nvidia-container-toolkit`, `waydroid`
- **Remote** — `remmina`, `freerdp`, `dialog`, `openbsd-netcat`
- **Cloud / DNS / certs** — `azure-cli`, `lego`, `rclone`
- **Dev tooling** — `mise`, `chezmoi`, `github-cli`, `cmake`, `cpio`, `git`, `curl`, `wget`
- **Printing** — `cups`, `cups-pdf`, `cups-filters`, `gutenprint`, `foomatic-db`, `foomatic-db-engine`, `ghostscript`, `system-config-printer`, `usbutils`
- **Secrets** — `bitwarden`, `bitwarden-cli`
- **Graphics** — `mesa`, `intel-media-driver`, `vulkan-intel`, `libva-intel-driver` (NVIDIA display deliberately blacklisted — see below)
- **Misc** — `mission-center`, `udiskie`, `xdg-user-dirs`, `man-db`, `texinfo`

### AUR packages (postinstall §3, via yay)

- **IDEs / browsers** — `visual-studio-code-bin`, `microsoft-edge-stable-bin`, `claude-desktop-native`
- **Hyprland ecosystem** — `iio-hyprland-git`, `hyprmural`, `matugen-bin`, `wleave`, `hyprshutdown`, `physlock`, `awww-bin` (swww successor)
- **Cursors / fonts** — `bibata-cursor-theme`, `ttf-nerd-fonts-meta`
- **Cloud / sync** — `dropbox`, `dropbox-cli`
- **Touch / 2-in-1** — `wvkbd` (mobintl on-screen keyboard)
- **Terminal / shell** — `sesh-bin`, `powershell-bin`
- **Bluetooth** — `overskride`
- **Pacman / boot** — `pacseek`, `limine-snapper-sync`
- **NVIDIA compute (display blacklisted)** — `nvidia-470xx-dkms`, `nvidia-470xx-utils` (CUDA only — MX250 Pascal can't drive Wayland)
- **Forked / pinned** (in `phase-3-arch-postinstall/aur-overrides/`)
  - `pinpam-fnrhombus` — adds `try_first_pass` / `use_first_pass` for concurrent PIN auth
  - `pam-fprint-grosshack-fnrhombus` — fixes the sudo retry-loop SIGUSR1 race
- **Built from upstream source** — `azure-ddns` (PKGBUILD from `fnrhombus/azure-ddns`), WinApps (`/opt/winapps`)

### Services enabled

- **System** — `systemd-timesyncd`, `NetworkManager`, `bluetooth`, `fprintd`, `fstrim.timer`, `smartd`, `sshd`, `ufw`, `cups.socket`, `docker`, `waydroid-container`, `numlock-on`, `lego-renew.timer`, `azure-ddns.timer`
- **User (`tom`)** — `hyprpolkitagent`, `wallpaper-rotate.timer`, `tablet-mode-watcher`, `rclone-gdrive-bisync.timer`, `dropbox` (the latter two stay no-op until first-login planters auth them)
- **Disabled / masked**
  - `greetd.service` — disabled (TTY login active)
  - `systemd-tpm2-setup.service` — masked (benign unseal failure on fresh install)
  - `keyd.service` — disabled (leftover from super-tap-to-launcher experiment)

### System files dropped to `/etc`, `/usr`, `/boot`

Configuration written by `chroot.sh` and `postinstall.sh` (sources under
[`phase-3-arch-postinstall/system-files/`](phase-3-arch-postinstall/system-files/)):

- **Disk / boot** — `/etc/fstab`, `/etc/crypttab.initramfs`, `/etc/kernel/{uki.conf,cmdline}`, `/etc/mkinitcpio.conf`, `/etc/mkinitcpio.d/{linux,linux-lts}.preset`, `/boot/limine.conf`
- **Locale / time** — `/etc/localtime`, `/etc/locale.{gen,conf}`, `/etc/vconsole.conf`, `/etc/adjtime`, `/etc/hostname`, `/etc/hosts`
- **Hardware quirks**
  - `/etc/modprobe.d/blacklist-nvidia.conf` — display modules blacklisted, CUDA modules allowed
  - `/etc/modprobe.d/rtl8723be.conf` — `aspm=0 ant_sel=2 fwlps=N ips=N` (PCIe AER storm fix)
- **Login / session** — `/etc/systemd/logind.conf.d/10-lid.conf`, PAM stacks (`sudo`, `hyprlock`, `polkit-1`, `physlock`, `login`, `greetd`)
- **Network** — `/etc/NetworkManager/system-connections/*.nmconnection` (pre-seeded Wi-Fi)
- **Pacman** — `/etc/pacman.conf` + the three hooks above in `/etc/pacman.d/hooks/`
- **journald** — `/etc/systemd/journald.conf.d/10-size.conf`
- **Bluetooth** — `/etc/bluetooth/main.conf` (`AutoEnable=true`)
- **SSH** — `/etc/ssh/sshd_config.d/10-arch-setup.conf`
- **Firewall** — UFW default rules
- **greetd (inert)** — `/etc/greetd/{config.toml,regreet.toml,wallpaper.jpg,regreet.css}`
- **Snapper** — `/etc/snapper/configs/root`, `/etc/conf.d/snapper`
- **Crypto / TPM** — `/etc/systemd/tpm2-pcr-{private,public}.pem`
- **DDNS / TLS** — `/etc/azure-ddns.env`, `/etc/lego/lego.env` (mode 600), `/etc/systemd/system/lego-renew.{service,timer}`
- **udev** — `/etc/udev/rules.d/99-usb-serial.rules` (CP210x, CH340, RP2040, FTDI)
- **Helper binaries** — `/usr/local/sbin/limine-redeploy`, `/usr/local/sbin/tpm2-reseal-luks`

### User-level setup (still inside this repo, before chezmoi takes over)

- yay built from source, `tom` owned
- zgenom cloned, plugins pre-built (mirrors the list in `wsl-cli-test.sh`)
- mise installed; Node LTS pulled to bootstrap Claude Code
- chezmoi clones `rhombu5/dots` (HTTPS at install, switches to SSH after first apply)
- Bitwarden Desktop pre-seeded with self-hosted server URL + tray behaviour
- Fingerprint enrollment (5 fingers, idempotent)
- §7.5 stage-2 PCR 7 reseal (one passphrase prompt; silent thereafter)
- SSH `~/.ssh/config` wired to Bitwarden agent socket; `authorized_keys` seeded
- `~/.local/share/arch-setup-bootstraps/` — first-login planters (self-deleting):
  - `first-login.sh` — `bw login` + `gh auth login`
  - `ssh-signing.sh` — pull SSH pubkey from Bitwarden, set `allowedSignersFile`
  - `cloud-storage-auth.sh` — Dropbox + rclone bisync setup
  - `callisto-rdp.sh` — Callisto RDP password into GNOME keyring for Remmina

### Ancillary one-shots

- **[`setup-azure-ddns.sh`](phase-3-arch-postinstall/setup-azure-ddns.sh)** — creates / rotates the `metis-ddns` Azure SP, assigns DNS Zone Contributor on `rhombus.rocks`, writes credential envfiles, issues first Let's Encrypt cert via `lego`
- **Windows VM** (optional, `--skip-windows-install` to opt out)
  - `dockur/windows` compose stack at `/etc/dockur-windows/`
  - Win11 + VS Enterprise unattended install via OEM scripts
  - WinApps cloned to `/opt/winapps` for seamless RDP integration

## Repo layout

| Path | What it is |
|---|---|
| [`docs/`](docs/) | Decisions, requirements, hardware investigation — read when editing |
| [`runbook/`](runbook/) | Coaching docs for the Claude session that walks the user through install |
| [`phase-2-arch-install/`](phase-2-arch-install/) | Live-ISO installer + chroot script |
| [`phase-3-arch-postinstall/`](phase-3-arch-postinstall/) | First-boot script, system-files, AUR overrides, planters |
| [`scripts/`](scripts/) | Dev-machine helpers (runbook PDF render) |
| [`wsl-setup.sh`](wsl-setup.sh), [`wsl-cli-test.sh`](wsl-cli-test.sh) | Optional Phase 0.5 CLI shakedown inside Arch WSL |
| [`CLAUDE.md`](CLAUDE.md) | Per-repo instructions for Claude Code sessions |

## Companion repo

User-level configuration — Hyprland configs, helper scripts, theming
pipeline, shell environment, app configs — lives in
**[rhombu5/dots](https://github.com/rhombu5/dots)**.

`postinstall.sh §13` runs `chezmoi init --apply rhombu5/dots` to bring it in.

## Caveats

- **Single-OS only.** Windows dual-boot was dropped 2026-04-27. RTC is UTC.
- **No NVIDIA on Wayland** — MX250 Pascal requires `nvidia-470xx`, which lacks GBM. Display is iGPU-only; NVIDIA loads for CUDA compute only.
- **Netac SSD is left alone** — slated for replacement, deliberately untouched by `install.sh`.
- The TPM2 SHA-256 PCR bank is unusable on this Inspiron's firmware — `cryptenroll` falls back to SHA-1. Hardware limitation, not a bug.
