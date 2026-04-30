# Tablet-mode signal path on the Inspiron 7786

Empirical findings from a live laptop session on 2026-04-29 (kernel
7.0.2-arch1-1, intel-hid driver), captured to keep future tablet-mode
work from chasing the wrong device.

## TL;DR

The `SW_TABLET_MODE` signal on this 7786 lives on a **dynamically
materialized** input device named `Intel HID switches`, NOT on the
obvious-looking, statically present `Intel HID events`. The kernel
creates the switches device the first time the screen folds back; it
persists for the rest of the boot. Any udev rule or daemon that keys
on `Intel HID events` and waits for `SW_TABLET_MODE` will silently
never fire.

## Hardware enumeration

```
DMI:           Dell Inc. / Inspiron 7786
ACPI present:  INT33D2..INT33D5 (no INT33D6, no INTC10*)
Driver bound:  /sys/devices/platform/INT33D5:00 → intel_hid
Modules:       intel_hid, hid_sensor_custom_intel_hinge, hid_sensor_*
intel_vbtn:    NOT loaded — matches INT33D6 only; not present here
```

Note: any documentation or design comment that says `intel_vbtn`
synthesizes `SW_TABLET_MODE` for this laptop is wrong. On this BIOS
revision the binding goes to `intel_hid` only.

Static input devices created by `intel_hid` at boot:

| sysfs                                          | name                       | EV    | SW | handler |
|------------------------------------------------|----------------------------|-------|----|---------|
| `/devices/platform/INT33D5:00/input/input21`   | `Intel HID events`         | 0x13  | 0  | event7  |
| `/devices/platform/INT33D5:00/input/input22`   | `Intel HID 5 button array` | 0x13  | 0  | event12 |

`EV=0x13` = `EV_SYN | EV_KEY | EV_MSC`. **Neither has `EV_SW`.**

## What happens when you fold the screen

`udevadm monitor --kernel --udev --environment` while folding back
~360°:

```
KERNEL[6291.028470] add /devices/platform/INT33D5:00/input/input44 (input)
  NAME="Intel HID switches"
  EV=21
  SW=2
  PROP=0
  MODALIAS=input:b0019v0000p0000e0000-e0,5,kramlsfw1,

KERNEL[6291.031342] add /devices/platform/INT33D5:00/input/input44/event25 (input)
  DEVNAME=/dev/input/event25
```

Kernel-level: a brand-new input device `Intel HID switches` is
instantiated under the same `INT33D5:00` ACPI device, with full
`EV_SW` capability and `SW_TABLET_MODE` bit set (`SW=0x2` ⇒ bit 1 ⇒
`SW_TABLET_MODE`).

Once created, it persists:

```
$ cat /sys/class/input/input44/name
Intel HID switches
$ cat /sys/class/input/input44/capabilities/{ev,sw}
21
2
```

Subsequent folds don't re-create the device — they fire `EV_SW`
events on `event25` directly, and udev sees `ACTION=="change"` with
`ENV{SW_TABLET_MODE}={0,1}`.

Side-channel signals captured during the same session:

- **5 button array** (event12) fires a `KEY/240` press+release on every
  fold transition, with `MSC/4=203` on tablet entry and `MSC/4=202` on
  tablet exit. (`MSC_SCAN` 0xCB / 0xCA — likely the ACPI 0xCC/0xCD
  codes that show up in old `intel_vbtn` documentation, remapped one
  byte off when intel_hid handles them instead.)
- **HID sensor hub `hinge`** (`iio:device8`, fed by
  `hid_sensor_custom_intel_hinge`) reports an angle when polled — saw
  174°, 360°, 119° during folding — but the value flickers back to 0
  between reads. Continuous use needs the sensor's IIO trigger/buffer
  enabled, not on-demand sysfs reads.

## Design implications

### Don't key on `Intel HID events`

`udevadm test --action=change` against
`/devices/platform/INT33D5:00/input/input21` (the static `Intel HID
events` device) produces no `SW_TABLET_MODE` env var on this hardware.
A rule of the shape `ATTRS{name}=="Intel HID events" ... ENV{SW_TABLET_MODE}`
will install cleanly and never fire.

### Key on `Intel HID switches` and handle both `add` and `change`

The first fold's event arrives as `ACTION=="add"` (the device is being
created with `SW_TABLET_MODE=1` already populated). Every later
transition arrives as `ACTION=="change"` on the persistent device.
Rules need to cover both — and should require `ENV{SW_TABLET_MODE}` to
be set so they don't trip on unrelated input device events.

