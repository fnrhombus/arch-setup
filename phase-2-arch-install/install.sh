#!/usr/bin/env bash
# phase-2-arch-install/install.sh
#
# Run from the Arch live environment (boot the ISO from Ventoy, pick
# the "archlinux-*x86_64.iso" entry — filename rolls monthly). This script reads every decision
# from decisions.md §Q9 and lays down Arch on:
#   - Samsung 512 GB SSD : LUKS2 + btrfs in the trailing ~316 GB unallocated space
#                          (EFI/MSR/Windows partitions are left untouched)
#   - Netac 128 GB SSD   : recovery ISO (1.5 GB, unencrypted) + LUKS2 swap (16 GB,
#                          random key per boot) + LUKS2 ext4 (~110 GB, keyfile-unlocked)
#
# Full-disk encryption per decisions.md §Q11 — parity with Windows BitLocker.
# Recovery key is auto-generated (BitLocker model: 48 hex chars, displayed
# once for the user to photograph); post-install phase 3 enrolls TPM2 so
# boot becomes silent (recovery key stays as fallback).
#
# All disk operations are size-gated: the script aborts if the expected
# disks are absent or if anything looks off. Never silently clobbers.
#
# Usage:
#   iwctl                                  # connect wifi (station wlan0 connect <ssid>)
#   bash /run/ventoy/phase-2-arch-install/install.sh
#
# The script self-mounts the Ventoy data partition at /run/ventoy on start
# (see section 0.5). You do not need to mount it yourself — the obvious
# `mount /dev/disk/by-label/Ventoy` fails with "Can't open blockdev" because
# Ventoy holds the USB disk exclusively via dm-linear for ISO serving.

set -euo pipefail

# ---------- helpers ----------
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

# Prompt twice for a password and print its SHA-512 crypt hash on stdout.
# Chatter goes to stderr so $(prompt_password ...) captures only the hash.
# Reads from /dev/tty so this survives being called inside a command
# substitution (which otherwise redirects stdin).
prompt_password() {
    local label="$1" p1 p2
    while :; do
        read -rsp "Password for $label: " p1 </dev/tty; printf '\n' >&2
        read -rsp "  confirm $label password: " p2 </dev/tty; printf '\n' >&2
        if [[ -z "$p1" ]]; then
            warn "  (empty — try again)"
        elif [[ "$p1" != "$p2" ]]; then
            warn "  (didn't match — try again)"
        else
            break
        fi
    done
    openssl passwd -6 "$p1"
}

# Auto-generate a BitLocker-style LUKS recovery key (48 numeric digits).
# Display in 8 space-separated groups of 6 for readability, but the
# spaces are display-only — the actual passphrase passed to luksFormat
# (and typed at boot) is the raw 48-digit string with no separators.
# That matches BitLocker's recovery-key UX exactly: digits + visual
# grouping + no need to type the separators.
#
# Why generated, not user-typed:
#   - Eliminates the fat-finger-twice-and-not-know-it failure mode the old
#     prompt_luks had (mismatch only catches typos *between* the two entries,
#     not consistent typos in both).
#   - 48 digits = ~159 bits entropy — strong enough; KDF stretches further.
#   - Symmetric UX with BitLocker: photograph once, transcribe to Bitwarden
#     at leisure, never type again unless the TPM seal breaks.
gen_and_show_luks_passphrase() {
    local key display_key ack
    # 48 numeric digits from /dev/urandom. tr -dc strips everything but
    # 0-9; head -c 48 caps the stream. /dev/urandom is the cryptographic
    # PRNG; openssl rand isn't needed (and `openssl rand -hex` would give
    # us 0-9a-f which is what we *don't* want here).
    key=$(tr -dc '0-9' </dev/urandom | head -c 48)
    # Display form only: insert a space every 6 digits.
    display_key=$(printf '%s' "$key" | sed 's/.\{6\}/& /g; s/ $//')

    # Red-banner BitLocker-style box (ported from install-auto-luks) plus
    # main's lighter "I HAVE THE KEY" ack (no full retype — 48 digits is
    # already plenty to fat-finger on a TTY).
    {
        printf '\n'
        printf '\033[1;37;41m%s\033[0m\n' "╔══════════════════════════════════════════════════════════════════════╗"
        printf '\033[1;37;41m%s\033[0m\n' "║                  LUKS RECOVERY KEY — SAVE THIS NOW                   ║"
        printf '\033[1;37;41m%s\033[0m\n' "║                                                                      ║"
        printf '\033[1;37;41m║   \033[1;33;41m%s\033[1;37;41m   ║\033[0m\n' "$display_key"
        printf '\033[1;37;41m%s\033[0m\n' "║                                                                      ║"
        printf '\033[1;37;41m%s\033[0m\n' "║   Save to Bitwarden as 'Metis LUKS'. This key will NOT be written    ║"
        printf '\033[1;37;41m%s\033[0m\n' "║   to any disk. Once install continues, it exists only inside the     ║"
        printf '\033[1;37;41m%s\033[0m\n' "║   LUKS header — no paper trail, no backup, no recovery from us.      ║"
        printf '\033[1;37;41m%s\033[0m\n' "║   When typing at the LUKS prompt: digits ONLY, no spaces.            ║"
        printf '\033[1;37;41m%s\033[0m\n' "╚══════════════════════════════════════════════════════════════════════╝"
        printf '\n'
        printf '  Type \033[1mI HAVE THE KEY\033[0m (case-sensitive, exactly) to continue:\n'
    } >&2

    while :; do
        read -rp '> ' ack </dev/tty
        [[ "$ack" == "I HAVE THE KEY" ]] && break
        printf '  (didn'"'"'t match — type "I HAVE THE KEY" exactly to confirm you photographed it)\n' >&2
    done

    printf '%s' "$key"
}

