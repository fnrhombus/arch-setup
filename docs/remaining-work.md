# Remaining work

Ordered snapshot of what's still open across the arch-setup repo as of 2026-04-21. Update as items land. Format: `- [ ]` for open, `- [x]` for done — same convention as `decisions.md`.

## On the laptop (after next `fnpostinstall` run)

- [ ] Re-run `postinstall.sh` after the end-4 → HyDE swap. HyDE will clobber `~/.config/hypr/*` into `~/.config/cfg_backups/<timestamp>/`. The sed for `$term → ghostty` may not match if HyDE's actual variable name differs — confirm Super+Return launches Ghostty after reboot. Fallback: edit `~/.config/hypr/keybindings.conf` by hand.
- [ ] Verify pass with `./postinstall.sh` (no `--no-verify`). Expect some items to FAIL the first time — Bitwarden desktop has to unlock once before `ssh-add -l` works, `/etc/metis-ddns.env` has to be filled before the DDNS service runs, the LE cert only exists after issuance. Re-run after each one-time action lands.
- [ ] Bitwarden desktop unlock + SSH agent toggle on.
- [ ] Azure DDNS one-time SP creation (runbook §3e-bis). Fill `/etc/metis-ddns.env`, kick `metis-ddns.service`, confirm `dig AAAA metis.rhombus.rocks` resolves externally.
- [ ] Let's Encrypt cert issuance for `metis.rhombus.rocks` (runbook §3e-ter). Only useful once DDNS resolves.
- [ ] Test SSH from Callisto against the laptop. `ssh tom@metis.rhombus.rocks` should accept the Callisto key and refuse passwords.
- [ ] Tick the fingerprint / lid / RDP checkboxes in `decisions.md` if everything tests clean.
- [ ] (Deferred) Pick a live-desktop remote tool (wayvnc vs Sunshine vs RustDesk) and wire it into postinstall. Research already done — user is punting for now.

## Phase-3.5 (2-in-1 hardware validation on real hardware)

- [ ] Confirm touch-panel chipset via `dmesg | grep -i -E 'wacom|goodix|hid-multitouch'`. `decisions.md` assumes Wacom AES but the 7786 revision varies.
- [ ] Test `iio-hyprland` auto-rotation when flipping to tablet mode.
- [ ] Test `wvkbd-mobintl` on-screen keyboard toggle (ideally via a hyprgrass long-press gesture).
- [ ] Tablet-mode detection: write udev rule binding `SW_TABLET_MODE` events to an OSK-toggle + keyboard/touchpad-disable script.
- [ ] Palm rejection: `LIBINPUT_ATTR_PALM_PRESSURE_THRESHOLD` quirk + Hyprland `input:touchpad:disable_while_typing = true`.
- [ ] Confirm Wacom AES stylus pressure/tilt in Krita or Xournal++. Eraser end may need a udev quirk.

## Pre-existing todos carried forward

- [ ] memtest86+ full pass (boot from Arch recovery partition).
- [ ] Fan inspection / clean (laptop has a thermal-throttle quirk flagged earlier in the session but never documented as a decision).
- [ ] Write up the thermal-threshold quirk in `decisions.md` once observed behavior is clear.

## `staged-azure-ddns/` → `fnrhombus/azure-ddns` split-out

The `staged-azure-ddns/` directory in this repo is the shape of the future standalone repo. **Its own dedicated handoff for the new-repo Claude session lives at [`staged-azure-ddns/HANDOFF.md`](../staged-azure-ddns/HANDOFF.md)** — that doc is self-contained and briefs a cold-start session on everything it needs to do (verify PKGBUILD, tag v0.1.0, AUR submission, known gaps, design choices to preserve).

User asked to keep the new repo private initially (AUR / public release after one-user success).

**I (Claude on Claude-Code-on-the-web) cannot create the repo** — my GitHub MCP tools are scoped to `fnrhombus/arch-setup` only. The user (or a Claude Code session with broader scope) needs to do the create step.

- [ ] Create private repo `fnrhombus/azure-ddns` on GitHub.
- [ ] Copy `staged-azure-ddns/*` to the new repo's root (keep directory structure).
- [ ] Hand the new session `staged-azure-ddns/HANDOFF.md` — it takes over from there.
- [ ] Once the new repo is live, replace `arch-setup/phase-3-arch-postinstall/metis-ddns/` with a submodule pointing at it, or keep it as-is and sync manually on changes.

## Repo hygiene

- [ ] Once HyDE is confirmed working on the laptop, remove the "end-4 wizard shim" language everywhere in `decisions.md` / `runbook/` / `CLAUDE.md` — most already flipped, but there may be a straggler or two I missed.
- [ ] `INSTALL-RUNBOOK.pdf` regeneration (`pnpm pdf`) after any `runbook/*.md` changes since last render. The print-ready PDF is the "at the laptop" artifact; markdown drift without PDF re-render makes the physical printout stale.
