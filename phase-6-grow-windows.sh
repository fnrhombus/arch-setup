#!/usr/bin/env bash
# phase-6-grow-windows.sh
#
# Shrinks the Arch Linux btrfs partition on the Samsung SSD and relocates
# all data so that unallocated space ends up IMMEDIATELY to the right of
# the Windows partition. Windows Disk Management can then Extend Volume
# on C: into that space.
#
# Run from the Arch live USB (Ventoy → Arch ISO) as root, with NO btrfs
# filesystem mounted. Not from the booted Arch system.
#
# Usage:
#   ./phase-6-grow-windows.sh <GB_to_give_Windows>
#   ./phase-6-grow-windows.sh --dry-run <GB_to_give_Windows>
#
# -----------------------------------------------------------------------
# Why this is complicated
# -----------------------------------------------------------------------
# Per decisions.md §Q9 the Samsung layout is:
#     [EFI 512M][MSR 16M][Windows 160G NTFS][Linux ~316G btrfs]
#
# Windows grows rightward from the end of its partition. For Windows to
# claim space, the free space must land IMMEDIATELY after Windows —
# between Windows and Linux. That means Linux's data has to physically
# shift rightward on the disk.
#
# You cannot just `sgdisk -d 4 && sgdisk -n 4:<later_start>:<old_end>`.
# btrfs writes its primary superblock at offset 65536 of the partition
# start. Shifting the start by N GiB puts the superblock inside what
# used to be random btrfs data — the filesystem becomes unmountable.
#
# The safe way is btrfs's own device-migration (`btrfs device add` +
# `btrfs device remove`) to physically copy data onto a new partition
# that lives at the end of the disk. Then we delete the original
# partition, leaving unallocated space where the old Linux data was —
# which is exactly where Windows wants to grow into.
#
# -----------------------------------------------------------------------
# Constraints
# -----------------------------------------------------------------------
# Let S = GB you want to give Windows
#     U = current btrfs usage in GB
#     O = original Linux partition size (~316 GB on this layout)
#     M = 2 GB safety margin
#
# Feasibility window:    U + M  <=  S  <=  O - U - M
#
# Upper bound: the new Linux partition (after migration) will be O - S.
# It must fit all current data plus slack, so S <= O - U - M.
#
# Lower bound: during the intermediate step we shrink btrfs to size S
# before creating the new partition. btrfs refuses to shrink below
# current usage, so S >= U + M.
#
# If U > (O - 2M) / 2 (roughly half the partition is used — ~156 GB on
# this layout), there's no valid S. You have two options:
#   (a) Delete files from Linux first (`ncdu`, clear ~/.cache, dropdown
#       snapshots) until U drops below 156 GB, then re-run this script.
#   (b) Use GParted Live (boot from Ventoy) to do an in-place partition
#       move. GParted handles the data migration directly; it's slower
#       but has no size constraint. See recovery §G in INSTALL-RUNBOOK.md.
#
# -----------------------------------------------------------------------
# What runs
# -----------------------------------------------------------------------
#   1.  Probe: find Samsung, current Arch root partition, print state.
#   2.  Validate S against current usage.
#   3.  Confirm with you (last chance to bail).
#   4.  Mount btrfs to /mnt/grow (read-write).
#   5.  Shrink btrfs filesystem to S GiB.
#   6.  Unmount, shrink partition to S GiB (preserves start sector and
#       PARTLABEL/PARTUUID).
#   7.  Create new partition in the freed space at end of disk, size
#       (O - S), with temporary PARTLABEL="ArchRootNew".
#   8.  Mount btrfs again (via the now-smaller original partition).
#   9.  `btrfs device add` the new partition.
#   10. `btrfs device remove` the original. Data migrates — this is the
#       long step; tens of minutes for hundreds of GB.
#   11. Unmount. Delete the original partition from the table.
#   12. Rename the new partition: PARTLABEL="ArchRoot" (matches install.sh
#       conventions so future tooling finds it the same way).
#   13. Print the disk state and next-steps for the Windows side.
#
# Filesystem UUID is preserved across device add/remove, so /etc/fstab
# and systemd-boot entries (which use `root=UUID=...`) keep working
# without edits. The PARTUUID does change — but no tooling in this
# project depends on PARTUUID.

