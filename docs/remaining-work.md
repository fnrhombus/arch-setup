# Remaining work

Ordered snapshot of what's still open across the arch-setup repo as of 2026-04-23. Update as items land. Format: `- [ ]` for open, `- [x]` for done — same convention as `decisions.md`.

## On the dev machine (Phase 0 — USB prep)

- [ ] `pnpm i` to download Arch ISO + Win11 ISO + Ventoy + stage everything onto the Ventoy USB.

## On Metis (Phase 1-3 — fresh install)

- [ ] Pre-flight: `fwupdmgr update` (Dell BIOS 1.16 → 1.18+); back up keepers from `/home/tom` not in Bitwarden; confirm Samsung 840 PRO + Netac 128 GB both present.
- [ ] **Phase 1 (Windows)**: F12 → Ventoy → Win11 ISO → unattended install via `autounattend.xml` (~30 min). Stash BitLocker recovery key in Bitwarden as **"Metis BitLocker recovery"** during phase-1 step 7.
- [ ] **Phase 2 (Arch)**: F12 → Ventoy → Arch ISO → live env. `git clone https://github.com/fnrhombus/arch-setup /tmp/arch-setup && bash /tmp/arch-setup/phase-2-arch-install/install.sh`. ~40 min, mostly unattended after the password prompts.
- [ ] **Phase 3 (postinstall on Metis)**: TTY login as `tom`, `~/postinstall.sh`. ~25 min (yay builds dominate). Includes printer driver install (Canon Pro 9000 Mk II via gutenprint) + chezmoi apply + matugen seed.

## On Metis (post-postinstall one-time actions)

- [ ] `~/setup-azure-ddns.sh` after `az login` device-code flow. Confirm `dig AAAA metis.rhombus.rocks` resolves.
- [ ] `sudo certbot certonly --authenticator dns-azure ...` for `metis.rhombus.rocks`.
- [ ] Bitwarden desktop: log in once, enable "Unlock with system keyring", enable SSH agent.
- [ ] Re-seal BitLocker on Windows side (INSTALL-RUNBOOK §C: `manage-bde -protectors -disable/-enable C:`) so subsequent boots don't keep prompting for the recovery key.
- [ ] Test SSH from Callisto to `tom@metis.rhombus.rocks` (Callisto pubkey already in `~/.ssh/authorized_keys`).
- [ ] Verify pass with `~/postinstall.sh` (no `--no-verify`). Re-run after each one-time action lands; expect a few items to FAIL until they're done (DDNS env file empty pre-`setup-azure-ddns.sh`, LE cert absent until issuance, etc.).
- [ ] Tick the fingerprint / lid / RDP checkboxes in `decisions.md` if everything tests clean.
- [ ] (Deferred) Pick a live-desktop remote tool (wayvnc vs Sunshine vs RustDesk) and wire it into postinstall. Research already done — user is punting for now.

## Phase 3.5 (2-in-1 hardware validation on real hardware)

See `runbook/phase-3.5-hardware-handoff.md` for the full handoff. Packages are already installed by postinstall §1 + §3; this phase is per-device tuning + tablet-mode wiring + pen calibration.

- [ ] Confirm touch-panel chipset via `dmesg | grep -i -E 'wacom|goodix|hid-multitouch'`.
- [ ] Test `iio-hyprland` auto-rotation when flipping to tablet mode.
- [ ] Test `wvkbd-mobintl` on-screen keyboard toggle (ideally via a hyprgrass long-press gesture).
- [ ] Tablet-mode detection: write udev rule binding `SW_TABLET_MODE` events to an OSK-toggle + keyboard/touchpad-disable script.
- [ ] Palm rejection: `LIBINPUT_ATTR_PALM_PRESSURE_THRESHOLD` quirk + Hyprland `input:touchpad:disable_while_typing = true`.
- [ ] Confirm Wacom AES stylus pressure/tilt in Krita or Xournal++. Eraser end may need a udev quirk.

## Pre-existing carry-forwards

- [ ] memtest86+ full pass (boot the limine `/Memtest86+` chainload entry).
- [ ] Fan inspection / clean (laptop has a thermal-throttle quirk flagged earlier in the session but never documented as a decision).
- [ ] Write up the thermal-threshold quirk in `decisions.md` once observed behavior is clear.

## `staged-azure-ddns/` → `fnrhombus/azure-ddns` split-out

The `staged-azure-ddns/` directory in this repo is the shape of the future standalone repo. **Its own dedicated handoff for the new-repo Claude session lives at [`staged-azure-ddns/HANDOFF.md`](../staged-azure-ddns/HANDOFF.md)** — that doc is self-contained and briefs a cold-start session on everything it needs to do (verify PKGBUILD, tag v0.1.0, AUR submission, known gaps, design choices to preserve).

User asked to keep the new repo private initially (AUR / public release after one-user success).

- [ ] Create private repo `fnrhombus/azure-ddns` on GitHub.
- [ ] Copy `staged-azure-ddns/*` to the new repo's root (keep directory structure).
- [ ] Hand the new session `staged-azure-ddns/HANDOFF.md` — it takes over from there.
- [ ] Once the new repo is live, replace `arch-setup/phase-3-arch-postinstall/metis-ddns/` with a submodule pointing at it, or keep it as-is and sync manually on changes.

## Repo hygiene

- [ ] Once the reinstall is verified end-to-end on Metis, merge `desktop-design` → `main` and delete the branch.
- [ ] `INSTALL-RUNBOOK.pdf` regeneration (`pnpm pdf`) after any `runbook/*.md` changes since last render. The print-ready PDF is the "at the laptop" artifact; markdown drift without PDF re-render makes the physical printout stale. (On Linux, set `EDGE=/usr/bin/microsoft-edge-stable`.)
