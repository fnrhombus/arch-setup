# Phase 3.5 — 2-in-1 Hardware Handoff

**You are Claude Code, invoked inside a booted Arch system sometime after the user finished the base install (phases 1–3 of `INSTALL-RUNBOOK.md`). They have been using the laptop for a while and are now ready to wire the 2-in-1 specific hardware that the base install deliberately skipped.**

Read this doc fully before touching anything. Then read `decisions.md` (for hardware + system context) and `handoff.md` (for user preferences and overall stack). Both should be in the same directory as this file.

---

## Context

The user's machine is a **Dell Inspiron 7786** — a 17" 2-in-1 convertible (laptop → tent → tablet). `phase-3-arch-postinstall/postinstall.sh` installed the base system (Hyprland via end-4 dotfiles, fingerprint, TPM-PIN, Bitwarden, Ghostty, tmux, etc.) but deliberately did NOT configure the 2-in-1 touch/pen/rotation hardware.

Those pieces were deferred because each has real tuning surface — doing them blind during the install would produce fragile config and make the first-boot experience noisier than it needs to be. Better approach: get the base system solid, let the user live with it for a week, then wire these one at a time with real-time feedback.

### What's already working (don't re-do these)

- Fingerprint (Goodix 27C6) for sudo/polkit/hyprlock
- TPM-PIN via pinpam for the same services
- Internal display (Intel UHD 620, Wayland-native)
- External HDMI monitor (wired directly to iGPU)
- Basic touchscreen input (Hyprland treats it like a mouse)
- Keyboard + touchpad (libinput defaults)
- Bluetooth, Wi-Fi, suspend/resume

### What's NOT working / not configured

From `decisions.md` Requirements (checkboxes still `[ ]`):

- [ ] Wacom Intuos pen tablet support (the user's EXTERNAL Wacom Intuos, plus the 7786's BUILT-IN active pen)
- [ ] Touch gestures (two-finger scroll already works; three-finger middle-click / swipe back-forward do not)
- [ ] Auto-rotation when the screen is flipped into tent/tablet mode
- [ ] Tablet mode detection (should disable keyboard, enable on-screen keyboard, reflow waybar)

---

## Hardware specifics to probe before doing anything

Run these first and save the output in scratch files. You'll need them when debugging:

```bash
lsusb                              # USB devices (Wacom external pen tablet appears here)
libinput list-devices              # every input device libinput sees
cat /proc/bus/input/devices        # fuller view incl. accelerometer
udevadm info --query=all --name=/dev/input/eventN   # for each event device
ls /sys/bus/iio/devices/           # accelerometer / gyro IIO devices
journalctl -b | grep -iE 'wacom|iptsd|iio|accel'
```

Expected to find:
- **Goodix touchscreen** on USB VID 27C6 — likely IPTS (Intel Precise Touch Stylus). Needs `iptsd`.
- **Accelerometer** as `/sys/bus/iio/devices/iio:deviceN` — used for auto-rotation via `iio-sensor-proxy`.
- **External Wacom Intuos** on USB — appears as a Wacom device node, usually handled by `xf86-input-wacom` or libinput.
- **Built-in active pen** — routed through the same IPTS stack as the touchscreen.

If any of those are missing, halt and investigate — don't install downstream packages blindly.

---

## Approach: one script per subsystem, each independently runnable

Create `phase-3.5-hardware/` as a sibling to the other phase dirs. Under it:

```
phase-3.5-hardware/
  00-probe.sh                  # runs all the lsusb/libinput/iio probes, dumps to ~/phase-3.5-probe.log
  10-touchscreen-iptsd.sh      # Intel Precise Touch daemon for Goodix screen
  20-auto-rotation.sh          # iio-sensor-proxy + hyprland per-output transform
  30-touchpad-gestures.sh      # libinput-gestures or Hyprland native binds
  40-wacom-external.sh         # xf86-input-wacom tuning for the Intuos
  50-wacom-builtin-pen.sh      # built-in active pen via IPTS
  60-tablet-mode.sh            # ACPI tablet-mode switch → disable kbd, flip rotation lock
```

**Rules:**
- Each script is idempotent — safe to re-run.
- Each prints `[+] what it did` on success, `[!] what it skipped and why` on soft fail, `[✗] what blocks progress` on hard fail.
- Never run more than one at a time. After each, ask the user to test the affected function before moving on.
- If any script's test fails, roll back with snapper (`sudo snapper -c root list` → `sudo snapper -c root undochange ID..0`).