set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    shift
fi

ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
run()  {
    if (( DRY_RUN )); then
        printf '\033[1;35m[DRY]\033[0m %s\n' "$*"
    else
        eval "$@"
    fi
}
ask()  {
    local prompt="$1"
    local answer
    read -rp "$prompt " answer
    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

# ---------- preflight ----------
[[ $EUID -eq 0 ]] || fail "Run as root (you're on the Arch live USB — 'sudo -i' first)."
[[ -n "${1:-}" ]] || fail "Usage: $0 [--dry-run] <GB_to_give_Windows>"
[[ "$1" =~ ^[0-9]+$ ]] || fail "First argument must be an integer GB value, got: $1"

S="$1"
GIB=$((1024 * 1024 * 1024))

for bin in sgdisk btrfs lsblk blkid partprobe; do
    command -v "$bin" &>/dev/null || fail "Missing tool: $bin — on the Arch live USB: pacman -Sy gptfdisk btrfs-progs util-linux parted"
done

# ---------- locate Samsung + Arch root partition ----------
log "Locating Samsung SSD (500-600 GB)..."
SAMSUNG=""
while read -r name size; do
    size_gb=$(( size / GIB ))
    if (( size_gb >= 500 && size_gb <= 600 )); then
        SAMSUNG="/dev/$name"
        ok "Samsung: $SAMSUNG (${size_gb} GB)"
        break
    fi
done < <(lsblk -bnd -o NAME,SIZE)
[[ -n "$SAMSUNG" ]] || fail "Could not locate a 500-600 GB disk. Adjust the size window."

log "Locating ArchRoot partition by PARTLABEL..."
ARCH_DEV=""
ARCH_PARTNUM=""
# -l (list, no tree) keeps NAME free of tree-drawing glyphs like "└─sda4".
while read -r name partlabel; do
    if [[ "$partlabel" == "ArchRoot" ]]; then
        ARCH_DEV="/dev/$name"
        ARCH_PARTNUM="${name##*[!0-9]}"
        ok "ArchRoot: $ARCH_DEV (partition #$ARCH_PARTNUM)"
        break
    fi
done < <(lsblk -ln -o NAME,PARTLABEL "$SAMSUNG")
[[ -n "$ARCH_DEV" ]] || fail "No partition with PARTLABEL=ArchRoot on $SAMSUNG."

# ---------- check it's really unmounted ----------
if findmnt -n "$ARCH_DEV" &>/dev/null; then
    fail "$ARCH_DEV is currently mounted. Unmount it first (umount -R /mnt or reboot live USB)."
fi
if mountpoint -q /mnt/grow 2>/dev/null; then
    fail "/mnt/grow is already mounted. Unmount it: umount /mnt/grow"
fi

# ---------- read current sizes ----------
PART_BYTES=$(blockdev --getsize64 "$ARCH_DEV")
PART_GB=$(( PART_BYTES / GIB ))
log "Current Arch partition size: ${PART_GB} GB"

# Mount briefly to measure usage
mkdir -p /mnt/grow
mount -o ro "$ARCH_DEV" /mnt/grow
USED_BYTES=$(btrfs filesystem usage -b /mnt/grow 2>/dev/null | awk '/^ +Used:/ {print $2; exit}')
umount /mnt/grow
[[ -n "$USED_BYTES" ]] || fail "Couldn't read btrfs usage."
USED_GB=$(( (USED_BYTES + GIB - 1) / GIB ))   # round up
log "Current Linux usage: ${USED_GB} GB"

MARGIN=2
LOWER=$(( USED_GB + MARGIN ))
UPPER=$(( PART_GB - USED_GB - MARGIN ))

log "Feasibility window for S: ${LOWER} <= S <= ${UPPER} GB"

if (( S < LOWER )); then
    fail "S=${S} GB is below the lower bound (${LOWER} GB).
  btrfs can't shrink below current usage. Either:
    - give Windows at least ${LOWER} GB, or
    - free space in Linux first (delete files, clear caches, prune snapshots)."
fi
if (( S > UPPER )); then
    fail "S=${S} GB is above the upper bound (${UPPER} GB).
  The new Linux partition would be too small to hold existing data.
  Either give Windows at most ${UPPER} GB, or free Linux space first."
fi

NEW_LINUX_GB=$(( PART_GB - S ))
ok "Plan:
      shrink Linux from ${PART_GB} GB to ${NEW_LINUX_GB} GB
      create ${S} GB of free space adjacent to Windows
      migrate all ${USED_GB} GB of data to the new Linux partition"

(( DRY_RUN )) && { ok "Dry-run complete. Re-run without --dry-run to execute."; exit 0; }

# ---------- last-chance confirmation ----------
echo
echo "This is destructive and takes a long time (minutes per 10 GB of USED data)."
echo "If it fails mid-migration, recovery requires a working Arch live USB + btrfs knowledge."
echo "You MUST have a current backup of anything irreplaceable in the Linux partition."
echo
ask "Proceed? (yes/no)" || { skip "Aborted by user."; exit 0; }

# ---------- capture old partition geometry ----------
log "Recording current partition geometry of partition #$ARCH_PARTNUM..."
OLD_START=$(sgdisk -i="$ARCH_PARTNUM" "$SAMSUNG" | awk '/First sector:/ {print $3}')
OLD_END=$(sgdisk   -i="$ARCH_PARTNUM" "$SAMSUNG" | awk '/Last sector:/  {print $3}')
OLD_TYPE=$(sgdisk  -i="$ARCH_PARTNUM" "$SAMSUNG" | awk '/Partition GUID code:/ {print $4}')
[[ -n "$OLD_START" && -n "$OLD_END" ]] || fail "Couldn't read partition geometry."
log "Original: start=$OLD_START, end=$OLD_END, typecode=$OLD_TYPE"

# ---------- step 1: shrink btrfs filesystem ----------
log "Step 1/6: shrinking btrfs filesystem to ${S} GiB..."
mount "$ARCH_DEV" /mnt/grow
btrfs filesystem resize "${S}G" /mnt/grow
umount /mnt/grow

# ---------- step 2: shrink partition ----------
log "Step 2/6: shrinking partition $ARCH_PARTNUM to ${S} GiB..."
sgdisk -d "$ARCH_PARTNUM" "$SAMSUNG"
sgdisk -n "${ARCH_PARTNUM}:${OLD_START}:+${S}G" \
       -t "${ARCH_PARTNUM}:8300" \
       -c "${ARCH_PARTNUM}:ArchRoot" "$SAMSUNG"
partprobe "$SAMSUNG"
udevadm settle

# ---------- step 3: create new partition in the freed tail ----------
log "Step 3/6: creating new partition in freed space at end of disk..."
# sgdisk -n 0:0:0 = next available partition number, starts at next free sector, ends at last free sector.
NEW_PARTNUM=$(sgdisk -n 0:0:0 -t 0:8300 -c 0:ArchRootNew "$SAMSUNG" \
              | awk '/created/ {print $NF}' | tr -d ',.')
partprobe "$SAMSUNG"
udevadm settle
# Fallback lookup if sgdisk didn't tell us the number. -l is essential —
# without it NAME includes tree glyphs and the trailing sed below gives
# the wrong answer (or nothing at all).
if ! [[ "$NEW_PARTNUM" =~ ^[0-9]+$ ]]; then
    NEW_PARTNUM=$(lsblk -ln -o NAME,PARTLABEL "$SAMSUNG" | awk '$2 == "ArchRootNew" {print $1; exit}' | sed 's/^.*[^0-9]//')
fi
[[ "$NEW_PARTNUM" =~ ^[0-9]+$ ]] || fail "Could not determine new partition number."
NEW_DEV=$(lsblk -ln -o NAME,PARTLABEL "$SAMSUNG" | awk '$2 == "ArchRootNew" {print "/dev/"$1; exit}')
[[ -n "$NEW_DEV" ]] || fail "Could not find new partition device node."
ok "New partition: $NEW_DEV (#$NEW_PARTNUM)"

# ---------- step 4: btrfs add + remove (the long step) ----------
# Wrap the pool-edit steps in a trap: mid-migration failure leaves the
# pool in a recoverable-but-confusing state (both devices present, data
# partially copied). Printing explicit recovery instructions beats making
# the user figure it out from a bare "btrfs: error, aborting" line.
on_btrfs_fail() {
    local rc=$?
    (( rc == 0 )) && return
    local bar
    bar=$(printf '\033[1;31m%s\033[0m\n' '============================================================')
    cat >&2 <<RECOVERY

$bar
  btrfs device migration failed (exit $rc).
  Pool state may be partially-migrated. Do NOT touch Windows yet —
  Linux itself should still boot (filesystem UUID is preserved).

  Inspect first:
      btrfs filesystem show /mnt/grow   # or /, if you've rebooted
      btrfs device usage   /mnt/grow

  Likely recoveries (pick the one that matches what 'show' reports):

    A) Migration aborted mid-copy — retry it:
         mount $ARCH_DEV /mnt/grow   # if not already mounted
         btrfs device remove $ARCH_DEV /mnt/grow

    B) device add succeeded but remove never ran — you're safe to retry
       as in (A), or roll back:
         btrfs device remove $NEW_DEV /mnt/grow
         umount /mnt/grow
         sgdisk -d $NEW_PARTNUM $SAMSUNG
         partprobe $SAMSUNG && udevadm settle
       Re-run this script after rollback.

    C) Both devices healthy, but remove is returning ENOSPC — the new
       partition is too small. Grow it (sgdisk -d $NEW_PARTNUM +
       sgdisk -n "${NEW_PARTNUM}:0:0") then 'btrfs filesystem resize max
       /mnt/grow' and retry 'btrfs device remove'.

  If all three fail, stop. Open an issue with the output of
  'btrfs filesystem show' and 'sgdisk -p $SAMSUNG'. Do not run
  sgdisk -d against the original partition while data still lives
  on it — that is the one unrecoverable move.
