---
name: /etc/adjtime must be UTC (single-OS Arch)
description: chroot.sh used to write LOCAL into /etc/adjtime as a Windows-dualboot accommodation. Dual-boot was dropped 2026-04-27. With LOCAL on single-OS, the system clock runs 4h ahead of real UTC and breaks anything that signs JWTs or validates cert timestamps.
type: project
originSessionId: 1f608502-800c-4723-a701-24396c206988
---
`/etc/adjtime` mode line MUST be `UTC` for this single-OS Arch install.

**Why:** The 2026-04-30 metis triage chased a 4-hour clock skew through Azure SP secret rotation, JWT cert auth, and TLS cert validity before tracing it to `RTC in local TZ: yes` (the LOCAL setting in `/etc/adjtime`). systemd was reading the BIOS clock as local time but every downstream component (Azure AAD, Let's Encrypt, JWT signing) treats the system's UTC view as authoritative. Local-mode BIOS + UTC-treating system = system clock 4h ahead of real UTC.

The LOCAL setting was originally written by chroot.sh as a Windows-dualboot accommodation — Windows defaults RTC to local time, so writing UTC back via `hwclock --systohc` would jump Windows's clock by the timezone offset. Dual-boot was dropped per CLAUDE.md 2026-04-27 (single-OS Arch only); the LOCAL setting became dead code that quietly poisoned everything time-sensitive.

**How to apply:**
- `phase-2-arch-install/chroot.sh` writes UTC into /etc/adjtime + enables `systemd-timesyncd.service` (commit `de5a401` 2026-04-30). Don't revert.
- If anything ever proposes flipping back to LOCAL or a Windows-compat clock dance: the right answer is "single-OS, dual-boot was dropped, see CLAUDE.md".
- If clock skew is reported again on a future install: check `timedatectl status` for `RTC in local TZ` and `NTP service: inactive`. Fix with `timedatectl set-local-rtc 0 --adjust-system-clock` + `timedatectl set-ntp true` + `hwclock --systohc --utc`.