### Sketch of each subsystem

**10 — Touchscreen / iptsd**
- `yay -S iptsd` (or `iptsd-git` if stable has drifted)
- Enable `iptsd.service`
- Reboot, test: finger touch, pen touch (if built-in pen), multi-touch

**20 — Auto-rotation**
- `sudo pacman -S iio-sensor-proxy`
- Enable `iio-sensor-proxy.service`
- Hyprland config: use `exec-once = hyprctl keyword ...` or a helper like [iio-hyprland](https://github.com/JeanSchoeller/iio-hyprland) to translate accelerometer orientation → `monitor=,transform,N`
- Test: physically rotate the laptop; screen should follow

**30 — Touchpad gestures**
- Check if end-4's Hyprland config already has gesture binds (`grep -ri gesture ~/.config/hypr`)
- If yes, tune; if no, add binds for three-finger swipe left/right → workspace switch, three-finger up → overview (if `hypr-plugins` is installed)
- Three-finger middle-click + tap-drag need libinput properties (`libinput debug-events` will show what the kernel reports)

**40 — External Wacom Intuos**
- `sudo pacman -S libwacom xf86-input-wacom` (the X driver is still used for tablet-area mapping even under Wayland, via XWayland)
- Probe with `xsetwacom --list devices` once plugged in
- Set area, pressure curve, button binds via `xsetwacom`
- Persist via udev rule + systemd-user service

**50 — Built-in active pen**
- Inherits iptsd from step 10 — usually "just works" once iptsd is up
- Tune pressure sensitivity if needed

**60 — Tablet mode**
- Listen for ACPI event `video/tabletmode` (check `acpi_listen`)
- On entering tablet mode: `hyprctl keyword input:kb_file ""` (disable physical kbd), launch `wvkbd-mobintl` (on-screen keyboard), waybar profile flip
- On exiting: reverse it
- Wire as a systemd user service watching the ACPI event node, or as a hyprland `exec` bound to a keybind if ACPI integration is flaky

---

## Ordering rationale

Do touchscreen first because the user can fall back to keyboard/trackpad if anything else breaks — the touchscreen working or not doesn't block recovery. Rotation second because tablet mode depends on it. Gestures are low-risk and can slot in whenever. Wacom last because the external tablet isn't always connected and the built-in pen only matters in tablet mode.

---

## Non-goals for this phase

- **Don't** touch the PAM stack, Bitwarden wiring, or Hyprland theme/keybinds.
- **Don't** run `end-4/illogical-impulse`'s installer again — its questions are designed for fresh installs and will ask things that only make sense in context.
- **Don't** reinstall fingerprint / TPM-PIN; they're already enrolled.
- **Don't** upgrade kernels or swap kernel flavors as part of this phase.

If the user asks for one of these, it's a separate conversation.

---

## Test strategy per subsystem

After each script, the user runs a specific check:

| Script | Test |
|---|---|
| 10 iptsd | Open `xeyes` or a drawing app; finger-touch and pen-touch both register |
| 20 rotation | Physically flip the laptop; display reorients within ~1s |
| 30 gestures | Three-finger swipe in Hyprland switches workspace |
| 40 wacom-ext | Draw in Krita or GIMP; pressure works, buttons do what's configured |
| 50 wacom-builtin | Same as 40 with the built-in pen |
| 60 tablet-mode | Flip into tablet mode; keyboard disables, on-screen keyboard appears |

If a test fails, don't move on. Debug, fix, re-test. Document the cause in a new recovery section of `INSTALL-RUNBOOK.md` if it's likely to hit other users of this hardware.

---

## Commit hygiene

Each subsystem gets its own commit with the pattern `phase-3.5: <subsystem> (script + runbook update)`. No squashing across subsystems. That way if subsystem 40 breaks later, `git bisect` lands on the exact commit.

Update `decisions.md`'s Requirements checkboxes as each subsystem passes its test.

---

## When you're done

- All checkboxes in `decisions.md` Requirements section are ticked.
- `phase-3.5-hardware/00-probe.sh` → `60-tablet-mode.sh` are committed, idempotent, and synced to the Ventoy USB (same as `phase-2-arch-install/` and `phase-3-arch-postinstall/` are today).
- `INSTALL-RUNBOOK.md`'s "Things you should know → Coming later" section can be rewritten to reference phase-3.5 as *done* rather than *pending*.
- The user can factory-reset the laptop and reproduce the full 2-in-1 experience from scratch by running phases 1 → 2 → 3 → 3.5 in order.
