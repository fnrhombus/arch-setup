# Phase 3.5 — 2-in-1 Hardware Handoff

**You are Claude Code, invoked inside a booted Arch system sometime after the user finished Phase 2 + Phase 3. They have been using the laptop for a while and are now ready to wire the 2-in-1 specific hardware that the base install deliberately skipped.**

Read this doc fully before touching anything. Then read `../docs/decisions.md` (for hardware + system context) and `phase-3-handoff.md` (for user preferences and overall stack — in the same directory as this file).

---

## Context

The user's machine is a **Dell Inspiron 7786** — a 17" 2-in-1 convertible (laptop → tent → tablet). `phase-3-arch-postinstall/postinstall.sh` installed the base system (bare Hyprland with Claude-authored configs in chezmoi, matugen theme, fingerprint, TPM-PIN, Bitwarden, Ghostty, tmux, etc.) but deliberately did NOT *configure* the 2-in-1 touch/pen/rotation hardware end-to-end. Most of the *packages* are already installed (see below) — what's left is per-device tuning and verification on real hardware.

Those pieces were deferred because each has real tuning surface — doing them blind during the install would produce fragile config and make the first-boot experience noisier than it needs to be. Better approach: get the base system solid, let the user live with it for a week, then wire these one at a time with real-time feedback.

### What's already working (don't re-do these)

- Fingerprint (Goodix 27C6) for sudo/polkit/hyprlock
- TPM-PIN via pinpam for the same services
- Internal display (Intel UHD 620, Wayland-native)
- External HDMI monitor (wired directly to iGPU)
- Basic touchscreen input (Hyprland treats it like a mouse via `hid-multitouch`)
- Keyboard + touchpad (libinput defaults)
- Bluetooth, Wi-Fi, suspend/resume, hibernate (TPM2-sealed cryptswap)

### What's installed but unverified / untuned

postinstall.sh §1 + §3 already pacman/yay-installed the relevant packages. The work in this phase is **enabling, configuring, and validating on real hardware**, not fresh install:

- `iio-sensor-proxy` (accelerometer service) + `iio-hyprland-git` (Hyprland accel→transform bridge) — installed, may need enabling + per-output transform mapping
- `hyprgrass` (Hyprland touch-gesture plugin) — loaded via `hyprpm` in §14; needs gesture bindings in `binds.conf` to actually do anything useful
- `libwacom` + kernel `wacom` driver (in-tree) — both present; tuning needed once a Wacom device is plugged in
- `wvkbd` (on-screen keyboard for tablet mode) — installed; not auto-launched yet

### What's genuinely deferred (no package, no config)

From `decisions.md` Requirements (checkboxes still `[ ]`):

- [ ] Tablet-mode detection. The 7786 does NOT have a dedicated `SW_TABLET_MODE` hinge sensor — Dell 2-in-1s of this era use ACPI events from `intel-vbtn` (codes 0xCC enter / 0xCD exit), which the kernel synthesizes into `SW_TABLET_MODE` on a virtual `Intel HID events` input device. Verify with `evtest` on `/dev/input/event*` for that name post-install. Then disable physical kbd, autostart `wvkbd-mobintl`, reflow waybar.
- [ ] Pen pressure curve / button mapping for the **external Wacom Intuos** (when plugged in).
- [ ] Three-finger swipe / pinch gesture bindings via `hyprgrass`.

> Active pen note: the 17" 7786 has **capacitive touch only**, no built-in active digitizer. Only the 13"/15" 7000-series 2-in-1s (7386, 7586) shipped the AES pen.

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
- **ELAN touchscreen** on the i2c bus (NOT USB), exposed as `ELAN2097:00 04F3:2666` (or similar — the 04F3 vendor is ELAN). Bound by `i2c-hid-acpi` → `hid-multitouch`. **NOT Goodix** — that's the fingerprint reader (`27c6:538c`); the Goodix-on-the-touchscreen claim in older versions of this doc was wrong. **NOT IPTS** either — IPTS is Surface-line only; do not install `iptsd`.
- **Accelerometer** as `/sys/bus/iio/devices/iio:deviceN` — `iio-sensor-proxy` already installed; needs `systemctl enable --now iio-sensor-proxy.service` if not yet enabled.
- **External Wacom Intuos** on USB — appears as a Wacom device node, handled natively by libinput on Wayland.
- **Tablet-mode signaling** via ACPI `intel-vbtn` (NOT a dedicated `SW_TABLET_MODE` hinge sensor). The driver synthesizes a virtual input device named `Intel HID events`; that's where `SW_TABLET_MODE` events fire when you fold the screen. `evtest` on that device with the screen folding will confirm.

