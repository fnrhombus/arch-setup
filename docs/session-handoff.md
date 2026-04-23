# Session handoff — continue on Metis

You are picking up a conversation on Claude Code running **on the Metis laptop itself**, in the `/tmp/arch-setup/` checkout. Everything below is state you inherit cold — no shared context with the prior session.

## Current state (2026-04-23)

**Branch**: `desktop-design`. The clean-slate reinstall design is locked-in across `docs/decisions.md`, `docs/desktop-requirements.md`, the phase-2/phase-3 install scripts, the chezmoi `dotfiles/` tree, and the printed runbook. **The actual reinstall has NOT happened yet** — Metis is still running the prior `main`-branch install (HyDE / SDDM / Catppuccin / systemd-boot / mako) until the user kicks off phase 1.

What the new design is, in one paragraph:

> Dual-boot Windows 11 + Arch on a Dell Inspiron 7786. Arch boots via **limine** (replaced systemd-boot — snapshot-rollback boot menu via `limine-snapper-sync`), greeted by **greetd + ReGreet** (replaced SDDM), running **bare Hyprland** with Claude-authored configs in chezmoi (no opinionated dotfile pack). Theme is **matugen / Material You** derived from the wallpaper (replaced Catppuccin), rendered into every component (waybar, swaync, fuzzel, ghostty, helix, hypr-colors, tmux, gtk, qt, hyprlock, regreet). Notifications via **swaync** (replaced mako). Wallpaper daemon **awww** (continuation of archived swww). **S4 hibernate enabled** with persistent LUKS2-encrypted swap, TPM2-sealed (PCRs 0+7), `resume=/dev/mapper/cryptswap` in the limine cmdline. Pacman post-upgrade hooks reseal the TPM on linux/limine/mkinitcpio updates and redeploy the limine UEFI binary.

## Source-of-truth hierarchy

If two documents disagree, the higher-priority one wins:

1. **`docs/decisions.md`** — locked design decisions with rationale. Edit this when a decision changes.
2. **`docs/desktop-requirements.md`** — implementation spec for §K matugen pipeline, §Hibernate, GTK-CSS pipeline end-to-end.
3. **`CLAUDE.md`** — project guide (file roles, working style, commit discipline).
4. **`runbook/INSTALL-RUNBOOK.md`** — what the user reads at the laptop during install.
5. **`runbook/phase-3-handoff.md`** — fed to the next Claude session inside the booted Arch.
6. **`runbook/SURVIVAL.md`** + **`runbook/GLOSSARY.md`** + **`runbook/keybinds.md`** + **`runbook/phase-3.5-hardware-handoff.md`** — references.

The phase-2 / phase-3 scripts MUST match the design above. As of 2026-04-23 they do — verified by the cleanup pass that produced commits `5edfb04`, `2d52f61`, `3e0dc14`, and the current commit (verify block, header comments, package names, idle timeouts, hostname, limine paths, hibernate cryptswap, all consistent).

## Where things stand on Metis

### What's ready
- `phase-2-arch-install/install.sh` + `chroot.sh` — limine + greetd + hibernate-cryptswap + TPM2 + Samsung disk path passed through `/root/.luks` to chroot.
- `phase-3-arch-postinstall/postinstall.sh` — pacman + AUR lists verified live; bare-Hyprland chezmoi apply at §13; CUPS + gutenprint for the user's Canon Pro 9000 Mk II at §1-print; Azure DDNS via `setup-azure-ddns.sh` (works around the Python 3.14 `az ad sp create-for-rbac --years` argparse bug); verify block sweeps for greetd / matugen / hyprgrass / cups; `limine-snapper-sync` installed.
- `phase-3-arch-postinstall/setup-azure-ddns.sh` — idempotent SP rotation, writes `/etc/metis-ddns.env` + `/etc/letsencrypt/azure.ini`.
- `dotfiles/` — full chezmoi source tree: 9 hyprland fragments, matugen config + 14 templates (incl. tmux), waybar / swaync / fuzzel / ghostty / yazi / helix / imv / zathura / qt / matugen, helper scripts (theme-toggle, wallpaper-rotate, control-panel, validate-hypr-binds), wallpaper-rotate systemd timer.
- Runbook PDFs renderable via `pnpm pdf` (Edge headless on Linux works with `EDGE=/usr/bin/microsoft-edge-stable`).

### What's pending — user actions
Order matters; some are USB-side, some are on Metis itself.

