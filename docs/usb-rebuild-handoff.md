# Claude Handoff — USB Rebuild (Dev Machine Session)

Paste this into a fresh Claude Code session on the Windows dev machine — the one that produces the Ventoy USB via `pnpm i`. Your job is to diagnose why Windows 11 won't install on Metis (Dell Inspiron 7786) from the current USB, and rebuild the stick if that's the fix.

Branch to work on: **`claude/fix-linux-boot-issue-9ps2s`** — pull the latest before you start.

## What's happening

fnrhombus has been stuck on phase 1 (Windows install) for hours. The install fails at the same two points on BOTH his SanDisk 32GB USB AND his internal 128GB Netac SATA SSD (which also runs Ventoy as an always-attached recovery-boot source). Symptoms:

- **Ventoy "normal mode"** on `Win11_25H2_English_x64_v2.iso`: Windows Boot Manager dies with `0xc000014c`, file `\EFI\Microsoft\Boot\BCD`, "Boot Configuration Data is missing or contains errors." This is BEFORE WinPE loads.
- **Ventoy "wimboot mode"** on the same ISO: WinPE boots, `autounattend.xml`'s `pe.cmd` runs, DiskPart creates 512MB EFI / 16MB MSR / 160GB Windows successfully, then:
  ```
  dism.exe /Apply-Image /ImageFile:H:\sources\install.wim /Name:"Windows 11 Pro" /ApplyDir:W:\
  ```
  fails with **Error: 13, "The data is invalid"**. DISM version `10.0.26100.7920`.

## Already ruled out

- **ISO corruption.** Ventoy's File checksum (SHA256) completes cleanly — bytes are intact end-to-end. Fido-fetched consumer Win11 25H2 v2.
- **USB hardware.** Both the USB stick and the internal SATA SSD fail identically — rules out USB-controller issues.
- **Ventoy version.** Both sticks upgraded to **1.1.12** (visible on the boot screen: "1.1.12 UEFI"). Prior research claimed 1.0.99's VTOYEFI GPT-attribute bug was the cause; that was a red herring — 1.1.12 has the same failures.
- **DISM `/CheckIntegrity /Verify`.** These were sed-stripped from autounattend.xml before retrying wimboot. Error 13 persists without them.
- **SATA mode.** Confirmed AHCI, not RAID/Intel RST.
- **Fast Boot.** Set to Thorough.
- **Secure Boot.** Disabled (as planned — re-enable post phase 3).
- **Samsung SSD.** DiskPart's `clean` wipes leftover partitions each try. Failure is strictly at DISM, not earlier.

## Still in play (ranked by suspicion)

1. **`autounattend.xml` bug.** Schneegans-generated with hand patches (Samsung-by-size detection, 512/16/160 layout, silent OOBE). Could be out of sync with Win11 25H2 WinPE. **Cheap test available** — see task 1 below.
2. **`ventoy/ventoy.json` config.** `auto_install` plugin injection could be breaking WinPE's BCD path.
3. **Win11 25H2 ISO + Ventoy wimboot.** Install.wim compression (LZMS/XPRESS8K?) might not survive Ventoy's virtual-ISO overlay. Different from 1.0.99 GPT-bug story.
4. **Dell Inspiron 7786 / 8th-gen specific regression** in Win11 25H2.

## Your tasks — in order

### 1. Cheap diagnostic: no-autounattend test (user can do this from the laptop without dev-machine help)

If the user hasn't tried this yet, have them boot back to Arch live from Ventoy, mount the SanDisk's data partition (`mount /dev/sdc1 /mnt`), and rename the XML:
```sh
mv /mnt/autounattend.xml /mnt/autounattend.xml.disabled
umount /mnt
```
Reboot → Ventoy → Win11 → **normal mode**.

- **Win11 Setup GUI loads cleanly** → autounattend is the cause. Don't rebuild USB; regenerate the XML (task 3).
- **Still fails with 0xc000014c** → autounattend isn't the cause. Proceed to rebuild (task 2).

### 2. Rebuild the USB from the dev machine

Assuming task 1 didn't clear it (or user wants a full clean slate):

```powershell
cd <repo>
git checkout claude/fix-linux-boot-issue-9ps2s
git pull
pnpm restore:force        # re-fetch ISOs from scratch
```

Then fully reinstall Ventoy on the SanDisk using **Windows-native `Ventoy2Disk.exe`** (GUI). This is destructive to the stick — confirm the user backed up anything personal on it. Pick the SanDisk, click "Install", pin Ventoy version to **1.1.12** (or newer, see `scripts/fetch-assets.ps1` — update the pin if it's still on 1.0.99).

Then:
```powershell
pnpm stage                # stage-usb.ps1 mirrors ISOs + configs + docs onto the fresh Ventoy
```

Bring the stick to Metis, retry Win11 normal mode.

### 3. If rebuild + fresh autounattend still fails

Likely candidates left:
- **Regenerate autounattend.xml from Schneegans** with a current Win11 25H2 profile. Compare the diff against `autounattend.xml`; apply our known patches (Samsung-by-size, 512/16/160, silent OOBE per `docs/autounattend-oobe-patch.md`) on top of the fresh template.
- **Fallback: Rufus-built installer.** Use Rufus on the dev machine to build a plain bootable Win11 USB (no Ventoy, no autounattend). Loses automation but bypasses both Ventoy + autounattend as potential causes. Stage autounattend.xml as a sidecar in the root of the USB if possible.

### 4. Commit discipline

- Atomic commits on `claude/fix-linux-boot-issue-9ps2s`.
- Push on feature completion (USB rebuild + any XML regeneration together).
- Bump Ventoy version pin in `scripts/fetch-assets.ps1` if the current pin is 1.0.99 — that's stale and contributed to the dead-end earlier.

## Key files

- `autounattend.xml` — Schneegans-generated + hand-patched. Orders 6-9 (windowsPE pass) emit `X:\pe.cmd` which runs inline PowerShell for Samsung-by-size detection, writes `X:\diskpart.txt`, runs DiskPart, calls DISM.
- `ventoy/ventoy.json` — `auto_install` entry matches the Win11 ISO filename → Ventoy injects autounattend.xml into the ISO boot.
- `scripts/fetch-assets.ps1` — downloads Ventoy, Arch ISO, Win11 ISO via Fido.
- `scripts/stage-usb.ps1` — robocopies assets onto Ventoy's data partition.
- `docs/decisions.md` §Q9 — disk layout (512/16/160/316).
- `docs/autounattend-oobe-patch.md` — what hand-patches our XML carries vs. vanilla Schneegans.

## Handing back to the Android coach

Once the rebuilt USB is ready (or you've identified the fix and pushed it), tell the user. The Android/phone Claude is coaching him through the physical steps at the laptop and will take over once the stick is done.

_Last updated in the middle of the stuck install — may be updated again if deeper research turns up new findings; pull latest before acting._