> The 7786 has **capacitive touch only** — no built-in active pen / AES digitizer. Don't waste time looking for a stylus device beyond the second `ELAN2097 ... UNKNOWN` channel (which is unused on this hardware).

If any of those are missing, halt and investigate — don't install downstream packages blindly.

---

## Approach: one script per subsystem, each independently runnable

Create `phase-3.5-hardware/` as a sibling to the other phase dirs. Under it:

```
phase-3.5-hardware/
  00-probe.sh                  # runs all the lsusb/libinput/iio probes, dumps to ~/phase-3.5-probe.log
  10-touchscreen-verify.sh     # confirm i2c-hid-acpi → hid-multitouch binds the ELAN screen; tune palm rejection
  20-auto-rotation.sh          # enable iio-sensor-proxy, wire iio-hyprland for per-output transform
  30-touch-gestures.sh         # hyprgrass gesture bindings (already loaded via hyprpm)
  40-wacom-external.sh         # libinput tuning for the Intuos (pressure curve, button binds)
  50-wacom-builtin-pen.sh      # built-in active pen calibration (if present)
  60-tablet-mode.sh            # SW_TABLET_MODE listener → disable kbd, autostart wvkbd, flip rotation lock
```

**Rules:**
- Each script is idempotent — safe to re-run.
- Each prints `[+] what it did` on success, `[!] what it skipped and why` on soft fail, `[✗] what blocks progress` on hard fail.
- Never run more than one at a time. After each, ask the user to test the affected function before moving on.
- If any script's test fails, roll back with snapper (`sudo snapper -c root list` → `sudo snapper -c root undochange ID..0`).

### Sketch of each subsystem

**10 — Touchscreen verify + tune**
- Confirm `hid-multitouch` is bound: `cat /sys/class/input/event*/device/driver/uevent | grep -i multitouch`
- Test multi-touch with `libinput debug-events`; finger taps, swipes register
- If palm rejection is poor under typing, tweak via libinput hwdb override (`/etc/libinput/local-overrides.quirks`)
- **Do NOT install `iptsd`** — wrong driver class for this Goodix part

**20 — Auto-rotation**
- `iio-sensor-proxy` already installed by postinstall §1; enable: `sudo systemctl enable --now iio-sensor-proxy.service`
- `iio-hyprland-git` already installed by postinstall §3; spawn it from Hyprland: `exec-once = iio-hyprland`
- Test: physically rotate the laptop; eDP-1 transform should follow