1. **Pre-reinstall on current install**: `fwupdmgr update` for Dell BIOS 1.16 → 1.18+; back up keepers from `/home/tom` not in Bitwarden.
2. **Stage USB on dev machine**: `pnpm i` (downloads Arch + Win11 + Ventoy ISOs, robocopies repo + autounattend onto Ventoy USB).
3. **Phase 1 — Windows install**: F12 → Ventoy → Win11 ISO; `autounattend.xml` runs unattended (~30 min). Stash BitLocker recovery key in Bitwarden as "Metis BitLocker recovery". (Note: hostname for both OSes is now `metis` — Windows also gets `Metis`. INSTALL-RUNBOOK §D documents the rename escape hatches if collision matters.)
4. **Phase 2 — Arch install**: F12 → Ventoy → Arch ISO → `git clone https://github.com/fnrhombus/arch-setup /tmp/arch-setup && bash /tmp/arch-setup/phase-2-arch-install/install.sh`. ~40 min, mostly unattended after the password prompts.
5. **Phase 3 — postinstall on Metis**: TTY login as `tom`, `~/postinstall.sh`. ~25 min (yay builds dominate). Includes printer driver install + chezmoi apply + matugen seed.
6. **One-time post-postinstall**:
   - `~/setup-azure-ddns.sh` (after `az login` device-code flow).
   - `sudo certbot certonly --authenticator dns-azure ...` for `metis.rhombus.rocks` (cert).
   - Bitwarden: launch, log in, enable "Unlock with system keyring", enable SSH agent.
   - Re-seal BitLocker on Windows side (INSTALL-RUNBOOK §C: `manage-bde -protectors -disable/-enable C:`).
   - Test SSH from Callisto.

### What's pending — phase 3.5 (deferred 2-in-1 hardware tuning)
See `runbook/phase-3.5-hardware-handoff.md`. The relevant packages (iio-sensor-proxy, iio-hyprland-git, hyprgrass, libwacom, wvkbd) are already installed by postinstall — phase-3.5 is per-device tuning + tablet-mode wiring + pen calibration, not bulk install.

## User preferences (carried forward)

- **Decisive over cautious.** Pick the opinionated default; discuss only if truly ambiguous.
- **Terminal + Claude Code (CLI) + RDP client + VSCode + browser** workflow. Future Windows VM.
- **Ghostty** as daily terminal. Theme is **matugen** (Material You from wallpaper) — Catppuccin is gone everywhere.
- **tmux required** (Ctrl+a prefix) for Claude Code's worktree workflow. Config in chezmoi at `dotfiles/dot_tmux.conf`; colors come from a matugen-rendered template; sesh handles the worktree-per-session picker.
- **Sudo cache 4h**, NOT Claude-as-root. Run `sudo -v` to refresh — there's no command to check remaining time.
- Dotfiles managed by **chezmoi** — no stow/symlinks.
- User does NOT enjoy config tweaking — but Claude doing it is fine. Result: bare Hyprland + chezmoi, NOT an opinionated dotfile pack.
- Always commit on task completion; **atomic commits** (one logical change per commit); push on feature completion. Commit messages explain the "why", not the "what".
- **Work in parallel** when tasks are independent. Single message with multiple tool calls, not serialized.
- User uses dictation — expect occasional "memory test" ↔ "speed test", "zsh" ↔ "this is zsh" confusions. Trust the user's stated intent over the dictation surface.

## Known gotchas (current design)

- **`pnpm pdf` on Linux** needs `EDGE=/usr/bin/microsoft-edge-stable` — the script's locateEdge() only checks Windows paths.
- **SSH-signed commits** require `SSH_AUTH_SOCK=/home/tom/.bitwarden-ssh-agent.sock` exported before `git commit`. Bitwarden desktop must be running with the SSH-agent toggle on.
- **BitLocker doesn't auto-reseal** on recovery-key entry. Must manually `manage-bde -protectors -disable/-enable` after boot-chain changes (limine install, kernel update with chained signing). Pacman hook `95-tpm2-reseal.hook` automates Linux side; Windows side is manual once.
- **Goodix touchscreen** uses `hid-multitouch`, NOT IPTS. IPTS is Surface-only; the prior `iptsd` recommendation in older `phase-3.5-hardware-handoff.md` revisions was wrong, has been corrected.
- **Wacom on Wayland**: `libwacom` + kernel `wacom` driver only. NOT `xf86-input-wacom`.
- **`pinpam-git`** ships its module as `libpinpam.so` (not `pam_pinpam.so`). PAM stack files reference `libpinpam.so` literally — the wrong name dlopen-fails silently.
- **`az ad sp create-for-rbac --years 2`** is broken under Python 3.14 + azure-cli 2.85.0 (argparse `%Y` bug). `setup-azure-ddns.sh` works around this with the piecemeal `ad app` / `ad sp` / `app credential reset` flow.
- **TPM PIN setup can succeed silently while the NV write fails** (NV index conflict with BitLocker / LUKS-TPM2). postinstall §7 runs `pinutil test < /dev/null` after setup as a smoke test.

## Working branch

As of this handoff: **`desktop-design`** (not yet merged to main). Once the reinstall is verified end-to-end on Metis, merge to main and delete the branch.

## Starter prompt you can paste to the new session

> Read `docs/session-handoff.md` end-to-end, then `docs/decisions.md` and `runbook/INSTALL-RUNBOOK.md`. Confirm you understand the current state — the design is locked-in on the `desktop-design` branch but the actual reinstall hasn't run yet. Then wait for my next instruction.
