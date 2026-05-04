---
name: Inspiron 7786 HDMI port doesn't wire CEC
description: Don't propose CEC-based solutions for this laptop's HDMI output — exhaustively tested 2026-05-04, hardware-level dead.
type: project
---

**Don't propose CEC over HDMI on the Inspiron 7786 (i915, DP-1 = HDMI). It's hardware-dead at the laptop side.**

**Why:** 2026-05-04 — investigated using CEC for "is the TV actually on" detection. Findings:

- Kernel CEC framework alive (`/dev/cec0`, `cec` module loaded by i915).
- `cec-ctl --playback` claims LA 4 fine; `cec-follower` runs.
- TV has CEC enabled (Vizio V505-G9, confirmed via on-screen CEC settings menu and active "Device Discovery" feature).
- Tested with 5 different HDMI cables including the OEM Vizio cable that came with the TV.
- Every `cec-ctl --to 0 --give-device-power-status` returns `Tx, Not Acknowledged (1), Max Retries`.
- Zero received messages across multiple full power-on/power-off cycles and HDMI input changes.
- Vizio's "Device Discovery" reports "no CEC devices connected" — the TV doesn't see the laptop either.

Conclusion: the Inspiron 7786's HDMI port doesn't physically wire CEC pin 13 to the i915 CEC controller. Common cost-cut on consumer laptops. Not fixable in software.

**How to apply:** if user asks for "TV power detection" / "TV-aware monitor handling" / anything CEC-shaped on this laptop, skip CEC entirely and use the alternatives that *do* work:

1. **Network presence detection.** Vizio TV at `192.168.1.98` (MAC `64:16:66:09:f0:1e`, OUI 64:16:66 = Vizio). Soft-off → completely silent (ICMP timeout, all common ports closed). On → pings respond. Verified 2026-05-04. This is the load-bearing real signal.
2. **DDC/CI** untested as of 2026-05-04 (need `i2c-dev` module loaded + ddcutil install). Mentioned as backup but not implemented.
3. The naive workaround (disable DP-1 in monitors.conf, hotkey to enable) works but the user explicitly rejected workarounds in favour of real signal-based detection.