# Cleanup trap: on any failure, unmount /mnt and close LUKS mappers so a
# retry can start clean. Without this, a mid-run abort leaves the new btrfs
# mounted, Netac ext4 mounted, swap active, and the mappers held — next run
# dies at `mount /mnt` or `cryptsetup open` ("device busy").
cleanup_on_fail() {
    local rc=$?
    (( rc == 0 )) && return
    warn "install.sh aborted (exit $rc) — unmounting /mnt + closing LUKS for clean retry..."
    sync 2>/dev/null || true
    swapoff -a 2>/dev/null || true
    # Shred the pre-hashed-password file before unmount so nothing lingers
    # even on abort. rm -f instead of shred keeps this cheap (it's already
    # on a tmpfs-ish mount about to be torn down).
    rm -f /mnt/root/.pw /mnt/root/.luks 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true
    # Close LUKS mappers in reverse order (cryptvar may depend on nothing,
    # but cryptroot's btrfs holds the cryptvar keyfile via /mnt mount).
    cryptsetup close cryptswap 2>/dev/null || true
    cryptsetup close cryptvar  2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
}
trap cleanup_on_fail EXIT

confirm() {
    local prompt="${1:-Continue?}"
    read -rp "$prompt [yes/NO]: " reply
    [[ "$reply" == "yes" ]] || die "Aborted by user."
}

# ---------- 0. sanity ----------
[[ $EUID -eq 0 ]]                       || die "Run as root."
[[ -d /sys/firmware/efi/efivars ]]      || die "Not booted in UEFI mode."
command -v pacstrap >/dev/null          || die "pacstrap missing — not in Arch live env?"
command -v cryptsetup >/dev/null        || die "cryptsetup missing — not in Arch live env? (FDE requires it)"

# Defensive: close any leftover dm-crypt mappers from a prior aborted run.
# cleanup_on_fail handles normal aborts, but hard crashes (power, kernel
# panic) or a user Ctrl+C between steps can leave mappers open. sgdisk
# then refuses to repartition, cryptsetup luksFormat errors with "device
# in use", etc. Close in reverse dependency order; errors are tolerated
# because the common case is nothing to close.
swapoff -a 2>/dev/null || true
umount -R /mnt 2>/dev/null || true
for _map in cryptswap cryptvar cryptroot; do
    [[ -e "/dev/mapper/$_map" ]] && {
        log "Closing stale mapper /dev/mapper/$_map from a previous run..."
        cryptsetup close "$_map" 2>/dev/null || warn "  couldn't close $_map — continuing anyway"
    }
done
unset _map

# ---------- 0.5 source dir (repo clone, resolved from the script's own path) ----------
# Canonical install: boot vanilla Arch ISO (from Ventoy — USB or Netac),
# `git clone https://github.com/fnrhombus/arch-setup ...`, run this script
# from inside the clone. SOURCE_DIR = the clone's root.
#
# No baked-in-ISO variant, no /run/ventoy dm-linear self-mount — both were
# tried and both had sharp edges (custom-ISO build maintenance overhead;
# Ventoy dm-linear random-access reads on internal-SATA bootstrap throwing
# Buffer I/O errors). The clone-and-run path has zero filesystem
# acrobatics: everything install.sh needs is in the clone.
SCRIPT_PARENT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
[[ -n "$SCRIPT_PARENT" && -f "$SCRIPT_PARENT/phase-2-arch-install/chroot.sh" ]] \
    || die "Not a valid arch-setup clone — chroot.sh missing next to install.sh. Did you clone the repo, or did you extract just this one script?"
SOURCE_DIR="$SCRIPT_PARENT"
unset SCRIPT_PARENT
log "Using repo clone at $SOURCE_DIR."

