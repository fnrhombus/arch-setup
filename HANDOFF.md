# HANDOFF — re-stage Arch ISO after SHA256 verification was added

**Self-destruct:** delete this file + commit when the work below is done. It only exists to pick up an interrupted task across sessions.

## Context

Live-boot of the Arch ISO off the Ventoy USB failed at the laptop with:

```
Copying rootfs image to RAM... 967MiB 0:00:02 [ 464MiB/s] done.
Mounting '/dev/loop0' to '/run/archiso/airootfs'
EXT4-fs (loop0): VFS: Can't find ext4 filesystem
ERROR: Failed to mount '/dev/loop0'
```

Memdisk mode (`d` at the Ventoy menu) reproduced the same error exactly, ruling out Ventoy's ISO-virtualization layer and pinning the fault on the ISO file itself. `fetch-assets.ps1` had no SHA256 verification, so a truncated/corrupt download silently staged onto the stick.

Commit `ea98d76` on this branch (`claude/fix-linux-boot-issue-9ps2s`) added SHA256 verification to both the download path (`scripts/fetch-assets.ps1`) and the USB copy path (`scripts/stage-usb.ps1`). The actual re-download hasn't happened yet — that's the pending work.

## What to do

On the **dev machine** (Windows, pwsh + pnpm available), **with the Ventoy USB plugged in**, from this repo root:

```powershell
pnpm restore:force
```

That re-downloads `archlinux-x86_64.iso` from the Rackspace mirror, verifies it against `archlinux-sha256sums.txt`, auto-chains into `stage-usb.ps1`, re-copies to the USB, and re-verifies the on-USB copy. Look for these two lines in the output:

```
[ok  ] archlinux-x86_64.iso SHA256 matches upstream
[ok  ] archlinux-x86_64.iso on USB verified
```

If either verification throws, re-run `pnpm restore:force` — the failing ISO is deleted on error so the next run starts clean.

## Cleanup when done

Once both `[ok  ]` lines have printed:

```powershell
git rm HANDOFF.md
git commit -m "handoff: arch iso re-staged + verified, removing handoff"
git push
```

After that, the user can unplug the USB, bring it to the laptop, and boot the Arch entry in **normal mode** (Memdisk not needed once the ISO is valid).
