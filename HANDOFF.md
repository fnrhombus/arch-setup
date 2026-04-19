# HANDOFF — reach install.sh via curl, then let it self-mount

**First thing to do: delete this file after reading**, *before* starting so you don't accidentally commit alongside it:

```bash
git rm HANDOFF.md
git commit -m "handoff: 7786 session picked up curl recipe, removing handoff"
git push
```

---

## Context

Previous handoff said to `bash /run/ventoy/phase-2-arch-install/install.sh` — that can't work because `/run/ventoy` isn't mounted in the live-ISO shell yet, and an earlier manual `dmsetup create ... /dev/sdb1 offset=0` attempt (on the pre-patch install.sh) failed with `device busy`. The plan is: fetch the fixed install.sh off GitHub via curl (so reaching it doesn't depend on the stick being mounted), then the script's own section 0.5 handles the `partx`/`dmsetup`/`mount` correctly against the parent disk.

**Revised cleanup** since last handoff: the previous cleanup only removed a mapper named `ventoy-data`, but install.sh's own mapper name convention is `$VENTOY_PART` — `sdb1`, `nvme0n1p1`, etc. — so if any earlier attempt left a stale mapper under one of those names, the narrower cleanup would miss it and install.sh's `[[ ! -e /dev/mapper/sdb1 ]]` guard would skip recreation, potentially mounting the wrong dm configuration. The broader loop below removes every linear mapper *except* `ventoy` itself (which must survive: section 0.5 reads `dmsetup deps ventoy` to find the parent USB disk).

## Step 1 — clean up any leftover dm-linear state

Safe to re-run; no-ops if nothing's there:

```bash
umount /run/ventoy 2>/dev/null || true
dmsetup ls --target linear 2>/dev/null \
  | awk '$1 != "ventoy" && $1 != "No" {print $1}' \
  | while read -r m; do dmsetup remove "$m" 2>/dev/null || true; done
```

## Step 2 — fetch the fixed install.sh off GitHub

```bash
curl -fsSL \
  'https://raw.githubusercontent.com/fnrhombus/arch-setup/claude/fix-linux-boot-issue-9ps2s/phase-2-arch-install/install.sh' \
  -o /tmp/install.sh
```

Sanity-check the fix landed:

```bash
grep -n 'PART_START=$(partx' /tmp/install.sh
```

Should print one line around **line 136**. If it doesn't, retry curl, or fall back to the manual recipe below.

## Step 3 — run it

```bash
bash /tmp/install.sh
```

Section 0.5 will detect the USB disk via `dmsetup deps ventoy`, resolve partition 1's start + size via `partx -g -o START,SECTORS`, `dmsetup create` against the parent `/dev/sdX` at that offset (avoiding the `/dev/sdb1` busy trap), and mount read-only at `/run/ventoy`. Then the script prompts once for root + `tom` passwords, pacstraps, runs `chroot.sh`, and finishes. Keep the F: stick plugged in throughout — install.sh copies phase-3 scripts and docs from it into the installed system.

## After install

Reboot → systemd-boot → Arch → log in as `tom` → `~/postinstall.sh` for Phase 3.

## Fallback if curl can't reach GitHub

No network in archiso — try `ip link show` / `iwctl`. If you can't get network up, do the mount manually (same cleanup loop first), then run install.sh from the mounted stick:

```bash
umount /run/ventoy 2>/dev/null || true
dmsetup ls --target linear 2>/dev/null | awk '$1 != "ventoy" && $1 != "No" {print $1}' | while read -r m; do dmsetup remove "$m" 2>/dev/null || true; done
DISK=$(dmsetup deps -o devname ventoy | grep -oE '[sv]d[a-z]+|nvme[0-9]+n[0-9]+' | head -n1)
PART_START=$(partx -g -o START  "/dev/$DISK" | head -n1 | awk '{print $1}')
PART_SIZE=$(partx  -g -o SECTORS "/dev/$DISK" | head -n1 | awk '{print $1}')
echo "0 $PART_SIZE linear /dev/$DISK $PART_START" | dmsetup create "${DISK}1"
mkdir -p /run/ventoy
mount -o ro "/dev/mapper/${DISK}1" /run/ventoy
bash /run/ventoy/phase-2-arch-install/install.sh
```

## What NOT to do

- **Don't mount `/dev/sdb1` directly.** archiso's probe hooks hold it open; you need dm-linear against the parent disk.
- **Don't re-download the Arch ISO.** SHA256 is four-way clean; it's not the problem.
- **Don't touch stick E:.** I/O-faulty per earlier sessions.
- **Don't `pacman -Sy git`** to clone the repo. `curl` is already on archiso and is the right tool here.
- **Don't remove the `ventoy` mapper in step 1.** Section 0.5 reads `dmsetup deps ventoy` to find the parent USB disk — removing it breaks the install.
- **Don't assume branch is `main`.** You're on `claude/fix-linux-boot-issue-9ps2s`.