# ---------- 1. locate disks by size ----------
# decisions.md §Q9: Samsung 512 GB nominal (~476 GiB actual), Netac 128 GB nominal (~119 GiB actual).
# Sizes here are GiB (binary), not GB (decimal). Windows are widened to tolerate vendor capacity drift.
SAMSUNG=""
NETAC=""
while read -r dev size; do
    gib=$(( size / 1024 / 1024 / 1024 ))
    if (( gib >= 450 && gib <= 520 )); then SAMSUNG="/dev/$dev"
    elif (( gib >= 100 && gib <= 150 )); then NETAC="/dev/$dev"
    fi
done < <(lsblk -b -d -n -o NAME,SIZE -e 7,11)  # exclude loop + rom

[[ -n "$SAMSUNG" ]] || die "No 450-520 GiB disk detected (expected Samsung SSD 840 PRO 512GB ~ 476 GiB)."
[[ -n "$NETAC"   ]] || die "No 100-150 GiB disk detected (expected Netac 128GB ~ 119 GiB)."

log "Samsung (install target): $SAMSUNG"
log "Netac  (recovery+swap+/var): $NETAC"

# Sanity: Samsung must already have GPT with at least 3 partitions (EFI, MSR, Windows).
# If not, phase-1 Windows install didn't run.
part_count=$(lsblk -n -o NAME "$SAMSUNG" | tail -n +2 | wc -l)
(( part_count >= 3 )) || die "Samsung has <3 partitions. Run Windows install (phase 1) first."

# ---------- 1.5 Ventoy-on-Netac detection ----------
# If the Netac was bootstrapped as a Ventoy boot medium (no-USB install
# path — Ventoy2Disk installed onto the Netac with reserved space at the
# tail), we want to PRESERVE Ventoy as the recovery rather than wiping it.
# In that mode, only the reserved region (partitions 3 + 4) gets carved
# into swap + var; the Ventoy data partition (sdb1, NTFS) and VTOYEFI
# companion (sdb2, FAT) stay untouched — they ARE the recovery.
#
# Detection: the "Ventoy" filesystem label sits on Ventoy's data partition.
# If its parent disk is $NETAC, Ventoy-on-Netac mode is active.
VENTOY_ON_NETAC=0
_ventoy_part=$(blkid -L Ventoy 2>/dev/null || true)
if [[ -n "$_ventoy_part" ]]; then
    _ventoy_disk=$(lsblk -ndo PKNAME "$_ventoy_part" 2>/dev/null || true)
    if [[ -n "$_ventoy_disk" && "/dev/$_ventoy_disk" == "$NETAC" ]]; then
        VENTOY_ON_NETAC=1
        log "Ventoy detected on $NETAC — reserved-region layout (Ventoy preserved as recovery)."
    fi
fi
unset _ventoy_part _ventoy_disk

# ---------- 2. network ----------
# Embedded Wi-Fi profiles. Mirror these in chroot.sh WIFI_PROFILES and in
# autounattend.xml's FirstLogon Wi-Fi block. Format: "SSID:PSK"
WIFI_PROFILES=(
    "ATTgs5BwGZ:t8ueiz43ueaf"
    "rhombus:n3wPassword"
    "rhombus_legacy:n3wPassword"
)

if ! ping -c1 -W3 archlinux.org >/dev/null 2>&1; then
    log "No internet yet; trying embedded Wi-Fi profiles..."
    rfkill unblock all 2>/dev/null || true
    systemctl start iwd 2>/dev/null || true
    sleep 1
    WIFI_DEV=$(iwctl device list 2>/dev/null | awk '/station/ {print $2; exit}')
    if [[ -n "$WIFI_DEV" ]]; then
        # Scan once so iwd knows what's in range
        iwctl station "$WIFI_DEV" scan 2>/dev/null || true
        sleep 3
        SEEN=$(iwctl station "$WIFI_DEV" get-networks 2>/dev/null || true)
        for pair in "${WIFI_PROFILES[@]}"; do
            s="${pair%%:*}"; p="${pair#*:}"
            if grep -qF "$s" <<<"$SEEN"; then
                log "Trying $s..."
                iwctl --passphrase "$p" station "$WIFI_DEV" connect "$s" 2>/dev/null || continue
                for _ in 1 2 3 4 5 6 7 8; do
                    ping -c1 -W2 archlinux.org >/dev/null 2>&1 && break 2
                    sleep 2
                done
            fi
        done
    fi
fi
if ! ping -c1 -W3 archlinux.org >/dev/null 2>&1; then
    die "Still no internet. Run 'iwctl' manually or plug in ethernet, then re-run."
fi
log "Network: OK"
timedatectl set-ntp true

