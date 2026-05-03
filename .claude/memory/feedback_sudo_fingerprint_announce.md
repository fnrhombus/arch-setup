---
name: notify-send before sudo (fingerprint cue)
description: Use the `sudonf` wrapper for any sudo/polkit auth — fires a Critical notification (which swaync also plays a sound on) and auto-dismisses it once auth resolves.
type: feedback
originSessionId: 1f608502-800c-4723-a701-24396c206988
---
Before running ANY `sudo` command (or anything that triggers polkit auth: `pkexec`, `pacman -S/-U/-R`, `tee /etc/...`, `systemctl restart` of root services, AUR `makepkg -si`, etc.), use the `sudonf` wrapper so the user sees a clear cue to fingerprint AND swaync plays a Critical-urgency sound.

**Why:** The fingerprint reader prompt fires inside the tool call and is invisible in the rendered chat output. Terminal bell `\a` did NOT work in user's terminal (Ghostty — bell is silent or visual-only off-screen). swaync's `critical-sound` script (`paplay dialog-warning.oga` on `urgency: Critical`) plus a notify-send confirmed working 2026-05-02. The user explicitly asked (2026-05-02) that fingerprint notifications NOT pile up in swaync after auth — `sudonf` dismisses the notification once sudo returns.

**How to apply:**
- Default form:
  ```bash
  sudonf '<short message>' <sudo args>
  ```
  e.g. `sudonf 'pacman -S blueman' pacman -S blueman`. The wrapper lives at `~/.local/bin/sudonf` (chezmoi-managed in [rhombu5/dots](https://github.com/rhombu5/dots)).
- The `<short message>` should hint what's about to run so the user can scan back and see what triggered the fingerprint cue.
- Multi-step sudo sequence in one Bash: still only `sudonf` at the top — sudo's `timestamp_timeout` (~5 min default) covers subsequent plain `sudo` calls in the same window without re-prompting.
- Across multiple Bash calls within ~5 min: same — only the first call needs `sudonf`. Further sudos within the timestamp window won't re-prompt, so no fresh notification needed.
- Polkit/pkexec — same pattern works (the wrapper still emits the notification, and the polkit-agent dialog is the actual auth UI).
- After the sudo sequence, say "no more sudo for the rest of this batch" so the user can stop watching the sensor.

**Don't:**
- Don't fall back to raw `notify-send + sudo` without dismissing — leftover Critical notifications keep replaying their sound the next session and clutter swaync.
- Don't use `printf '\a'` / terminal bell — verified silent in this environment.
- Don't use `paplay` directly for a cue — `sudonf`'s notification triggers swaync's critical-sound script automatically, no need to play sounds out-of-band.
