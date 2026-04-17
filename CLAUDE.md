# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **planning and prep repository** for a future Arch Linux dual-boot install on a Dell Inspiron 7786 (2-in-1 laptop). It contains no application code — only decision records, a handoff guide for post-install Claude sessions, and WSL-based test scripts that shake out the CLI stack (zsh/tmux/helix/zgenom) before the Arch install happens.

Git remote: `git@github.com:fnrhombus/arch-setup.git`. Owner: `fnrhombus`.

## Bootstrap phases

This repo's deliverables map to these phases. `decisions.md` is the single source of truth — if any artifact disagrees with it, the artifact is wrong.

| # | Phase | Environment | Entry point(s) |
|---|---|---|---|
| 0 | USB prep (on dev machine) | Windows + PowerShell | `pnpm i` → [scripts/fetch-assets.ps1](scripts/fetch-assets.ps1) + [scripts/stage-usb.ps1](scripts/stage-usb.ps1) |
| 0.5 | CLI-stack shakedown (optional) | `archlinux` WSL distro on the user's current machine | [wsl-setup.sh](wsl-setup.sh) → [wsl-cli-test.sh](wsl-cli-test.sh) |
| 1 | Windows install | Ventoy USB → Windows Setup | [autounattend.xml](autounattend.xml) + [ventoy/ventoy.json](ventoy/ventoy.json) |
| 2 | Arch bare-metal install | Ventoy USB → Arch live ISO | [phase-2-arch-install/install.sh](phase-2-arch-install/install.sh) → [phase-2-arch-install/chroot.sh](phase-2-arch-install/chroot.sh) |
| 3 | Arch post-install / teaching | Booted Arch, logged in as `tom` | [phase-3-arch-postinstall/postinstall.sh](phase-3-arch-postinstall/postinstall.sh) (+ `p10k.zsh` sidecar). [handoff.md](handoff.md) briefs the next Claude session. |
| 6 | Reclaim space for Windows (future) | Arch live USB or recovery partition | [phase-6-grow-windows.sh](phase-6-grow-windows.sh) |

Phase 1 only touches the Samsung SSD 840 PRO 512GB. The Netac 128GB is reserved entirely for Linux (recovery ISO + swap + `/var/log`+`/var/cache`, per decisions.md §Q9) and stays untouched until phase 2.

The whole end-to-end flow from a bare dev machine is:
1. Clone this repo, `pnpm i` — fetches ISOs, detects the Ventoy USB, mirrors everything onto it.
2. Plug the stick into the laptop, boot it, pick the Win11 entry from the Ventoy menu. Windows installs fully unattended (autounattend.xml: inline PS picks the Samsung by size → writes `X:\target-disk.txt` → diskpart reads that, silent OOBE).
3. Reboot, pick the Arch entry from Ventoy, run `./install.sh` from the mounted Ventoy data partition. Password prompt is one-shot at the top; pacstrap + chroot run unattended.
4. First boot into Arch, log in as `tom`, run `~/postinstall.sh`.

## File roles

### Planning / decision docs
- [decisions.md](decisions.md) — Locked-in decisions with rationale: hardware spec, partition plan, Hyprland, systemd-boot, yay, Ghostty, SDDM, PipeWire, Catppuccin, chezmoi, etc. **Edit this when a decision changes** — don't let it drift from the other docs.
- [handoff.md](handoff.md) — The document fed to the next Claude session *inside Arch after install*. Describes the user, hardware, installed stack, and what Claude is expected to teach (Hyprland, Helix, tmux). Keep in sync with decisions.md.
- [phase-3.5-hardware-handoff.md](phase-3.5-hardware-handoff.md) — Handoff between phases 3 and 4 — tracks which requirements in decisions.md still need fingerprint/pen/tablet/RDP validation on real hardware.
- [INSTALL-RUNBOOK.md](INSTALL-RUNBOOK.md) — Step-by-step script the user reads at the physical laptop, phase by phase. Duplicate of some decisions.md content by design, but biased toward *actions* vs. *rationale*.

### Phase 0 — dev-machine USB prep
- [package.json](package.json) — Entry points for the dev-machine prep flow. `pnpm i` chains `fetch-assets.ps1` → `stage-usb.ps1` (postinstall hook). `pnpm stage` re-runs the USB staging only; `pnpm restore:force` re-downloads ISOs.
- [scripts/fetch-assets.ps1](scripts/fetch-assets.ps1) — Downloads the Arch ISO (latest from Rackspace mirror) + Ventoy Windows release (latest from GitHub API) into `assets/`. Idempotent (`-Force` to override). Warns loudly if `assets/Win11_*x64*.iso` is missing — Microsoft gates the Win11 ISO behind a per-session API so it stays manual.
- [scripts/stage-usb.ps1](scripts/stage-usb.ps1) — Auto-finds the Ventoy data partition by its `Ventoy` filesystem label, sanity-checks with the ~32 MB VTOYEFI companion, then mirrors ISOs + configs + phase scripts onto it via robocopy. Soft-exits (code 2) if no USB is present, so `pnpm i` never fails just because the stick is unplugged.
- [assets/](assets/) — Directory where ISOs land. `.gitignore` covers all auto-populated entries; the Win11 ISO is also gitignored by pattern. Everything else you drop in shows up as untracked so you can decide deliberately.