# ---------- 2.5 collect passwords + LUKS passphrase up-front ----------
# Prompt now so the long pacstrap + chroot stretch is unattended. Account
# password hashes are handed to chroot.sh via /mnt/root/.pw (mode 600);
# cleanup_on_fail and the post-chroot rm -f together ensure the file never
# survives this script. Requires openssl, which is in the Arch live ISO.
#
# LUKS passphrase stays in an in-memory variable for the duration of this
# script — used to luksFormat both volumes and to luksAddKey the cryptvar
# keyfile — then unset before exit. Never touches disk.
command -v openssl >/dev/null || die "openssl not found in live env — needed for password hashing + LUKS key generation."
log "Collecting passwords now (you won't be prompted again during install)."
log "After the two account passwords, a 48-char LUKS recovery key will be generated and displayed for you to photograph."
ROOT_PW_HASH=$(prompt_password "root")
TOM_PW_HASH=$(prompt_password "tom")
LUKS_PW=$(gen_and_show_luks_passphrase)

# ---------- 3. confirm ----------
cat <<EOF

About to:
  - Leave Samsung partitions 1, 2, 3 (EFI, MSR, Windows) UNTOUCHED
  - Create one new LUKS2 + btrfs partition in the trailing unallocated space of $SAMSUNG
EOF
if (( VENTOY_ON_NETAC )); then
    cat <<EOF
  - Leave Netac partitions 1, 2 (Ventoy data + VTOYEFI) UNTOUCHED — they stay as recovery
  - Create 2 new LUKS2 partitions in $NETAC's reserved region:
      - LUKS2 swap w/ random key (16 GB)
      - LUKS2 ext4 for /var/log + /var/cache (rest of reserved region)
EOF
else
    cat <<EOF
  - WIPE $NETAC entirely (GPT label, 3 new partitions: recovery ISO,
    LUKS2 swap w/ random key, LUKS2 ext4 for /var/log + /var/cache)
EOF
fi
cat <<EOF
  - pacstrap a full Arch system and configure per decisions.md

EOF
confirm "Proceed?"

# ---------- 4. Samsung: add btrfs partition in trailing free space ----------
log "Adding btrfs partition in trailing free space on $SAMSUNG..."
# A previous aborted install.sh run may have left an "ArchRoot" partition
# (or several) consuming the trailing free space. Delete any partition with
# number > 3 before re-creating, so --largest-new finds room. Windows
# partitions 1-3 (EFI, MSR, Windows) stay untouched.
for n in $(sgdisk --print "$SAMSUNG" | awk '$1 ~ /^[0-9]+$/ && $1 > 3 {print $1}' | sort -rn); do
    log "  removing stale partition ${SAMSUNG}${n}"
    sgdisk --delete="$n" "$SAMSUNG"
done
partprobe "$SAMSUNG"
udevadm settle

# `sgdisk --largest-new` creates the largest possible new partition from free space.
sgdisk --largest-new=0 --typecode=0:8300 --change-name=0:ArchRoot "$SAMSUNG"
partprobe "$SAMSUNG"
udevadm settle

# Find the new partition by its PARTLABEL rather than "highest partition number"
# — if Windows ever adds a Recovery partition between MSR and Windows (which
# some install paths do), `tail -1` would pick the wrong one and we'd mkfs over
# Windows. PARTLABEL="ArchRoot" is set by --change-name above and is unique.
# -l (list, no tree) is CRITICAL: without it lsblk prefixes NAME with tree
# glyphs like "└─sda4", which we'd then treat as "sda4 with line-drawing
# characters" and happily mkfs the wrong (nonexistent) device path.
SAMSUNG_ROOT=$(lsblk -ln -o NAME,PARTLABEL "$SAMSUNG" | awk '$2 == "ArchRoot" {print $1; exit}')
[[ -n "$SAMSUNG_ROOT" ]] || die "Could not find ArchRoot partition after sgdisk — check lsblk output."
SAMSUNG_ROOT="/dev/$SAMSUNG_ROOT"
log "New Linux root partition: $SAMSUNG_ROOT"

# Samsung EFI partition (first partition, created by Windows install).
SAMSUNG_EFI=$(lsblk -ln -o NAME,PARTTYPE "$SAMSUNG" | awk '$2 ~ /c12a7328-f81f-11d2-ba4b-00a0c93ec93b/ {print $1; exit}')
[[ -n "$SAMSUNG_EFI" ]] || die "Could not find EFI System partition on Samsung."
SAMSUNG_EFI="/dev/$SAMSUNG_EFI"
log "EFI System partition: $SAMSUNG_EFI"

