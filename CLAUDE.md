# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **planning and prep repository** for a future Arch Linux dual-boot install on a Dell Inspiron 7786 (2-in-1 laptop). It contains no application code — only decision records, a handoff guide for post-install Claude sessions, and WSL-based test scripts that shake out the CLI stack (zsh/tmux/helix/zgenom) before the Arch install happens.

Git remote: `git@github.com:fnrhombus/arch-setup.git`. Owner: `fnrhombus`.

## Bootstrap phases

This repo's deliverables map to these phases. [docs/decisions.md](docs/decisions.md) is the single source of truth — if any artifact disagrees with it, the artifact is wrong.

| # | Phase | Environment | Entry point(s) |
|---|---|---|---|
| 0 | USB prep (on dev machine) | Windows + PowerShell | `pnpm i` → [scripts/fetch-assets.ps1](scripts/fetch-assets.ps1) + [scripts/stage-usb.ps1](scripts/stage-usb.ps1) |
| 0-alt | **Netac-Ventoy bootstrap** (Metis-only — when USB ports won't boot Ventoy) | Current Arch on Metis | [prep-netac-ventoy.sh](prep-netac-ventoy.sh) — wipes the Netac, installs Ventoy, populates with both ISOs + the repo. One-way door. |
| 0.5 | CLI-stack shakedown (optional) | `archlinux` WSL distro on the user's current machine | [wsl-setup.sh](wsl-setup.sh) → [wsl-cli-test.sh](wsl-cli-test.sh) |
| 1 | Windows install | Ventoy boot medium → Windows Setup | [autounattend.xml](autounattend.xml) + [ventoy/ventoy.json](ventoy/ventoy.json) |
| 2 | Arch bare-metal install | Ventoy boot medium → Arch live ISO | [phase-2-arch-install/install.sh](phase-2-arch-install/install.sh) → [phase-2-arch-install/chroot.sh](phase-2-arch-install/chroot.sh) |
| 3 | Arch post-install / teaching | Booted Arch, logged in as `tom` | [phase-3-arch-postinstall/postinstall.sh](phase-3-arch-postinstall/postinstall.sh). [runbook/phase-3-handoff.md](runbook/phase-3-handoff.md) briefs the next Claude session. |
| 3.5 | 2-in-1 hardware wiring (deferred) | Booted Arch | [runbook/phase-3.5-hardware-handoff.md](runbook/phase-3.5-hardware-handoff.md) |
| 6 | Reclaim space for Windows (future) | Arch live USB or recovery partition | [phase-6-grow-windows.sh](phase-6-grow-windows.sh) |

Phase 1 only touches the Samsung SSD 840 PRO 512GB. The Netac 128GB is reserved entirely for Linux (recovery ISO + swap + `/var/log`+`/var/cache`, per [docs/decisions.md](docs/decisions.md) §Q9) once Phase 2 finishes — but during the **Phase 0-alt no-USB bootstrap**, the Netac transiently hosts Ventoy as a USB stand-in. Phase 2's `install.sh` re-wipes the Netac and rebuilds the §Q9 layout from scratch, so the Ventoy install is sacrificial.

For phone-coaching the user through the install (BIOS prep, secret-photographing, troubleshooting), paste [runbook/phase-0-handoff.md](runbook/phase-0-handoff.md) into a fresh Claude conversation on the user's phone before they reboot.

The whole end-to-end flow from a bare dev machine is:
1. Clone this repo, `pnpm i` — fetches ISOs, detects the Ventoy USB, mirrors everything onto it.
2. Plug the stick into the laptop, boot it, pick the Win11 entry from the Ventoy menu. Windows installs fully unattended (autounattend.xml: inline PS picks the Samsung by size → writes `X:\target-disk.txt` → diskpart reads that, silent OOBE).
3. Reboot, pick the Arch entry from any Ventoy loader (SanDisk USB or the internal Netac-Ventoy if the no-USB workflow is in play), clone the repo and run the installer: `git clone https://github.com/fnrhombus/arch-setup /tmp/arch-setup && bash /tmp/arch-setup/phase-2-arch-install/install.sh`. Root + tom passwords prompted up front; the LUKS recovery key is auto-generated BitLocker-style (48 digits, displayed with loud banner, strict type-back required). pacstrap + chroot run unattended.
4. First boot into Arch, log in as `tom`, run `~/postinstall.sh`.

## Repo layout

Markdown files split into two groups by audience:

- **[docs/](docs/)** — Planning and rationale. Read on the dev machine when editing the project. Not strictly needed at the laptop (but staged anyway, since phase-3.5 references `docs/decisions.md`).
- **[runbook/](runbook/)** — What the user reads *at the laptop* during the install. `pnpm pdf` renders every `runbook/*.md` to a sibling `.pdf`; `INSTALL-RUNBOOK.pdf` is the one you print.

Everything else at the repo root is a deliverable the install itself consumes (scripts, XML, Ventoy config, phase dirs) or dev-machine plumbing (`package.json`, `.mise.toml`, `scripts/`).

## File roles

### docs/ — planning / rationale (dev machine)
- [docs/decisions.md](docs/decisions.md) — Locked-in decisions with rationale: hardware spec, partition plan, Hyprland, **limine** (replaced systemd-boot 2026-04-22), yay, Ghostty, **greetd + ReGreet** (replaced SDDM), PipeWire, **matugen / Material You** (replaced Catppuccin), chezmoi, etc. Plus the `Desktop component picks` block locking the smaller picks. **Edit this when a decision changes** — don't let it drift from the other docs.
- [docs/desktop-requirements.md](docs/desktop-requirements.md) — Full spec for the bare-Hyprland + chezmoi-managed approach (matugen pipeline, manual hibernate workflow, GTK-CSS pipeline end to end, keybind philosophy, workspace strategy). Source of truth for the *implementation* of what decisions.md decided.
- [docs/autounattend-oobe-patch.md](docs/autounattend-oobe-patch.md) — Record of patches already applied to the Schneegans-generated `autounattend.xml` (Samsung-by-size detection, 512 MB EFI, 160 GiB Windows, silent OOBE, disable hibernation/Fast Startup). **Always cross-check against docs/decisions.md §Q9 when editing.**
- [docs/wsl-setup-lessons.md](docs/wsl-setup-lessons.md) — Hard-won WSL pitfalls harvested from a prior `fnwsl` repo (MTU 1350 before any network op, `GIT_TEMPLATE_DIR=""` on every clone, `ZGEN_DIR` must be set before sourcing zgenom, never use raw.githubusercontent.com, etc.). **Consult before touching any setup script** — these gotchas are silent and expensive.

### runbook/ — read at the laptop
- [runbook/INSTALL-RUNBOOK.md](runbook/INSTALL-RUNBOOK.md) — Step-by-step script the user reads at the physical laptop, phase by phase. Duplicate of some decisions.md content by design, but biased toward *actions* vs. *rationale*. PDF output lives at `runbook/INSTALL-RUNBOOK.pdf`.
- [runbook/phase-3-handoff.md](runbook/phase-3-handoff.md) — The document fed to the next Claude session *inside Arch after install*. Describes the user, hardware, installed stack, and what Claude is expected to teach (Hyprland, Helix, tmux). Keep in sync with `docs/decisions.md`.
- [runbook/phase-3.5-hardware-handoff.md](runbook/phase-3.5-hardware-handoff.md) — Handoff between phases 3 and 4 — tracks which requirements in `docs/decisions.md` still need fingerprint/pen/tablet/RDP validation on real hardware.
- [runbook/GLOSSARY.md](runbook/GLOSSARY.md) — Every non-obvious tool/utility/package that shows up in decisions.md + postinstall.sh, with a brief full-name / what-it-does / when-you-care blurb.
- [runbook/SURVIVAL.md](runbook/SURVIVAL.md) — Minimum-viable rescue card. What to do if the desktop is broken or Claude isn't running: TTY login, Wi-Fi from `iwctl`, launch a terminal/browser, start Claude.

### Phase 0 — dev-machine USB prep
- [package.json](package.json) — Entry points for the dev-machine prep flow. `pnpm i` chains `fetch-assets.ps1` → `stage-usb.ps1` (postinstall hook). `pnpm stage` re-runs the USB staging only; `pnpm restore:force` re-downloads ISOs. `pnpm pdf` renders every `runbook/*.md` to a sibling `.pdf`.
- [scripts/fetch-assets.ps1](scripts/fetch-assets.ps1) — Downloads the Arch ISO (latest from Rackspace mirror) + Ventoy Windows release (latest from GitHub API) + Windows 11 consumer ISO via vendored [Fido.ps1](https://github.com/pbatard/Fido) into `assets/`. Fido output is renamed to the canonical `Win11_25H2_English_x64_v2.iso` so `ventoy/ventoy.json`'s `auto_install` match keeps working — bump both together when Microsoft ships 26H2. Idempotent (`-Force` to override). On any Fido failure (MS API drift, etc.) falls through to actionable manual-download instructions.
- [scripts/stage-usb.ps1](scripts/stage-usb.ps1) — Auto-finds the Ventoy data partition by its `Ventoy` filesystem label, sanity-checks with the ~32 MB VTOYEFI companion, then mirrors ISOs + configs + phase scripts + `docs/` + `runbook/` onto it via robocopy. Soft-exits (code 2) if no USB is present, so `pnpm i` never fails just because the stick is unplugged.
- [scripts/runbook-pdf.mjs](scripts/runbook-pdf.mjs) — `pnpm pdf` entry point. Renders every `runbook/*.md` → `runbook/<name>.pdf` via `marked` + Edge headless (`--print-to-pdf`). 5.5"×8.5" pages, 0.5" margins, 12pt body.
- [assets/](assets/) — Directory where ISOs land. `.gitignore` covers all auto-populated entries; the Win11 ISO is also gitignored by pattern. Everything else you drop in shows up as untracked so you can decide deliberately.

### Phase 1 — Windows install
- [autounattend.xml](autounattend.xml) — Schneegans-generated Windows unattend file, hand-patched per the OOBE checklist. Orders 6-9 of the windowsPE pass emit `X:\pe.cmd`, which at runtime: (a) runs inline PowerShell to find the unique disk in the 500-600 GB window (the Samsung per decisions.md §Q9) and writes its number to `X:\target-disk.txt`, aborting if zero or multiple matches; (b) `set /p`'s that number into `%TARGET_DISK%` and builds `X:\diskpart.txt` against it; (c) runs diskpart to lay out EFI 512 MB / MSR 16 MB / Windows 160 GiB / trailing ~316 GiB unallocated.
- [ventoy/ventoy.json](ventoy/ventoy.json) — Ventoy plugin config. Makes Ventoy inject `autounattend.xml` when the Win11 ISO is selected from the menu (otherwise Ventoy's Windows-installer emulation ignores the sibling XML). Mirrored to `<Ventoy-data>/ventoy/ventoy.json` by `stage-usb.ps1`.

### Phase 2 — Arch bare-metal install
- [phase-2-arch-install/install.sh](phase-2-arch-install/install.sh) — Main installer. Runs from the Arch live ISO. Auto-detects Samsung + Netac by size, prompts for root + `tom` passwords once at the top (hashed via `openssl passwd -6`, handed to chroot via mode-600 file), pacstraps, then calls `chroot.sh`.
- [phase-2-arch-install/chroot.sh](phase-2-arch-install/chroot.sh) — Inside `arch-chroot /mnt`. Consumes the pre-hashed passwords, sets timezone + locale, creates user `tom`, allocates TPM2 SHA-256 PCR bank, installs **limine** (UEFI binary to ESP fallback path + NVRAM entry + `/boot/limine.conf`), installs **greetd + greetd-regreet** (system-files at `phase-3-arch-postinstall/system-files/{greetd,pam.d}/`), writes hibernate-ready `/etc/crypttab.initramfs` (cryptroot + cryptswap with TPM2), pacman post-upgrade reseal hook, wires greetd PAM for gnome-keyring + fprintd, seeds Wi-Fi profiles, enables services.

### Phase 3 — Arch post-install
- [phase-3-arch-postinstall/postinstall.sh](phase-3-arch-postinstall/postinstall.sh) — First-boot script run as `tom`. Installs yay, AUR packages (VSCode, Edge), zgenom + plugins, chezmoi, fprintd enrollment, etc.
- **No pre-shipped `p10k.zsh` sidecar** — removed 2026-04-21 per user preference. `~/.p10k.zsh` is now authored by `p10k configure` on first zsh launch. The sidecar file was previously lifted from the `fnwsl` setup; history in git if the answer changes.

### Phase 6 — reclaim space for Windows (optional, future)
- [phase-6-grow-windows.sh](phase-6-grow-windows.sh) — Run from the Arch live environment (USB **or** the Netac recovery partition). Shrinks the btrfs partition by doing `btrfs device add` → `btrfs device remove` onto a new partition at the tail of the Samsung, which moves the free space to be adjacent to Windows so Disk Management's Extend Volume works. Has an EXIT trap that prints explicit recovery recipes if the migration fails mid-flight.

### CLI-stack shakedown (phase 0.5, optional)
- [wsl-cli-test.sh](wsl-cli-test.sh) — Idempotent setup script for an Arch WSL distro used to validate the CLI stack (zsh + zgenom plugins, tmux, helix, mise tools, chezmoi). Ends with a `verify` block that lists FAIL/OK per tool — always preserve that verification section when editing.
- [wsl-setup.sh](wsl-setup.sh) — Minimal `/etc/wsl.conf` writer; runs once as root inside the Arch WSL distro (sets default user `tom`, enables systemd, disables Windows PATH interop).

## Working on this repo

There is no build, lint, or test target. Work is almost entirely **editing markdown** and the two shell scripts. If you edit a script:

- Run `shellcheck` if available, otherwise hand-trace.
- `wsl-cli-test.sh` is meant to be run inside an `archlinux` WSL distro: `wsl -d archlinux -u tom bash ./wsl-cli-test.sh`. Assume the user has `mise`, `pacman`, and `yay` available inside.
- `wsl-setup.sh` runs as root *once*, before `wsl-cli-test.sh`: `wsl -d archlinux -u root bash ./wsl-setup.sh && wsl --terminate archlinux`.

### Pre-commit hook (Hyprland binds validation)

`.githooks/pre-commit` runs `validate-hypr-binds` against any staged changes under `dotfiles/dot_config/hypr/`. Refuses commits with duplicate (MOD, KEY) pairs, unknown dispatchers, or malformed `bindd` descriptions. Activate once per fresh clone with:

```sh
git config core.hooksPath .githooks
```

`core.hooksPath` is `.git/config`-local — it doesn't ship with the clone, so each new checkout has to set it once. Any future committer (claude or human) needs this active or they'll push broken bind configs.

## Context that should influence every edit

- **The target machine cannot use NVIDIA under Wayland.** MX250 requires nvidia-470xx, which lacks GBM. Any suggestion involving Optimus/nvidia on this hardware is wrong — Intel UHD 620 only, external monitor via HDMI (wired to iGPU), NVIDIA modules blacklisted.
- **User does not enjoy config tweaking — but Claude does it for them.** The "no excessive config tweaking" preference is filtered through "Claude does the tweaking efficiently." Result: NO opinionated dotfile pack (HyDE, ml4w, Caelestia all rejected). Configs are **Claude-authored and chezmoi-managed** at `dotfiles/` in this repo. Theme = matugen (Material You from wallpaper). Bootloader = limine. Greeter = greetd + ReGreet. The reinstall-design history is in `docs/reinstall-planning.md`.
- **tmux is required, not optional.** It's there for Claude Code's worktree workflow (Zellij is not supported). Prefix is `Ctrl+a`, carried from the prior `fnwsl` setup.
- **Dotfiles will be managed by `chezmoi`** eventually — don't propose `stow` or plain symlinks.
- **Shell stack is locked:** zsh + zgenom + powerlevel10k + the plugin list in `wsl-cli-test.sh`. Mirror any plugin change across both the `.zshrc` block *and* the pre-build block at the bottom of that script, or the zgenom cache will be stale on first login.

## Conventions

- Markdown checkboxes (`- [ ]`) in `docs/decisions.md` track unmet requirements — tick them as work completes, don't delete them.
- Platform-specific notes in prose should stay plain; the `[Windows]`/`[WSL]` annotation convention is for the user's global `~/.claude/CLAUDE.md`, not for this repo's content.

## Working style

- **Always do as much work in parallel as is reasonably possible.** Independent tool calls should go in a single message with multiple tool blocks; independent edits to different files should batch; independent research questions should fan out via parallel `Agent` calls. Do not serialize work that has no dependency. (Web/mobile Claude Code does not support a user-level `~/.claude/CLAUDE.md`, so this lives here as the project-scoped equivalent until that surface gains one.)

## Commit discipline

- **Always commit on task completion.** Never leave a finished task as uncommitted work.
- **Commits MUST be atomic** — one logical change per commit. If uncommitted changes span multiple tasks, split them into separate commits (use `git add -p` or path-scoped `git add`).
- **Hierarchy:** a *task* is the lowest unit of work (one commit). A *feature* is the next level up (one or more task commits that together deliver the feature).
- **Push on feature completion.** Once all task commits that make up a feature are in, push to the remote. Don't push partial features mid-stream unless the user asks.
