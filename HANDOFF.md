# HANDOFF — dd Arch ISO to a raw stick, bypass Ventoy

**First thing: delete this file after reading**, *before* starting work, so you don't accidentally commit alongside it:

```powershell
git rm HANDOFF.md
git commit -m "handoff: dev pc session ddd a raw stick, removing handoff"
git push
```

---

## Context

Dell 7786 has been stuck at archiso's `loop0` / `EXT4-fs: Can't find ext4 filesystem` mount error for an entire session. Here's everything we know, because this pattern is unusual:

### Key facts

- **ISO is clean.** Four-way SHA256 match confirmed in an earlier session. `f14bf46afbe782d28835aed99bfa2fe447903872cb9f4b21153196d6ed1d48ae`. Do not re-download.
- **Failure is in loop0 content.** dmesg shows both `EXT4-fs` and `ISOFS` rejecting the mounted airootfs image — meaning the bytes in the loop device are garbage, not a malformed-but-valid filesystem. The ISO is clean but the in-RAM copy is corrupt → USB-layer read corruption.
- **Tried and failed on 7786:**
  - Ventoy normal mode (multiple times, multiple ports)
  - Ventoy Memdisk mode (`d`)
  - Ventoy Compatible mode (`i`)
  - USB-A port #1, #2
  - USB 2.0 port on the dock (via USB-C uplink)
  - Editing archiso kernel cmdline to append `copytoram_size=0` (archiso cmdline does *not* contain `copytoram` explicitly — Ventoy or a default must be injecting the RAM-copy behavior somewhere)
- **The one thing that works:** cold boot after the laptop has been **off for hours**. ~5 minutes isn't enough. Capacitor/thermal signature — points to borderline hardware on the USB controller or RAM path. But the user wants to finish the install today, not replace a motherboard.

### Repo state

- Branch: **`claude/fix-linux-boot-issue-9ps2s`** (not main).
- `phase-2-arch-install/install-from-clone.sh` exists — USB-free install variant the user's been running after `git clone` into `/tmp/arch-setup`. Pacstrap etc. all work once we can get into archiso.
- `phase-2-arch-install/install.sh` fix for Ventoy dm-linear mount via `partx -g` on parent disk (commit `d170d47`) is irrelevant to the current bottleneck but still needed for any future USB-based install.

## What to do

The plan: take Ventoy out of the equation entirely by `dd`'ing the Arch ISO onto a raw USB stick. If the raw stick still hits loop0 failures, it's hardware. If it boots cleanly, Ventoy is somehow contributing and we'll know.

### Stick selection

- **Don't re-use F:** (SanDisk Cruzer U, 7.5 GB). It's Ventoy'd and the user may still want it for other ISOs. A `dd` would wipe the Ventoy layout.
- **Stick E:** (SanDisk Cruzer Glide, 29 GB) is the previously-flagged I/O-suspect one (kernel wedge during Win11 ISO write). Probably don't use it either.
- **Best: find a third stick** — any 2+ GB USB stick in the house. If nothing available, fall back to E: (wipe-and-retry is low-cost; its earlier wedge was during a sustained *write* of a large ISO, and the stick has been idle since — worth trying).

### dd procedure (Windows-side via Rufus)

Since the dev PC is Windows, easiest way to dd is Rufus in DD mode:

1. Download Rufus if not present: [rufus.ie](https://rufus.ie) (portable exe, no install)
2. Plug in the target stick (whichever one you chose above)
3. Rufus → select the stick → select `assets/archlinux-x86_64.iso` → **"Write in DD image mode"** when prompted (the dialog appears after clicking Start)
4. Start, wait, eject cleanly
5. Verify with `CertUtil -hashfile \\.\PhysicalDriveN SHA256` against the upstream hash (optional but reassuring — the whole-stick hash should prefix-match the ISO hash for the first ISO_BYTES bytes, but this is fiddly; skip if unsure)

### Alternative: PowerShell raw dd equivalent

If Rufus isn't available and the user is OK with a PowerShell approach:

```powershell
# Find the physical disk number for the target stick (careful!)
Get-Disk | Where-Object BusType -eq USB | Format-Table Number, Size, FriendlyName
# e.g. Number = 3

# Raw-copy ISO onto it (DESTROYS all existing data on that stick)
$diskNum = 3   # <-- set this to the target stick's number
$iso = 'V:\arch-setup@fnrhombus\assets\archlinux-x86_64.iso'
$dest = "\\.\PhysicalDrive$diskNum"
# Use dd-for-windows or:
[System.IO.File]::OpenRead($iso) | ForEach-Object { ... }   # messier
```
Rufus is easier; prefer that.

## Success criteria

- Stick can be read by the dev PC after dd: `Get-PartitionSupportedSize` on it should show a bootable EFI System partition.
- `CertUtil -hashfile <iso-file-on-stick> SHA256` matches upstream (optional).
- Hand the stick to the user. They boot it directly (F12 → USB), no Ventoy menu.

## What NOT to do

- **Don't `pnpm stage`** — stick layout won't be Ventoy-compatible and the stage script would fail or corrupt.
- **Don't re-download the ISO** — SHA256 is proven clean.
- **Don't touch stick F:** — still useful, don't wipe it.
- **Don't assume branch is main.**

## What the user will do with the raw stick

1. Plug the raw stick into the 7786 (USB-A port — since this stick has no Ventoy chainloading, UAS/controller story may be different)
2. F12 → boot from USB
3. Should go straight into archiso's systemd-boot menu (no Ventoy menu in front)
4. Pick "Arch Linux install medium (x86_64, UEFI)" → land at root shell
5. If loop0 fails again: it's hardware on the 7786, not Ventoy. Come back for a different plan.
6. If it boots: `pacman -Sy --noconfirm git`, clone the branch, run `install-from-clone.sh`.