# ---------- 5. Netac: partition ----------
# Two layouts, chosen by VENTOY_ON_NETAC (§1.5):
#   reserved-region — preserve sdb1 (Ventoy data) + sdb2 (VTOYEFI); carve
#                     swap + var into the trailing reserved free space.
#                     Ventoy itself IS the recovery; no separate partition.
#   greenfield     — wipe the whole Netac, create ArchRecovery +
#                     ArchSwap + ArchVar from scratch. ArchRecovery gets
#                     the Arch ISO dd'd onto it in §12.
if (( VENTOY_ON_NETAC )); then
    log "Partitioning $NETAC reserved region (Ventoy data + VTOYEFI preserved)..."
    # A previous aborted install.sh run (or any prior LUKS attempt) may have
    # left partitions 3+/4+ in place. sgdisk --new refuses to overwrite an
    # existing partition number — it'll log "Could not create partition N
    # from 40 to 2047" and abort. Delete partitions > 2 in reverse order so
    # the table doesn't get renumbered mid-loop, leaving sdb1 (Ventoy data)
    # + sdb2 (VTOYEFI) intact.
    for n in $(sgdisk --print "$NETAC" | awk '$1 ~ /^[0-9]+$/ && $1 > 2 {print $1}' | sort -rn); do
        log "  removing stale Netac partition ${NETAC}${n}"
        sgdisk --delete="$n" "$NETAC"
    done
    partprobe "$NETAC"
    udevadm settle
    # sgdisk --new=N:0:... starts at the first free sector after the highest
    # existing partition — which is VTOYEFI (partition 2) for Ventoy-on-Netac
    # installed via Ventoy2Disk -r. So partitions 3 + 4 land in the reserved
    # region without touching 1 or 2.
    sgdisk \
        --new=3:0:+16G --typecode=3:8200 --change-name=3:ArchSwap \
        --new=4:0:0    --typecode=4:8300 --change-name=4:ArchVar  \
        "$NETAC"
    _NETAC_RECOVERY_N=""   # Ventoy IS the recovery; no separate slot.
    _NETAC_SWAP_N=3
    _NETAC_VAR_N=4
else
    log "Wiping and partitioning $NETAC..."
    sgdisk --zap-all "$NETAC"
    sgdisk \
        --new=1:0:+1536M --typecode=1:8300 --change-name=1:ArchRecovery \
        --new=2:0:+16G   --typecode=2:8200 --change-name=2:ArchSwap     \
        --new=3:0:0      --typecode=3:8300 --change-name=3:ArchVar      \
        "$NETAC"
    _NETAC_RECOVERY_N=1
    _NETAC_SWAP_N=2
    _NETAC_VAR_N=3
fi
partprobe "$NETAC"
udevadm settle

# Portable partition-device resolver (sda<N> vs nvme0n1p<N>).
# CAREFUL: split the two `local` statements. Bash evaluates `${n}` in
# `local n="$1" path="${NETAC}${n}"` using the OUTER scope's `n` (the
# `for n in ...` prune loop above leaves outer n=last_pruned_partition),
# not the just-declared local. That made every call resolve to the same
# wrong device.
_netac_part() {
    local n="$1"
    local path="${NETAC}${n}"
    [[ -b "$path" ]] || path="${NETAC}p${n}"
    printf '%s' "$path"
}
NETAC_SWAP=$(_netac_part "$_NETAC_SWAP_N")
NETAC_VAR=$(_netac_part "$_NETAC_VAR_N")
if [[ -n "$_NETAC_RECOVERY_N" ]]; then
    NETAC_RECOVERY=$(_netac_part "$_NETAC_RECOVERY_N")
else
    NETAC_RECOVERY=""
fi
unset -f _netac_part
unset _NETAC_RECOVERY_N _NETAC_SWAP_N _NETAC_VAR_N

# Defensive: the two block devices below get separate cryptsetup luksFormat
# calls, so they MUST be distinct block devices. If they collide (something
# wrong with the resolver or the kernel's view of the partition table), the
# second luksFormat fails mid-way with "device in use" AFTER the first has
# written a LUKS header — leaving the retry needing a `cryptsetup close`
# that the cleanup trap does but the user can't see. Fail loud, up front.
log "Resolved Netac partitions: SWAP=$NETAC_SWAP  VAR=$NETAC_VAR  RECOVERY=${NETAC_RECOVERY:-<none>}"
[[ -b "$NETAC_SWAP" ]] || die "NETAC_SWAP=$NETAC_SWAP is not a block device. Kernel may not have re-read the partition table after sgdisk — try \`blockdev --rereadpt $NETAC\` manually and retry."
[[ -b "$NETAC_VAR"  ]] || die "NETAC_VAR=$NETAC_VAR is not a block device. Same cause as above."
[[ "$NETAC_SWAP" != "$NETAC_VAR" ]] || die "NETAC_SWAP and NETAC_VAR both resolved to $NETAC_SWAP. Resolver bug or sgdisk didn't create both partitions."