$bar
RECOVERY
}
trap on_btrfs_fail EXIT

log "Step 4/6: adding $NEW_DEV to btrfs pool..."
mount "$ARCH_DEV" /mnt/grow
btrfs device add -f "$NEW_DEV" /mnt/grow

log "Step 5/6: removing $ARCH_DEV from btrfs pool (data migrates — go get coffee)..."
btrfs device remove "$ARCH_DEV" /mnt/grow
ok "Migration complete."

umount /mnt/grow

# Migration survived — disarm the recovery trap so later sgdisk work
# doesn't trigger the btrfs-flavored banner on some unrelated failure.
trap - EXIT

# ---------- step 5: delete the now-empty original partition ----------
log "Step 6/6: deleting empty original partition #$ARCH_PARTNUM..."
sgdisk -d "$ARCH_PARTNUM" "$SAMSUNG"
partprobe "$SAMSUNG"
udevadm settle

# ---------- step 6: rename new partition to ArchRoot ----------
log "Renaming $NEW_DEV PARTLABEL to ArchRoot..."
sgdisk -c "${NEW_PARTNUM}:ArchRoot" "$SAMSUNG"
partprobe "$SAMSUNG"
udevadm settle

# ---------- summary ----------
echo
ok "DONE. Current Samsung layout:"
lsblk -o NAME,SIZE,PARTLABEL,FSTYPE,UUID "$SAMSUNG"
echo
cat <<SUMMARY
NEXT STEPS (on the Windows side):
  1. Reboot into Windows (pick "Windows Boot Manager" in systemd-boot).
  2. Right-click Start → Disk Management.
  3. Right-click the Windows C: partition → Extend Volume.
  4. Accept the default (extends into the ${S} GB unallocated space).
  5. Reboot back into Arch to confirm Linux still boots. First Windows
     boot will likely prompt for the BitLocker recovery key — this is
     the same behavior as the initial install; key is stored in your
     Bitwarden vault per INSTALL-RUNBOOK.md step 7.

ROLLBACK (if something looks wrong BEFORE you touch Windows):
  - The original partition is gone but the data lives on the new one.
  - Linux should boot normally; systemd-boot uses the filesystem UUID,
    which btrfs preserves across device migration.
  - If Linux fails to boot: from the live USB, mount the ArchRoot
    partition, confirm /etc/fstab UUIDs match 'blkid', and check
    /boot/loader/entries/arch.conf's root=UUID=... value.

SUMMARY
