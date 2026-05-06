# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **planning and install-automation repository** for a single-OS Arch Linux install on a Dell Inspiron 7786 (2-in-1 laptop). It contains no application code — only decision records, install scripts (Phase 2 + Phase 3), a handoff guide for post-install Claude sessions, and a shakedown WSL test for the CLI stack (zsh/tmux/helix/zgenom).

Git remote: `git@github.com:fnrhombus/arch-setup.git`. Owner: `fnrhombus`.

**Single-OS, single-disk:** Arch only on the Samsung 512 GB SSD. Windows dual-boot was originally planned and dropped 2026-04-27 (the saga lives in the commit log). The Netac 128 GB SSD (slated for replacement) is left untouched; the design puts everything on a single LUKS partition so SSD migration is a one-line `dd`.

**Repo scope (locked-in 2026-04-27):** this repo is **OS setup automation only**. Phase 2 install scripts, Phase 3 postinstall, hardware/decisions docs, runbook. **Anything user-config-shaped goes in [rhombu5/dots](https://github.com/rhombu5/dots)** — the chezmoi source tree (Hyprland configs, matugen templates, helper scripts under `~/.local/bin/`, shell rc files, validate-hypr-binds CI). Postinstall.sh §13 fetches and applies it via `chezmoi init --apply rhombu5/dots`.

When considering a new file, ask: *would this belong in `~/.config/`, `~/.local/bin/`, or a per-user shell file?* If yes → rhombu5/dots. If it's an Arch install step or a phase-script, it stays here.

## Bootstrap phases

This repo's deliverables map to these phases. [docs/decisions.md](docs/decisions.md) is the single source of truth — if any artifact disagrees with it, the artifact is wrong.

| # | Phase | Environment | Entry point(s) |
|---|---|---|---|
| 0 | Boot-medium prep (on any machine) | Windows + Rufus, or Linux + `dd` | Download the latest Arch ISO, write to a USB stick. No staging script — single ISO, no repo mirror needed (we `git clone` from the live ISO). |
| 0.5 | CLI-stack shakedown (optional) | `archlinux` WSL distro on the user's current machine | [wsl-setup.sh](wsl-setup.sh) → [wsl-cli-test.sh](wsl-cli-test.sh) |
| 2 | Arch install | Booted from Arch live USB | [phase-2-arch-install/install.sh](phase-2-arch-install/install.sh) → [phase-2-arch-install/chroot.sh](phase-2-arch-install/chroot.sh) |
| 3 | Arch post-install / teaching | Booted Arch, logged in as `tom` | [phase-3-arch-postinstall/postinstall.sh](phase-3-arch-postinstall/postinstall.sh). [runbook/phase-3-handoff.md](runbook/phase-3-handoff.md) briefs the next Claude session. |
| 3.5 | 2-in-1 hardware wiring (deferred) | Booted Arch | [runbook/phase-3.5-hardware-handoff.md](runbook/phase-3.5-hardware-handoff.md) |

Phase 2 only touches the Samsung SSD 840 PRO 512GB; everything else (Netac etc.) is left untouched.

End-to-end flow from a bare laptop:
1. Download the Arch ISO from archlinux.org, write to a USB stick (Rufus on Windows, `dd if=archlinux-x86_64.iso of=/dev/sdX bs=4M status=progress conv=fsync` on Linux). Verify against the upstream `sha256sums.txt`.
2. F2 BIOS → SATA = AHCI, Secure Boot = OFF (re-enable later via sbctl). F12 → boot the USB.
3. From the Arch live shell: `iwctl` to connect Wi-Fi, then `git clone https://github.com/fnrhombus/arch-setup /tmp/arch-setup && bash /tmp/arch-setup/phase-2-arch-install/install.sh`. Root + tom passwords prompted up front; the LUKS recovery key is auto-generated BitLocker-style (48 digits, displayed with loud banner, strict type-back required). pacstrap + chroot run unattended.
4. First boot into Arch — silent if TPM2 enrollment succeeded at install time. Log in as `tom`, run `~/postinstall.sh`.

## Repo layout

Markdown files split into two groups by audience:

- **[docs/](docs/)** — Planning and rationale. Read when editing the project; the source of truth for design decisions.
- **[runbook/](runbook/)** — Claude-coaching docs. The user does NOT print or follow a runbook — they have a Claude session to coach them through. These files brief that Claude session: phase-3 hands off post-install teaching, phase-3.5 lists deferred 2-in-1 hardware work, GLOSSARY + SURVIVAL are reference material.

Everything else at the repo root is a deliverable the install consumes (phase scripts) or dev-machine plumbing (`package.json`, `.mise.toml`, `scripts/`).

## File roles

### docs/ — planning / rationale (dev machine)
- [docs/decisions.md](docs/decisions.md) — Locked-in decisions with rationale: hardware spec, partition plan, Hyprland, **limine** (replaced systemd-boot 2026-04-22), yay, Ghostty, **bare TTY login** (greetd + ReGreet replaced SDDM 2026-04-22, then disabled in favour of bare TTY 2026-04-30 — see §D), PipeWire, **matugen / Material You** (replaced Catppuccin), chezmoi, etc. **Edit this when a decision changes** — don't let it drift from the other docs.
- [docs/desktop-requirements.md](docs/desktop-requirements.md) — Full spec for the bare-Hyprland + chezmoi-managed approach (matugen pipeline, manual hibernate workflow, GTK-CSS pipeline end to end, keybind philosophy, workspace strategy). Source of truth for the *implementation* of what decisions.md decided.
- [docs/tpm-luks-bitlocker-parity.md](docs/tpm-luks-bitlocker-parity.md) — Full design of the LUKS+TPM seal: signed-PCR-11 policy at install time + stage-2 PCR 7 binding from postinstall. Trust-anchor shift, threat model, recovery procedures.
- [docs/wsl-setup-lessons.md](docs/wsl-setup-lessons.md) — Hard-won WSL pitfalls harvested from a prior `fnwsl` repo (MTU 1350 before any network op, `GIT_TEMPLATE_DIR=""` on every clone, `ZGEN_DIR` must be set before sourcing zgenom, never use raw.githubusercontent.com, etc.). **Consult before touching any setup script** — these gotchas are silent and expensive.

### runbook/ — Claude-coaching handoffs
- [runbook/phase-3-handoff.md](runbook/phase-3-handoff.md) — The document fed to the next Claude session *inside Arch after install*. Describes the user, hardware, installed stack, and what Claude is expected to teach (Hyprland, Helix, tmux). Keep in sync with `docs/decisions.md`.
- [runbook/phase-3.5-hardware-handoff.md](runbook/phase-3.5-hardware-handoff.md) — Handoff between phases 3 and 4 — tracks which requirements in `docs/decisions.md` still need fingerprint/pen/tablet/RDP validation on real hardware.
- [runbook/GLOSSARY.md](runbook/GLOSSARY.md) — Every non-obvious tool/utility/package that shows up in decisions.md + postinstall.sh, with a brief full-name / what-it-does / when-you-care blurb.
- [runbook/SURVIVAL.md](runbook/SURVIVAL.md) — Minimum-viable rescue card. What to do if the desktop is broken or Claude isn't running: TTY login, Wi-Fi from `iwctl`, launch a terminal/browser, start Claude.

### Phase 0 — boot-medium prep
- [package.json](package.json) — Minimal pnpm wrapper. Two scripts: `prepare` (wires up the git pre-commit hook) and `pdf` (renders `runbook/*.md` → PDFs). Phase 0 is otherwise tool-free: download the Arch ISO from archlinux.org, write to USB with Rufus or `dd`. No staging script, no Ventoy.
- [scripts/runbook-pdf.mjs](scripts/runbook-pdf.mjs) — `pnpm pdf` entry point. Renders every `runbook/*.md` → `runbook/<name>.pdf` via `marked` + Edge headless (`--print-to-pdf`). 5.5"×8.5" pages, 0.5" margins, 12pt body.
- [assets/](assets/) — Directory where the Arch ISO can be cached if you want a local copy (not required — the live USB is enough). `.gitignore` covers the ISO + sigs + sumfile so they never get committed.

### Phase 2 — Arch install
- [phase-2-arch-install/install.sh](phase-2-arch-install/install.sh) — Main installer. Runs from the Arch live ISO. Auto-detects the Samsung by size (450-520 GiB), full-disk wipe, EFI 1 GiB + LUKS2 partition layout, generates a 48-digit recovery key (BitLocker-style), enrolls TPM2 against a signed-PCR-11 policy, mkfs.btrfs + subvolumes (@/@home/@snapshots/@swap), creates a 16 GiB NoCOW swapfile and captures its `resume_offset`, pacstraps, then calls `chroot.sh`.
- [phase-2-arch-install/chroot.sh](phase-2-arch-install/chroot.sh) — Inside `arch-chroot /mnt`. Consumes the pre-hashed passwords, sets timezone + locale, creates user `tom`, allocates TPM2 SHA-256 PCR bank, installs **limine** (UEFI binary to ESP fallback path + NVRAM entry + `/boot/limine.conf` chainloading the UKIs), configures mkinitcpio in UKI mode + `/etc/kernel/uki.conf` (signed-PCR-11) + `/etc/kernel/cmdline` (with `resume_offset=`), installs **greetd + greetd-regreet** (system-files at `phase-3-arch-postinstall/system-files/{greetd,pam.d}/` — greetd is enabled here but postinstall §1f disables it in favour of bare TTY login; packages stay as a recoverable fallback), writes `/etc/crypttab.initramfs` (single cryptroot entry), pacman post-upgrade reseal hook, wires greetd PAM for gnome-keyring + fprintd (kept current for the fallback case), seeds Wi-Fi profiles, enables services.

### Phase 3 — Arch post-install
- [phase-3-arch-postinstall/postinstall.sh](phase-3-arch-postinstall/postinstall.sh) — First-boot script run as `tom`. Installs yay, AUR packages (VSCode, Edge), zgenom + plugins, chezmoi (clones [rhombu5/dots](https://github.com/rhombu5/dots) and applies), fprintd enrollment, stage-2 PCR 7 binding on the cryptroot TPM seal (§7.5), etc.
- **No pre-shipped `p10k.zsh` sidecar** — removed 2026-04-21 per user preference. `~/.p10k.zsh` is now authored by `p10k configure` on first zsh launch.

### CLI-stack shakedown (phase 0.5, optional)
- [wsl-cli-test.sh](wsl-cli-test.sh) — Idempotent setup script for an Arch WSL distro used to validate the CLI stack (zsh + zgenom plugins, tmux, helix, mise tools, chezmoi). Ends with a `verify` block that lists FAIL/OK per tool — always preserve that verification section when editing.
- [wsl-setup.sh](wsl-setup.sh) — Minimal `/etc/wsl.conf` writer; runs once as root inside the Arch WSL distro (sets default user `tom`, enables systemd, disables Windows PATH interop).

## Coaching the user through the install

The user does NOT follow a written runbook — Claude coaches in real time. There IS no `INSTALL-RUNBOOK.md` (removed 2026-04-27). The points below give a fresh Claude session the minimum context it needs to walk Tom through Phase 0 → Phase 3.

### Phase 0 — boot-medium prep (before the laptop boots)

- The laptop boots from a regular Arch live USB (no Ventoy, no autounattend). Make the USB on Tom's dev machine: download the latest Arch ISO from archlinux.org, write to USB with **Rufus** (Windows: `winget install Rufus.Rufus`) or `dd` on Linux.
- Verify the ISO against the upstream `sha256sums.txt` before writing — otherwise a corrupt download silently produces a stick that gets ~10 min into boot before failing on `loop0`.
- BIOS prep at the laptop: F2 → **SATA Operation = AHCI** (RAID/Intel-RST hides the disk from the installer); **Secure Boot OFF** for the install (limine binary isn't signed yet — sbctl wires this up later).
- F12 boot menu → pick the USB stick.

### Phase 2 — running install.sh

Coaching the user during the install:
- Tom needs Wi-Fi from the live shell. `iwctl` → `station wlan0 connect <SSID>` → enter PSK. Wi-Fi profiles for the user's home/office SSIDs are also embedded in `install.sh` §2 — if `archlinux.org` pings on first try, `install.sh` skips manual Wi-Fi.
- `git clone https://github.com/fnrhombus/arch-setup -b claude/option-b-uki-tpm-parity /tmp/arch-setup && bash /tmp/arch-setup/phase-2-arch-install/install.sh` (drop `-b` once option-b is merged to main).
- Three prompts up front: root password (twice), tom password (twice), then a 48-digit LUKS recovery key gets auto-generated and displayed in a red banner. Tom MUST photograph the screen — the key only exists in the LUKS header and his photo. Banner blocks until he types `I HAVE THE KEY` exactly.
- After "Proceed?" `yes`, install runs unattended for ~15-25 min (pacstrap + mkinitcpio UKI builds + chroot config). Tom can step away.
- On completion: remove the USB, reboot. **First boot is silent** if TPM2 enrollment succeeded at install time (look for `Enrolling TPM2 (signed PCR 11 policy)` in the install log). If TPM enroll failed, Tom enters the recovery key once; postinstall §7.5 retries.

### Phase 3 — running postinstall.sh

- Login as `tom`. Run `~/postinstall.sh`. Watch for:
  - §1 pacman packages (~5 min, ~1.5 GB download)
  - §3 yay + AUR builds (~10 min — VSCode, Edge, claude-desktop, etc.)
  - §7 fingerprint enrollment — Tom needs to swipe ONE finger 13 times when prompted
  - §7.5 stage-2 LUKS TPM2 reseal — prompts for the LUKS passphrase ONCE; this layers PCR 7 onto the seal so SB toggle becomes meaningful
  - §13 chezmoi clones rhombu5/dots and applies the bare-Hyprland configs
- After it completes: reboot one more time. Boot is still silent (the §7.5 reseal kept PCR-7-bound TPM unlock working). agetty's bare-TTY login prompt shows up on tty1; Tom logs in (lid-aware: fprintd/PIN/password via `/etc/pam.d/login`); `~/.zprofile` execs `uwsm start hyprland-uwsm.desktop` and Hyprland comes up themed via matugen.

### What to know that isn't in a script

- **TPM2 / signed-PCR-11 design rationale** — `docs/tpm-luks-bitlocker-parity.md`. Read this before answering "why didn't first boot prompt me for the key" or "what happens if I enable Secure Boot."
- **Migration to a future SSD** — `dd` the LUKS partition byte-for-byte to the new drive, then `btrfs filesystem resize max /` if the destination is bigger. No re-keying, no second-disk dependencies. The single-LUKS-partition design exists for this exact path.
- **The Netac SSD** — slated for replacement, deliberately untouched by `install.sh`. Don't propose "use the Netac for X" — Tom wants it free of state.

## Working on this repo

There is no build, lint, or test target. Work is almost entirely **editing markdown** and the two shell scripts. If you edit a script:

- Run `shellcheck` if available, otherwise hand-trace.
- `wsl-cli-test.sh` is meant to be run inside an `archlinux` WSL distro: `wsl -d archlinux -u tom bash ./wsl-cli-test.sh`. Assume the user has `mise`, `pacman`, and `yay` available inside.
- `wsl-setup.sh` runs as root *once*, before `wsl-cli-test.sh`: `wsl -d archlinux -u root bash ./wsl-setup.sh && wsl --terminate archlinux`.

## Context that should influence every edit

- **The target machine cannot use NVIDIA under Wayland.** MX250 requires nvidia-470xx, which lacks GBM. Any suggestion involving Optimus/nvidia on this hardware is wrong — Intel UHD 620 only, external monitor via HDMI (wired to iGPU), NVIDIA modules blacklisted.
- **User does not enjoy config tweaking — but Claude does it for them.** The "no excessive config tweaking" preference is filtered through "Claude does the tweaking efficiently." Result: NO opinionated dotfile pack (HyDE, ml4w, Caelestia all rejected). Configs are **Claude-authored and chezmoi-managed** in a separate repo, [rhombu5/dots](https://github.com/rhombu5/dots). Theme = matugen (Material You from wallpaper). Bootloader = limine. Login = bare TTY → uwsm → Hyprland (greetd + ReGreet kept installed but disabled).
- **Dotfiles live in a separate repo** — [rhombu5/dots](https://github.com/rhombu5/dots), cloned into `~/.local/share/chezmoi` by `chezmoi init --apply rhombu5/dots`. This repo (arch-setup) holds installer scripts only; **don't propose adding configs back here**. Don't propose `stow` or plain symlinks either.
- **tmux is required, not optional.** It's there for Claude Code's worktree workflow (Zellij is not supported). Prefix is `Ctrl+a`, carried from the prior `fnwsl` setup.
- **Shell stack is locked:** zsh + zgenom + powerlevel10k + the plugin list in `wsl-cli-test.sh`. Mirror any plugin change across both the `.zshrc` block *and* the pre-build block at the bottom of that script, or the zgenom cache will be stale on first login.
- **Tablet-mode signal path on the 7786 was empirically traced 2026-04-29** — see [docs/tablet-mode-investigation.md](docs/tablet-mode-investigation.md). Read this before designing or editing any tablet-mode auto-detection: the signal lives on a dynamically-created `Intel HID switches` device, not the obvious `Intel HID events`.

## Conventions

- Markdown checkboxes (`- [ ]`) in `docs/decisions.md` track unmet requirements — tick them as work completes, don't delete them.
- Platform-specific notes in prose should stay plain; the `[Windows]`/`[WSL]` annotation convention is for the user's global `~/.claude/CLAUDE.md`, not for this repo's content.

## Working style

- **Always do as much work in parallel as is reasonably possible.** Independent tool calls should go in a single message with multiple tool blocks; independent edits to different files should batch; independent research questions should fan out via parallel `Agent` calls. Do not serialize work that has no dependency. (Web/mobile Claude Code does not support a user-level `~/.claude/CLAUDE.md`, so this lives here as the project-scoped equivalent until that surface gains one.)