# ---------- 6. LUKS format + filesystems ----------
# Encrypt both data partitions with the same passphrase. The passphrase is
# the ONLY key at install time; phase 3's postinstall.sh enrolls TPM2 later
# so boot becomes silent. Passphrase stays as the recovery fallback.
#
# luksFormat defaults: LUKS2 + argon2id KDF + aes-xts-plain64. --batch-mode
# suppresses the "THIS WILL OVERWRITE DATA" confirmation (we already got
# the user's `yes` in section 3). --key-file=- reads the passphrase from
# stdin so it never appears in `ps`.
log "Encrypting Samsung root ($SAMSUNG_ROOT) with LUKS2..."
printf '%s' "$LUKS_PW" | cryptsetup luksFormat --type luks2 --batch-mode \
    --label ArchRootLUKS --key-file=- "$SAMSUNG_ROOT"
printf '%s' "$LUKS_PW" | cryptsetup open --key-file=- "$SAMSUNG_ROOT" cryptroot

log "Encrypting Netac /var ($NETAC_VAR) with LUKS2..."
printf '%s' "$LUKS_PW" | cryptsetup luksFormat --type luks2 --batch-mode \
    --label ArchVarLUKS --key-file=- "$NETAC_VAR"
printf '%s' "$LUKS_PW" | cryptsetup open --key-file=- "$NETAC_VAR" cryptvar

# Hibernate-ready swap: persistent LUKS2 (NOT a per-boot random key) so
# the resume-from-hibernate image survives a power cycle. Same passphrase
# as cryptroot — sd-encrypt's keyring cache opens cryptswap silently from
# the cryptroot passphrase during first boot, so users only type it once
# even though cryptswap is in crypttab.initramfs (required by resume=).
# Phase-3 postinstall enrolls TPM2 on both volumes, flipping the boot to
# fully silent from the second boot onward.
log "Encrypting Netac swap ($NETAC_SWAP) with LUKS2 (persistent, hibernate-ready)..."
printf '%s' "$LUKS_PW" | cryptsetup luksFormat --type luks2 --batch-mode \
    --label ArchSwapLUKS --key-file=- "$NETAC_SWAP"
printf '%s' "$LUKS_PW" | cryptsetup open --key-file=- "$NETAC_SWAP" cryptswap

log "Creating filesystems on LUKS mappers..."
mkfs.btrfs -f -L ArchRoot /dev/mapper/cryptroot
mkfs.ext4  -F -L ArchVar  /dev/mapper/cryptvar
mkswap     -L ArchSwap    /dev/mapper/cryptswap
# Don't swapon at install time — pacstrap doesn't need it (16 GB RAM) and
# an active swap would block the cryptsetup close at the bottom of install.
# NETAC_RECOVERY stays raw and unencrypted — we dd the Arch ISO onto it later.
# (Rationale: recovery partition is intentionally bootable as-is; encrypting
# it would defeat the "boot this from F12 if Arch is hosed" survival path.)

# ---------- 7. btrfs subvolumes ----------
log "Creating btrfs subvolumes..."
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt

# ---------- 8. mount ----------
log "Mounting filesystems..."
MOPTS="noatime,compress=zstd:3,space_cache=v2,ssd"
mount -o "$MOPTS,subvol=@"          /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,boot,var/log,var/cache}
mount -o "$MOPTS,subvol=@home"      /dev/mapper/cryptroot /mnt/home
mount -o "$MOPTS,subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots
mount "$SAMSUNG_EFI" /mnt/boot
# Netac ext4 at /var: we mount the single ext4 volume at /var and bind-mount
# /var/log and /var/cache from it. Simpler: mount it at an intermediate path
# and bind the two subdirs. But cleanest: put /var itself on Netac. However,
# decisions.md §Q9 says "/var/log + /var/cache on Netac" (not all of /var),
# so use two subdirs + bind mounts so other /var paths stay on btrfs.
mkdir -p /mnt/mnt/netac-var
mount /dev/mapper/cryptvar /mnt/mnt/netac-var
mkdir -p /mnt/mnt/netac-var/{log,cache}
mount --bind /mnt/mnt/netac-var/log   /mnt/var/log
mount --bind /mnt/mnt/netac-var/cache /mnt/var/cache

# ---------- 8.5 cryptvar keyfile (for unattended unlock at boot) ----------
# cryptroot prompts for the passphrase at boot; cryptvar is unlocked from a
# keyfile living on the (now-unlocked) root fs so the user doesn't type the
# passphrase twice. The keyfile is 4096 random bytes, mode 400, root:root,
# at /etc/cryptsetup-keys.d/cryptvar.key — a path systemd-cryptsetup-generator
# understands natively.
log "Generating keyfile for cryptvar auto-unlock..."
install -d -m 700 /mnt/etc/cryptsetup-keys.d
(umask 077 && dd if=/dev/urandom of=/mnt/etc/cryptsetup-keys.d/cryptvar.key \
    bs=512 count=8 status=none)