**30 — Touch gestures (hyprgrass)**
- `hyprgrass` already loaded via `hyprpm` in postinstall §14
- Add bindings to `dot_config/hypr/binds.conf` in [rhombu5/dots](https://github.com/rhombu5/dots) using the new `gesture = ...` syntax (Hyprland 0.51+) — three-finger swipe left/right → workspace prev/next, three-finger up → hyprexpo. Edit via `chezmoi edit ~/.config/hypr/binds.conf` then `chezmoi cd` to commit + push to dots.
- Re-run `chezmoi apply`; the validator will catch dispatcher typos

**40 — External Wacom Intuos** *(only if user plugs one in)*
- `libwacom` + kernel `wacom` driver: both already present (no `xf86-input-wacom` needed under Wayland)
- Probe: `libinput-list-devices | grep -A20 -i wacom` once plugged in (`libinput-list-devices` from the `libinput-tools` package, not `libinput`)
- Tune via Hyprland's `device:` block in `input.conf` (pressure curve, button mapping)
- Persist via the chezmoi-managed `input.conf` fragment

**50 — Built-in active pen** *(removed: 7786 doesn't have one)*
- The 17" 7786 is **capacitive-only**, no AES digitizer. Skip this script. Only the 13"/15" 7000-series 2-in-1s (7386, 7586) shipped active pens.

**60 — Tablet mode**
- The 7786 does NOT have a `SW_TABLET_MODE` hinge sensor. Tablet-mode comes from ACPI `intel-vbtn` synthesizing the event on a virtual input device named `Intel HID events`. `evtest /dev/input/event*` against that device, fold the screen — should see `SW_TABLET_MODE` value 1 ↔ 0 transitions.
- **Wired in postinstall.sh §1d (already installed):**
  - udev rule `/etc/udev/rules.d/99-tablet-mode.rules` watches `ATTRS{name}=="Intel HID events"` and writes `SW_TABLET_MODE` to `/run/tablet-mode/state` on each `change` event.
  - User-level `~/.config/systemd/user/tablet-mode-watch.path` notices the write and triggers `tablet-mode.service`, which runs `~/.local/bin/tablet-mode-toggle --detect`.
  - `tablet-mode-toggle` queries `hyprctl devices -j` to discover the actual kbd (`at-translated-set-2-keyboard`) + touchpad (`dell0896:00-04f3:30b6-touchpad`) names, then `hyprctl keyword device:NAME:enabled false/true` to toggle them. On tablet entry it also `setsid -f wvkbd-mobintl --hidden` (kills it on exit).
  - Manual override binding: `SUPER+ALT+K` → `tablet-mode-toggle --toggle` (forces a flip if auto-detect misfires).
- **First test on real hardware** (priority — never validated):
  1. `lsmod | grep intel_vbtn` — must show the module loaded. If absent, `sudo modprobe intel_vbtn`.
  2. `sudo evtest` → pick the `Intel HID events` device → fold the screen. Expect `SW_TABLET_MODE` value transitions.
  3. `sudo udevadm monitor --environment --subsystem-match=input` while folding — expect `ACTION=change` events with `SW_TABLET_MODE=1` (or 0).
  4. `cat /run/tablet-mode/state` after a fold — expect `1`.
  5. `systemctl --user status tablet-mode.service` — expect a recent activation; check journalctl for `[tablet-mode]` lines.
  6. `hyprctl devices` — confirm the actual kbd+touchpad names. If they don't match the discover_devices() heuristic in `tablet-mode-toggle`, tweak the jq filter.
- **Still TODO** (out of scope for this commit, part of issue #6):
  - Touchscreen palm rejection while typing in laptop mode (libinput `disable-while-typing` covers the touchpad but not the touchscreen — needs a `quirks` override or a userspace daemon).
  - Pen pressure curve / button mapping (no built-in pen on the 7786, only external Wacom Intuos when plugged in — handled in §40 of this doc).
  - hyprgrass-dependent gestures (three-finger swipe, pinch zoom in tablet mode).
  - waybar profile flip — tablet-mode-toggle does NOT yet swap waybar layouts (small-screen-friendly variant). Add a `pkill -SIGUSR1 waybar` + per-mode waybar config split if needed.

---

## Ordering rationale

Do touchscreen first because the user can fall back to keyboard/trackpad if anything else breaks — the touchscreen working or not doesn't block recovery. Rotation second because tablet mode depends on it. Gestures are low-risk and can slot in whenever. Wacom last because the external tablet isn't always connected and the built-in pen only matters in tablet mode.

---

## Non-goals for this phase

- **Don't** touch the PAM stack, Bitwarden wiring, or Hyprland theme/keybinds (other than adding gesture bindings to `binds.conf`).
- **Don't** install `iptsd` — Goodix on this Dell uses `hid-multitouch`, not the IPTS protocol.
- **Don't** install `xf86-input-wacom` — Wayland uses libinput + the kernel `wacom` driver natively.
- **Don't** reinstall fingerprint / TPM-PIN; they're already enrolled.
- **Don't** upgrade kernels or swap kernel flavors as part of this phase.

If the user asks for one of these, it's a separate conversation.

---

## Test strategy per subsystem

After each script, the user runs a specific check:

| Script | Test |
|---|---|
| 10 touchscreen | Open Krita or GIMP; finger-touch + multi-touch both register; no spurious touches while typing |
| 20 rotation | Physically flip the laptop; display reorients within ~1s |
| 30 gestures | Three-finger swipe in Hyprland switches workspace |
| 40 wacom-ext | Draw in Krita or GIMP; pressure works, buttons do what's configured |
| 50 wacom-builtin | Same as 40 with the built-in pen (if present) |
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
