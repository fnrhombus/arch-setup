# Session handoff — continue on Metis

You are picking up a conversation that was running on Claude Code on the web (web session, scoped to `fnrhombus/arch-setup`) and is now moving to a Claude Code session running **on the Metis laptop itself**. Everything below is state you inherit cold — no shared context with the prior session.

## Where things stand on Metis (as of 2026-04-21)

### Working
- Dual-boot Windows 11 + Arch install completed from USB (Ventoy + autounattend + install.sh + chroot.sh + postinstall.sh).
- BitLocker on Windows side (recovery key path documented when PCRs mismatch — see runbook/INSTALL-RUNBOOK.md §C).
- LUKS + btrfs + snapper on Arch side, TPM2 autounlock enrolled, fallback passphrase + recovery keys stored in Bitwarden.
- Fingerprint reader (Goodix 538C) working via `libfprint-goodix-53xc` on `libfprint-tod-git` with `!lto`. 5 fingers enrolled by postinstall.
- TPM-PIN via pinpam wired into sudo / polkit / hyprlock.
- NetworkManager, SDDM, Bluetooth, PipeWire, Docker service, snapper, smartmontools, memtest86+(-efi) loader entry — all installed and enabled.
- sshd hardened (key-only, no root, `AllowUsers tom`), Callisto pubkey in `~/.ssh/authorized_keys`.
- `ufw` active: default deny in, default allow out, `22/tcp ALLOW`.
- nwg-displays layout confirmed: Vizio V505-G9 (DP-1) at `(0,0)` scale 1.5, eDP-1 at `(0,1440)` scale 1. Mouse flows across the full shared edge after the X=0 fix.
- Systemd-boot NVRAM entry was deleted by Windows first-boot but Arch EFI fallback (`/EFI/BOOT/BOOTX64.EFI`) still boots via F12 → "Samsung Partition 1". Fix is queued (see Pending).

### Drifted / being rolled forward
- **Dotfiles**: user was on end-4/illogical-impulse; postinstall now installs **HyDE-Project/HyDE** instead. The most recent postinstall run aborted at `target not found: wvkbd` (wvkbd is AUR, fix pushed on this branch). Next `fnpostinstall` will attempt the HyDE swap. HyDE will clobber `~/.config/hypr/*` and back the old tree up to `~/.config/cfg_backups/<timestamp>/`. See `docs/decisions.md` §Q3 for rationale.
- **Shell**: something in the end-4 stack left `tom` running fish despite decisions.md §Q8 locking zsh. postinstall §18 uses `usermod` to re-assert zsh as login shell, and new sed logic strips `shell fish` overrides from kitty/foot/ghostty configs.
- **p10k config**: we previously pre-shipped `~/.p10k.zsh` from fnwsl. That sidecar was deleted this session; first zsh launch now fires the `p10k configure` wizard so the user authors their own.

### Pending on Metis

In rough priority:

1. **Re-run `fnpostinstall`**. Latest push to this branch includes the wvkbd fix. First pass will:
   - Install the AUR tail including wvkbd + iio-hyprland + claude-desktop-native + python-certbot-dns-azure.
   - Run HyDE installer (interactive — skip NVIDIA with `-n`).
   - Re-apply §13a customizations (monitors.conf source, lid switch bindl, touch gestures, hyprgrass plugin).
   - Run `p10k configure` wizard on the first zsh that loads after the run.
2. **Fix BitLocker re-prompt loop.** Runbook §C — elevated PowerShell in Windows: `manage-bde -protectors -disable C: -RebootCount 0` → reboot → `manage-bde -protectors -enable C:`. Runbook §C's Fast Startup precheck uses `powercfg /a` (don't grep `hybrid` — that matches Hybrid Sleep, not Fast Startup).
3. **Re-register systemd-boot in NVRAM.** Windows deleted the entry; EFI fallback via Samsung Partition 1 still works. From Arch:
   ```
   sudo bootctl install
   sudo efibootmgr -v | grep -iE 'Manager'
   # Replace YYYY with the hex ID of the new Linux Boot Manager entry:
   sudo efibootmgr -o YYYY,0000
   ```