chmod 400 /mnt/etc/cryptsetup-keys.d/cryptvar.key
printf '%s' "$LUKS_PW" | cryptsetup luksAddKey --key-file=- \
    "$NETAC_VAR" /mnt/etc/cryptsetup-keys.d/cryptvar.key

# Wipe any Arch-managed files left on the EFI System Partition from a
# previous aborted install. Phase 1 mkfs'd the ESP fresh for Windows, so
# Microsoft's bootloader must survive; only Arch's kernel/initramfs/ucode
# would conflict with pacstrap's next run.
rm -f /mnt/boot/intel-ucode.img \
      /mnt/boot/amd-ucode.img \
      /mnt/boot/initramfs-linux*.img \
      /mnt/boot/vmlinuz-linux*

# ---------- 9. pacstrap ----------
log "Running pacstrap (this pulls ~1-2 GB over the network)..."
pacstrap -K /mnt \
    base base-devel linux linux-firmware linux-headers linux-lts linux-lts-headers intel-ucode \
    btrfs-progs e2fsprogs dosfstools \
    networkmanager iwd wpa_supplicant openssh \
    sudo git vim helix \
    zsh tmux \
    efibootmgr \
    man-db man-pages texinfo \
    pipewire pipewire-pulse pipewire-jack wireplumber \
    hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
    polkit \
    noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd \
    mesa intel-media-driver vulkan-intel libva-intel-driver \
    bluez bluez-utils \
    fprintd \
    snapper

# ---------- 10. fstab ----------
log "Generating /etc/fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Harden the two bind mounts: systemd mounts entries in parallel unless we
# tell it otherwise. /var/log and /var/cache need to wait for the ext4 at
# /mnt/netac-var to be mounted first, or the binds race and either fail or
# bind to the empty btrfs mountpoint under /var. Rewrite both entries to
# include x-systemd.requires-mounts-for=/mnt/netac-var.
python3 - <<'PYEOF' || warn "fstab post-process failed — check /mnt/etc/fstab by hand."
import re
p = "/mnt/etc/fstab"
with open(p) as f: src = f.read()
out = []
DEP = "x-systemd.requires-mounts-for=/mnt/netac-var"
for line in src.splitlines():
    parts = line.split()
    # fstab: <src> <target> <fstype> <options> <dump> <pass>
    if len(parts) >= 4 and parts[1] in ("/var/log", "/var/cache") and "bind" in parts[3].split(","):
        if DEP not in parts[3]:
            parts[3] = parts[3] + "," + DEP
            line = "\t".join(parts)
    out.append(line)
with open(p, "w") as f: f.write("\n".join(out) + "\n")
PYEOF

# ---------- 11. chroot config ----------
log "Staging chroot script + repo..."
cp "$SOURCE_DIR/phase-2-arch-install/chroot.sh" /mnt/root/chroot.sh
chmod +x /mnt/root/chroot.sh

# Stage the entire repo at /root/arch-setup/ inside the chroot so chroot.sh
# can install greetd system-files from phase-3-arch-postinstall/system-files/
# and so postinstall can find dotfiles/ for chezmoi init.
mkdir -p /mnt/root/arch-setup
cp -r "$SOURCE_DIR"/. /mnt/root/arch-setup/

# Hand the pre-hashed passwords to the chroot via a root-owned mode-600
# file. chroot.sh reads + shreds it. cleanup_on_fail also rm -f's it so an
# abort mid-chroot doesn't leave hashes behind on the freshly-installed fs.
(umask 077 && printf '%s\n%s\n' "$ROOT_PW_HASH" "$TOM_PW_HASH" > /mnt/root/.pw)

# Hand partition LUKS UUIDs to chroot.sh for crypttab + cmdline wiring.
# All three now have persistent LUKS2 headers.
LUKS_ROOT_UUID=$(blkid -s UUID -o value "$SAMSUNG_ROOT")
LUKS_VAR_UUID=$(blkid -s UUID -o value "$NETAC_VAR")
LUKS_SWAP_UUID=$(blkid -s UUID -o value "$NETAC_SWAP")
[[ -n "$LUKS_ROOT_UUID" && -n "$LUKS_VAR_UUID" && -n "$LUKS_SWAP_UUID" ]] \
    || die "Failed to resolve LUKS UUIDs (blkid returned empty)."
(umask 077 && cat > /mnt/root/.luks <<EOF
LUKS_ROOT_UUID=$LUKS_ROOT_UUID
LUKS_VAR_UUID=$LUKS_VAR_UUID
LUKS_SWAP_UUID=$LUKS_SWAP_UUID
SAMSUNG_DISK=$SAMSUNG
EOF
)

