# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **planning and prep repository** for a future Arch Linux dual-boot install on a Dell Inspiron 7786 (2-in-1 laptop). It contains no application code — only decision records, a handoff guide for post-install Claude sessions, and WSL-based test scripts that shake out the CLI stack (zsh/tmux/helix/zgenom) before the Arch install happens.

Not a git repo. Not on a remote yet. Owner: `fnrhombus`.

## Bootstrap phases

This repo's deliverables map to four phases. `decisions.md` is the single source of truth — if any artifact disagrees with it, the artifact is wrong.

| # | Phase | Environment | Entry point(s) |
|---|---|---|---|
| 1 | Windows install | USB booted into Windows Setup / PE | `autounattend.xml` + [windows-diskpart.txt](windows-diskpart.txt) + [windows-diskpart-preflight.ps1](windows-diskpart-preflight.ps1) |
| 2 | CLI-stack shakedown (optional, pre-Arch) | `archlinux` WSL distro on the user's current machine | [wsl-setup.sh](wsl-setup.sh) → [wsl-cli-test.sh](wsl-cli-test.sh) |
| 3 | Arch bare-metal install | Arch live ISO (USB) | *future — not in this repo yet* |
| 4 | Arch post-install / teaching | Booted Arch | [handoff.md](handoff.md) is the brief; script body reuses [wsl-cli-test.sh](wsl-cli-test.sh) |

Phase 1 only touches the Samsung SSD 840 PRO 512GB. The Netac 128GB is reserved entirely for Linux (recovery ISO + swap + `/var/log`+`/var/cache`, per decisions.md §Q9) and stays untouched until phase 3.

## File roles

- [decisions.md](decisions.md) — Locked-in decisions with rationale: hardware spec, partition plan, Hyprland, systemd-boot, yay, Ghostty, SDDM, PipeWire, Catppuccin, chezmoi, etc. **Edit this when a decision changes** — don't let it drift from `handoff.md`.
- [handoff.md](handoff.md) — The document fed to the next Claude session *inside Arch after install*. It describes the user, hardware, installed stack, and what Claude is expected to teach (Hyprland, Helix, tmux). Keep it in sync with decisions.md.
- [autounattend.xml](autounattend.xml) — Schneegans-generated Windows unattend file. Its stock diskpart + OOBE blocks are wrong for this dual-boot; see the patch checklist below.
- [autounattend-oobe-patch.md](autounattend-oobe-patch.md) — Hand-patch checklist: which XML fragments to swap, full-silent `<OOBE>` replacement, `Specialize.ps1` additions (disable hibernation + Fast Startup). **Always cross-check against decisions.md §Q9 when editing.**
- [windows-diskpart.txt](windows-diskpart.txt) — Static diskpart template producing the target Samsung layout (EFI 512 MB / MSR 16 MB / Windows 160 GiB / trailing ~316 GiB unallocated). Uses `%DISK%` placeholder.
- [windows-diskpart-preflight.ps1](windows-diskpart-preflight.ps1) — PE-time PowerShell that size-matches the Samsung (500–600 GB window), substitutes the disk number, writes `X:\diskpart-runtime.txt`. Fails loudly on zero-or-multiple matches — never silently clobbers the wrong drive.
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
