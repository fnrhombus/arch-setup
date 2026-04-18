# Claude Handoff — Phase 0: BIOS Setup & First Boot

Paste this into a new Claude conversation on any device. It gives Claude everything needed to walk you through the BIOS settings and USB boot steps before the Windows install begins.

---

## Who you are

- Installing Windows + Arch Linux dual-boot on a **Dell Inspiron 7786** (17" 2-in-1)
- Using a **Ventoy USB** you've already prepared on your dev machine (ISOs + scripts staged)
- This is a guided install — you want Claude to advise you step by step and troubleshoot if something looks wrong

## What Claude should do

Walk me through Phase 0 (BIOS setup) and help me troubleshoot anything that goes wrong before or during USB boot. Ask me what I'm seeing on screen; give short, direct instructions.

---

## Hardware

| Component | Details |
|---|---|
| Machine | Dell Inspiron 7786 |
| CPU | Intel i7-8565U |
| Storage (primary) | Samsung SSD 840 PRO **512 GB** — this is where Windows + Arch will go |
| Storage (secondary) | Netac SSD **128 GB** — Arch recovery ISO + swap + log/cache |
| GPU | Intel UHD 620 (NVIDIA MX250 is blacklisted — incompatible with Wayland) |

---

## Phase 0 — BIOS settings checklist

Enter BIOS with **F2** at power-on (hammer it). Save & exit after all changes.

| Setting | Value | Where to find it |
|---|---|---|
| Boot Mode | **UEFI** (not Legacy/CSM) | Boot tab |
| Secure Boot | **Disabled** | Security tab — re-enable *after* Phase 3 stabilizes, not now |
| SATA Operation | **AHCI** | Storage/Advanced tab — if set to RAID/Intel RST, Arch can't see the disks |
| Fast Boot | **Disabled** | Boot tab — Minimal or Thorough both risk the USB not appearing in F12 |
| Fingerprint Reader | **Enabled** | Security tab — if disabled here, Linux sees no sensor and Phase 3 fprintd enrollment fails |

After saving: hammer **F12** at the Dell logo → one-time boot menu → pick the USB entry (labeled something like "UEFI: SanDisk …" or the WD brand name).

### Known Dell quirks at this stage

- **USB doesn't appear in F12**: Secure Boot being ON hides unsigned USB boot entries. Disable Secure Boot first, then retry F12.
- **Fast Boot sub-options (Minimal / Thorough)**: If the BIOS won't let you fully disable Fast Boot, choose **Thorough** — Minimal skips USB hardware init and the stick won't appear in F12.
- **SATA still shows RAID after switching to AHCI**: Sometimes requires two saves. Switch → save → re-enter BIOS → confirm it's AHCI.
- **F12 menu appears but USB is missing**: USB Boot may be off. Check Boot Sequence → ensure "USB Storage Device" is listed and enabled.

---

## What happens next (so Claude has context)

After booting the USB:
1. Ventoy menu → pick `Win11_25H2_English_x64_v2.iso` → Windows installs fully unattended (~30 min, 2 auto-reboots)
2. Ventoy menu → pick the Arch ISO → run `./install.sh` from the Ventoy data partition
3. First boot into Arch → run `~/postinstall.sh` as user `tom`

The install scripts auto-detect both drives by size (Samsung 500–600 GB window, Netac 100–150 GB window) and abort with a clear error if something is wrong.

---

## If you're not on the install yet

If you're still at the dev machine and the USB isn't prepared, the prep command is:
```
pnpm i   # in the arch-setup repo — fetches ISOs, detects Ventoy USB, mirrors everything onto it
```