arch-chroot /mnt /root/chroot.sh
rm -f /mnt/root/.pw /mnt/root/.luks

# Passphrase was only needed for luksFormat + luksAddKey; scrub from memory.
unset LUKS_PW

# ---------- 12. recovery partition ----------
# Skipped if NETAC_RECOVERY is empty (no separate recovery partition in the
# chosen layout). Otherwise tries to dd an Arch ISO onto it; if no ISO is
# available (e.g. the Netac-Ventoy bootstrap wiped the ISO source along
# with the Netac in §5, and the live ISO isn't reachable as a block device
# either), WARN instead of dying — install completes with an empty recovery
# partition, user populates it manually later. Better than aborting after
# pacstrap + chroot have already succeeded.
if [[ -z "$NETAC_RECOVERY" ]]; then
    log "No separate recovery partition in this layout; skipping ISO write."
else
    # Look for the Arch ISO at: (a) SOURCE_DIR, (b) custom-ISO live-boot
    # fallback (the running ISO IS what we'd dd; use the live device).
    ARCH_ISO=$(ls "$SOURCE_DIR"/archlinux-*.iso 2>/dev/null | head -1 || true)
    if [[ -z "$ARCH_ISO" || ! -f "$ARCH_ISO" ]] && [[ -d /run/archiso/bootmnt ]]; then
        log "  No Arch ISO file in source; checking the live ISO image itself."
        LIVE_ISO_DEV=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null | head -1)
        if [[ -b "$LIVE_ISO_DEV" ]]; then
            ARCH_ISO="$LIVE_ISO_DEV"
        fi
    fi
    if [[ -z "$ARCH_ISO" ]]; then
        warn "No Arch ISO found (checked $SOURCE_DIR + /run/archiso). Skipping recovery write."
        warn "  Populate manually after boot: sudo dd if=/path/to/archlinux-x86_64.iso of=$NETAC_RECOVERY bs=4M conv=fsync"
    else
        log "Writing Arch ISO to recovery partition $NETAC_RECOVERY..."
        # Size-gate: NETAC_RECOVERY is 1536 MiB. A larger ISO would dd past the
        # partition boundary into NETAC_SWAP with no error, silently corrupting swap.
        ISO_BYTES=$(stat -c%s "$ARCH_ISO")
        PART_BYTES=$(blockdev --getsize64 "$NETAC_RECOVERY")
        if (( ISO_BYTES > PART_BYTES )); then
            warn "Arch ISO ($ISO_BYTES bytes) is larger than recovery partition ($PART_BYTES bytes). Skipping."
            warn "  Resize NETAC_RECOVERY in install.sh or populate with a smaller ISO later."
        else
            dd if="$ARCH_ISO" of="$NETAC_RECOVERY" bs=4M status=progress conv=fsync
        fi
    fi
fi

# ---------- 13. post-install hook ----------
# Stage phase-3 script + setup-azure-ddns + the dotfiles tree where the
# user can run them after first login. (The full repo is already at
# /mnt/root/arch-setup/ from the staging step in §11.)
install -d -m 755 /mnt/home/tom
cp "$SOURCE_DIR/phase-3-arch-postinstall/postinstall.sh"     /mnt/home/tom/postinstall.sh 2>/dev/null \
    || warn "phase-3 script missing — copy it later from /root/arch-setup."
cp "$SOURCE_DIR/phase-3-arch-postinstall/setup-azure-ddns.sh" /mnt/home/tom/setup-azure-ddns.sh 2>/dev/null || true
chmod +x /mnt/home/tom/postinstall.sh /mnt/home/tom/setup-azure-ddns.sh 2>/dev/null || true
# Dotfiles (Claude-authored, chezmoi-managed) live at /root/arch-setup/dotfiles
# and are applied by postinstall via `chezmoi init --source=...`.
arch-chroot /mnt chown -R tom:tom /home/tom

# ---------- 14. cleanup ----------
log "Syncing + unmounting..."
sync
umount -R /mnt
# Close LUKS mappers so a retry (or a manual `cryptsetup luksFormat` later)
# doesn't trip on "device still in use". All three have LUKS headers now;
# cryptswap was opened at §6 for mkswap, so close it here too.
cryptsetup close cryptswap || true
cryptsetup close cryptvar  || true
cryptsetup close cryptroot || true

cat <<EOF

Done. Remove the USB and reboot.

First boot asks for the LUKS passphrase (you set it at the top of this run).
Log in as 'tom', then:
    ./postinstall.sh           # installs yay, zgenom, chezmoi (applies the
                               # bare-Hyprland dotfiles + matugen pipeline),
                               # fingerprint, TPM2 enroll for silent LUKS
                               # unlock, ufw, metis-ddns, printer drivers, etc.
EOF