4. **Fill `/etc/metis-ddns.env` with Azure SP credentials** (one-time `az ad sp create-for-rbac --name metis-ddns --role "DNS Zone Contributor" --scopes <zone-id> --years 2`), then `sudo systemctl start metis-ddns.service`. Detailed in runbook §3e-bis. `DDNS_DISABLE_IPV4=1` is the default (router doesn't expose v4).
5. **Issue Let's Encrypt cert** for `metis.rhombus.rocks` after step 4 succeeds. Mirror the same SP creds into `/etc/letsencrypt/azure.ini` (different INI keys — see template). `certbot certonly --authenticator dns-azure ...`. Detailed in runbook §3e-ter. `certbot-renew.timer` is already enabled.
6. **Test SSH from Callisto** against metis. Should accept the key in the vault item named "Callisto", refuse passwords.
7. **Phase-3.5 2-in-1 hardware validation** (full list in `docs/remaining-work.md`): confirm touch-panel chipset via `dmesg`, test iio-hyprland rotation, test wvkbd OSK, write tablet-mode udev rule, palm rejection tuning, Wacom AES pressure/tilt test.
8. **memtest86+ full pass** if not already completed (user was running it when this session ended).

## Working branch

As of this handoff the branch `claude/fix-linux-boot-issue-9ps2s` has been **merged into main** and deleted. **Work off `main` going forward.**

## Key docs for grounding

- `docs/decisions.md` — source of truth for all locked-in decisions. Read before suggesting any architectural change.
- `docs/remaining-work.md` — full todo list across the laptop install, phase-3.5 hardware, and the azure-ddns split-out.
- `runbook/INSTALL-RUNBOOK.md` — step-by-step install + troubleshooting; §3e-bis (DDNS), §3e-ter (Let's Encrypt), §3e-quater (firewall), §C (BitLocker PCR reseal) are the ones most relevant right now.
- `runbook/phase-3-handoff.md` — the long-form teaching-oriented handoff for a Claude session on the laptop. This doc (`docs/session-handoff.md`) is the short bridge; that one is the reference.
- `staged-azure-ddns/HANDOFF.md` — only relevant if user asks about the split-out. Otherwise ignore.

## User preferences (carried forward)

- Decisive over cautious. Pick the opinionated default; discuss only if truly ambiguous.
- Terminal + Claude Code (CLI) + RDP client + VSCode + browser workflow. Future Windows VM.
- Ghostty as daily terminal. Catppuccin Mocha everywhere it can be applied.
- **tmux is required** (Ctrl+a prefix) for Claude Code's worktree workflow.
- Dotfiles managed by chezmoi eventually — don't propose stow/symlinks.
- User does NOT enjoy config tweaking. Opinionated defaults with sane upgrade paths.
- Always commit on task completion; atomic commits (one logical change per commit); push on feature completion. Commit messages explain the "why", not the "what".
- Work in parallel when tasks are independent. Single message with multiple tool calls, not serialized.
- User uses dictation — expect occasional "memory test" ↔ "speed test", "zsh" ↔ "this is zsh" confusions. Trust the user's stated intent over the dictation surface.

## Known gotchas seen this session

- **`nwg-displays` canvas**: defaults monitor X positions to non-zero values (~2000 for the 4K rectangle) even when rectangles look snapped. Type `0` into X fields manually for both monitors or the mouse only transitions at a corner.
- **BitLocker doesn't auto-reseal** on recovery-key entry. Must manually `manage-bde -protectors -disable/-enable` after boot-chain changes.
- **Windows deletes EFI NVRAM entries** for non-Windows bootloaders on first boot / feature updates. Samsung Partition 1 fallback (EFI `BOOTX64.EFI`) still works even when NVRAM only shows Windows. Re-register with `bootctl install`.
- **HyDE prompts for shell** during install. Fish is an option on its list; if user accepts, we end up in fish despite decisions.md §Q8. postinstall §18 re-asserts zsh via `usermod`.
- **wvkbd is AUR, not [extra]** — common footgun when adding 2-in-1 touch packages. Same goes for `iio-hyprland`, `libfprint-goodix-53xc`, `python-certbot-dns-azure`, `claude-desktop-native`, `pinpam-git`.
- **systemd-boot has no auto-scan** for memtest86+ even when the EFI package is installed. Must write `/boot/loader/entries/memtest86+.conf` manually (postinstall §1c does this).
- **Ghostty theme file name** is literally `"Catppuccin Mocha"` (capital C, space), not `catppuccin-mocha`. Wrong form is a silent no-op.

## Commit signing note

This branch's commits are unsigned. The Claude Code web harness has `commit.gpgsign=true` in git config but `/home/claude/.ssh/commit_signing_key.pub` was empty — key material wasn't provisioned. Per-session issue; the laptop-side Claude session may or may not have the same problem. If signed history matters, investigate before the first commit.

## Starter prompt you can paste to the new session

> Read `docs/session-handoff.md` end-to-end, then `docs/decisions.md` and `docs/remaining-work.md`. Confirm you understand the current state and the next priority (re-run `fnpostinstall`), then wait for my next instruction.