### Phase 1 — Windows install
- [autounattend.xml](autounattend.xml) — Schneegans-generated Windows unattend file, hand-patched per the OOBE checklist. Orders 6-9 of the windowsPE pass emit `X:\pe.cmd`, which at runtime: (a) runs inline PowerShell to find the unique disk in the 500-600 GB window (the Samsung per decisions.md §Q9) and writes its number to `X:\target-disk.txt`, aborting if zero or multiple matches; (b) `set /p`'s that number into `%TARGET_DISK%` and builds `X:\diskpart.txt` against it; (c) runs diskpart to lay out EFI 512 MB / MSR 16 MB / Windows 160 GiB / trailing ~316 GiB unallocated.
- [autounattend-oobe-patch.md](autounattend-oobe-patch.md) — Hand-patch checklist: XML fragments to swap, full-silent `<OOBE>` replacement, `Specialize.ps1` additions (disable hibernation + Fast Startup). **Always cross-check against decisions.md §Q9 when editing.**
- [ventoy/ventoy.json](ventoy/ventoy.json) — Ventoy plugin config. Makes Ventoy inject `autounattend.xml` when the Win11 ISO is selected from the menu (otherwise Ventoy's Windows-installer emulation ignores the sibling XML). Mirrored to `<Ventoy-data>/ventoy/ventoy.json` by `stage-usb.ps1`.

### Phase 2 — Arch bare-metal install
- [phase-2-arch-install/install.sh](phase-2-arch-install/install.sh) — Main installer. Runs from the Arch live ISO. Auto-detects Samsung + Netac by size, prompts for root + `tom` passwords once at the top (hashed via `openssl passwd -6`, handed to chroot via mode-600 file), pacstraps, then calls `chroot.sh`.
- [phase-2-arch-install/chroot.sh](phase-2-arch-install/chroot.sh) — Inside `arch-chroot /mnt`. Consumes the pre-hashed passwords, sets timezone + locale, creates user `tom`, installs systemd-boot, wires PAM for gnome-keyring + fprintd, seeds Wi-Fi profiles, enables services.

### Phase 3 — Arch post-install
- [phase-3-arch-postinstall/postinstall.sh](phase-3-arch-postinstall/postinstall.sh) — First-boot script run as `tom`. Installs yay, AUR packages (VSCode, Edge), zgenom + plugins, chezmoi, fprintd enrollment, etc.
- [phase-3-arch-postinstall/p10k.zsh](phase-3-arch-postinstall/p10k.zsh) — Pre-shipped powerlevel10k config lifted from the `fnwsl` setup — prevents the first shell from dropping into the p10k configure wizard. Copied to `~/.p10k.zsh` by postinstall.sh.

### Phase 6 — reclaim space for Windows (optional, future)
- [phase-6-grow-windows.sh](phase-6-grow-windows.sh) — Run from the Arch live environment (USB **or** the Netac recovery partition). Shrinks the btrfs partition by doing `btrfs device add` → `btrfs device remove` onto a new partition at the tail of the Samsung, which moves the free space to be adjacent to Windows so Disk Management's Extend Volume works. Has an EXIT trap that prints explicit recovery recipes if the migration fails mid-flight.

### CLI-stack shakedown (phase 0.5, optional)
- [wsl-cli-test.sh](wsl-cli-test.sh) — Idempotent setup script for an Arch WSL distro used to validate the CLI stack (zsh + zgenom plugins, tmux, helix, mise tools, chezmoi). Ends with a `verify` block that lists FAIL/OK per tool — always preserve that verification section when editing.
- [wsl-setup.sh](wsl-setup.sh) — Minimal `/etc/wsl.conf` writer; runs once as root inside the Arch WSL distro (sets default user `tom`, enables systemd, disables Windows PATH interop).
- [wsl-setup-lessons.md](wsl-setup-lessons.md) — Hard-won WSL pitfalls harvested from a prior `fnwsl` repo (MTU 1350 before any network op, `GIT_TEMPLATE_DIR=""` on every clone, `ZGEN_DIR` must be set before sourcing zgenom, never use raw.githubusercontent.com, etc.). **Consult before touching any setup script** — these gotchas are silent and expensive.

## Working on this repo

There is no build, lint, or test target. Work is almost entirely **editing markdown** and the two shell scripts. If you edit a script:

- Run `shellcheck` if available, otherwise hand-trace.
- `wsl-cli-test.sh` is meant to be run inside an `archlinux` WSL distro: `wsl -d archlinux -u tom bash ./wsl-cli-test.sh`. Assume the user has `mise`, `pacman`, and `yay` available inside.
- `wsl-setup.sh` runs as root *once*, before `wsl-cli-test.sh`: `wsl -d archlinux -u root bash ./wsl-setup.sh && wsl --terminate archlinux`.

## Context that should influence every edit

- **The target machine cannot use NVIDIA under Wayland.** MX250 requires nvidia-470xx, which lacks GBM. Any suggestion involving Optimus/nvidia on this hardware is wrong — Intel UHD 620 only, external monitor via HDMI (wired to iGPU), NVIDIA modules blacklisted.
- **User does not enjoy config tweaking.** Choose opinionated defaults with sane upgrade paths. The `end-4/illogical-impulse` Hyprland dotfiles are the baseline — don't suggest building Hyprland config from scratch.
- **tmux is required, not optional.** It's there for Claude Code's worktree workflow (Zellij is not supported). Prefix is `Ctrl+a`, carried from the prior `fnwsl` setup.
- **Dotfiles will be managed by `chezmoi`** eventually — don't propose `stow` or plain symlinks.
- **Shell stack is locked:** zsh + zgenom + powerlevel10k + the plugin list in `wsl-cli-test.sh`. Mirror any plugin change across both the `.zshrc` block *and* the pre-build block at the bottom of that script, or the zgenom cache will be stale on first login.

## Conventions

- Markdown checkboxes (`- [ ]`) in `decisions.md` track unmet requirements — tick them as work completes, don't delete them.
- Platform-specific notes in prose should stay plain; the `[Windows]`/`[WSL]` annotation convention is for the user's global `~/.claude/CLAUDE.md`, not for this repo's content.
