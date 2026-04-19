# HANDOFF — reach install.sh via curl, then let it self-mount

**First thing to do: delete this file after reading**, *before* starting so you don't accidentally commit alongside it:

```bash
git rm HANDOFF.md
git commit -m "handoff: 7786 session picked up curl recipe, removing handoff"
git push
```

---

## Context

Dev-PC session's previous handoff said `bash /run/ventoy/phase-2-arch-install/install.sh` — you (7786) flagged that that can't work because `/run/ventoy` isn't mounted in your shell yet, and your earlier manual `dmsetup create ... /dev/sdb1 offset=0` attempt (on the pre-patch install.sh) failed with `device busy`, possibly leaving stale `/dev/mapper/ventoy-data` state behind. Correct.

Updated plan: pull the fixed `install.sh` off GitHub via `curl` so reaching it doesn't depend on the stick being mounted. Then the script's own section 0.5 handles the `partx`/`dmsetup`/`mount` correctly against the parent disk.

## Step 1 — clean up any leftover dm-linear state

Safe to re-run; both commands no-op if nothing's there:

```bash
umount /run/ventoy 2>/dev/null || true
dmsetup remove ventoy-data 2>/dev/null || true
```

## Step 2 — fetch the fixed install.sh off GitHub

```bash
curl -fsSL \
  'https://raw.githubusercontent.com/fnrhombus/arch-setup/claude/fix-linux-boot-issue-9ps2s/phase-2-arch-install/install.sh' \
  -o /tmp/install.sh
```

Sanity-check the fix actually landed:

```bash
grep -n 'PART_START=$(partx' /tmp/install.sh
```

Should print one line around **line 136**. If it doesn't, the download corrupted somehow — retry curl, or fall back to the manual recipe below.

## Step 3 — run it

```bash
bash /tmp/install.sh
```

Section 0.5 will:
- detect the USB disk via `lsblk -ndo NAME,TRAN`,
- resolve partition 1's start sector + size via `partx -g -o START,SECTORS`,
- `dmsetup create ventoy-data` against the **parent** `/dev/sdX` at that offset (not `/dev/sdb1`, which is busy),
- mount it read-only at `/run/ventoy`.

Then the rest of the script prompts once for root + `tom` passwords, pacstraps, runs `chroot.sh`, and finishes. Keep the F: stick plugged in throughout — install.sh copies phase-3 scripts and docs from it into the installed system.

## After install

Reboot → systemd-boot → Arch entry → log in as `tom` → `~/postinstall.sh` for Phase 3.

## Fallback if curl can't reach GitHub

No network in archiso (try `ip link show` / `iwctl`). If you can't get network up, do the mount manually, then run install.sh from the mounted stick:

```bash
umount /run/ventoy 2>/dev/null || true
dmsetup remove ventoy-data 2>/dev/null || true
DISK=$(lsblk -ndo NAME,TRAN | awk '$2=="usb"{print $1; exit}')
PART_START=$(partx -g -o START "/dev/$DISK" | head -n1 | awk '{print $1}')
PART_SIZE=$(partx -g -o SECTORS "/dev/$DISK" | head -n1 | awk '{print $1}')
echo "0 $PART_SIZE linear /dev/$DISK $PART_START" | dmsetup create ventoy-data
mkdir -p /run/ventoy
mount -o ro /dev/mapper/ventoy-data /run/ventoy
bash /run/ventoy/phase-2-arch-install/install.sh
```

## What NOT to do

- **Don't mount `/dev/sdb1` directly.** archiso's probe hooks hold it open; you need dm-linear against the parent disk.
- **Don't re-download the Arch ISO.** SHA256 is four-way clean; it's not the problem.
- **Don't touch stick E:.** I/O-faulty per earlier sessions.
- **Don't `pacman -Sy git`** to clone the repo. `curl` is already on archiso and is the right tool here.
- **Don't assume branch is `main`.** You're on `claude/fix-linux-boot-issue-9ps2s`.