Sketch of a working rule (not lint-tested):

```
SUBSYSTEM=="input", ATTRS{name}=="Intel HID switches", \
    ACTION=="add|change", ENV{SW_TABLET_MODE}=="?*", \
    RUN+="/bin/sh -c 'mkdir -p /run/tablet-mode && \
                      printf %%s %E{SW_TABLET_MODE} > /run/tablet-mode/state && \
                      chmod 0644 /run/tablet-mode/state'"
```

If the `ACTION=="add|change"` syntax doesn't parse cleanly for a given
udev version, split into two rules.

### `intel_vbtn` is not loaded; don't write design comments that claim it

The driver that handles `INT33D5` here is `intel_hid`. Any comment
saying "the kernel's intel_vbtn driver synthesizes SW_TABLET_MODE …"
is misleading on this laptop. `intel_vbtn` is keyed on `INT33D6`,
which this firmware does not expose.

### Toggle-script device-name discovery is fine

Querying `hyprctl devices -j` against the running session correctly
identifies the keyboard as `at-translated-set-2-keyboard` and the
touchpad as `dell0896:00-04f3:30b6-touchpad` — so a toggle script that
discovers devices via the Hyprland IPC will toggle the right inputs
without hard-coding hardware names.

### Required runtime tooling on the running system

All present: `wvkbd-mobintl`, `jq`, `iio-hyprland`, `iio-sensor-proxy`,
`hyprctl`. Postinstall already pulls these in.

### Adjacent — accelerometer-driven screen rotation works

Confirmed working on the same machine 2026-04-29: `iio-hyprland`
consumes `net.hadess.SensorProxy.AccelerometerOrientation` from
`iio-sensor-proxy` and rotates the Hyprland output as the laptop is
turned. Only the `SW_TABLET_MODE` signal path needed re-tracing — the
rest of the IIO sensor hub is healthy on this hardware.

## Reproducing this investigation

Three monitors run in parallel while folding the screen:

```bash
# evmon.py — decode raw input events on event{0,7,12,25}
cat > /tmp/evmon.py <<'EOF'
import os, select, struct, time
DEVS = {
    "/dev/input/event0":  "lid",
    "/dev/input/event7":  "intel-hid-events",
    "/dev/input/event12": "intel-hid-5btn",
    "/dev/input/event25": "intel-hid-switches",  # appears after first fold
}
TYPE = {0: "SYN", 1: "KEY", 4: "MSC", 5: "SW"}
SW   = {0: "LID", 1: "TABLET_MODE", 4: "DOCK"}
EVT_FMT = "@llHHi"; EVT_SZ = struct.calcsize(EVT_FMT)
fds = {}
for path, label in DEVS.items():
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        fds[fd] = (path, label); print(f"[opened] {label}")
    except OSError as e:
        print(f"[skip]   {path}: {e}")
p = select.poll()
for fd in fds: p.register(fd, select.POLLIN)
while True:
    for fd, _ in p.poll(1000):
        data = os.read(fd, EVT_SZ * 64); _, label = fds[fd]
        for i in range(0, len(data), EVT_SZ):
            sec, usec, etype, ecode, eval = struct.unpack(EVT_FMT, data[i:i+EVT_SZ])
            if etype == 0: continue
            ts = time.strftime("%H:%M:%S", time.localtime(sec)) + f".{usec//1000:03d}"
            cn = SW.get(ecode, str(ecode)) if etype == 5 else ecode
            print(f"{ts} {label:18s} {TYPE.get(etype, etype)}/{cn}={eval}", flush=True)
EOF

# In separate terminals (or background):
python3 /tmp/evmon.py
udevadm monitor --kernel --udev --environment --subsystem-match=input
while :; do v=$(cat /sys/bus/iio/devices/iio:device8/in_angl0_raw); \
            printf '%s hinge=%s\n' "$(date +%T.%3N)" "$v"; sleep 0.25; done
```

Then physically fold the screen back ~360° and back to laptop. Look
for:

- `KERNEL[...] add /devices/platform/INT33D5:00/input/inputN` with
  `NAME="Intel HID switches"` on the very first fold.
- On subsequent folds, `EV_SW` events on the new event-number with
  `code=1` (`SW_TABLET_MODE`), `value` toggling 0↔1, and matching
  udev `ACTION=="change"` events with `ENV{SW_TABLET_MODE}` populated.
- `KEY/240` bursts with `MSC/4=202|203` on the 5-button-array — useful
  as a fallback signal if the switches-device path is ever broken.
