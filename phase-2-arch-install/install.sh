#!/usr/bin/env bash
# phase-2-arch-install/install.sh
#
# Run from the Arch live environment (boot archlinux-*.iso via any Ventoy
# loader — USB stick or on-disk Netac recovery). Reads every decision from
# docs/decisions.md §Q9 and lays down Arch on:
#   - Samsung 512 GB SSD : LUKS2 + btrfs in the trailing ~316 GB unallocated
#                          (Windows EFI/MSR/Windows partitions untouched)
#   - Netac 128 GB SSD   : recovery ISO slot (unpopulated — see below) +
#                          LUKS2 swap (16 GB, random key per boot) +
#                          LUKS2 ext4 (~110 GB, keyfile-unlocked) for
#                          /var/log + /var/cache
#
# Full-disk encryption per decisions.md §Q11 — parity with Windows BitLocker.
# Post-install phase 3 enrolls TPM2 so boot becomes silent (passphrase or
# recovery key stays as fallback).
#
# NETAC_RECOVERY partition is created but not populated with an Arch ISO
# (the cloned repo doesn't carry the ISO — gitignored). Fill it manually
# later if desired:
#   sudo dd if=/path/to/archlinux-x86_64.iso of=<NETAC_RECOVERY> bs=4M conv=fsync
#
# All disk operations are size-gated: the script aborts if the expected
# disks are absent or if anything looks off. Never silently clobbers.
#
# Usage:
#   pacman -Sy --noconfirm git
#   git clone https://github.com/fnrhombus/arch-setup /tmp/arch-setup
#   iwctl                                  # connect wifi if no ethernet
#   bash /tmp/arch-setup/phase-2-arch-install/install.sh

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

# Prompt twice for a LUKS passphrase and print the plaintext on stdout.
# Unlike prompt_password above (which hashes for /etc/shadow), cryptsetup needs
# the plaintext — it hashes internally via argon2id. Caller must keep it in
# memory only; never let it touch disk.
prompt_luks() {
    local label="$1" p1 p2
    while :; do
        read -rsp "LUKS passphrase for $label: " p1 </dev/tty; printf '\n' >&2
        read -rsp "  confirm $label passphrase: " p2 </dev/tty; printf '\n' >&2
        if [[ ${#p1} -lt 8 ]]; then
            warn "  (too short — 8+ chars; 12+ recommended. This is your recovery fallback if the TPM loses its seal.)"
        elif [[ "$p1" != "$p2" ]]; then
            warn "  (didn't match — try again)"
        else
            break
        fi
    done
    printf '%s' "$p1"
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

# ---------- 0.5 locate the cloned repo ----------
# Source files (chroot.sh, phase-3 scripts, p10k sidecar) are read from the
# script's own parent directory — the repo clone. $REPO_ROOT names the
# resolved path. The earlier Ventoy-USB variant of this script has been
# removed; clone-only is the canonical path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
log "Using repo clone at $REPO_ROOT."
[[ -f "$REPO_ROOT/phase-2-arch-install/chroot.sh" ]] \
    || die "$REPO_ROOT/phase-2-arch-install/chroot.sh missing — is this really a clone of the repo?"

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
command -v openssl >/dev/null || die "openssl not found in live env — needed for password hashing."
log "Collecting passwords + LUKS passphrase now (you won't be prompted again during install)."
log "The LUKS passphrase is what you'll type at boot if the TPM ever loses its seal — stash it in Bitwarden."
ROOT_PW_HASH=$(prompt_password "root")
TOM_PW_HASH=$(prompt_password "tom")
LUKS_PW=$(prompt_luks "disk encryption (used for both Samsung root and Netac /var)")

# ---------- 3. confirm ----------
cat <<EOF

About to:
  - Leave Samsung partitions 1, 2, 3 (EFI, MSR, Windows) UNTOUCHED
  - Create one new LUKS2 + btrfs partition in the trailing unallocated space of $SAMSUNG
  - WIPE $NETAC entirely (GPT label, 3 new partitions: recovery ISO,
    LUKS2 swap w/ random key, LUKS2 ext4 for /var/log + /var/cache)
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

# ---------- 5. Netac: wipe and partition ----------
log "Wiping and partitioning $NETAC..."
sgdisk --zap-all "$NETAC"
sgdisk \
    --new=1:0:+1536M --typecode=1:8300 --change-name=1:ArchRecovery \
    --new=2:0:+16G   --typecode=2:8200 --change-name=2:ArchSwap     \
    --new=3:0:0      --typecode=3:8300 --change-name=3:ArchVar      \
    "$NETAC"
partprobe "$NETAC"
udevadm settle

NETAC_RECOVERY="${NETAC}1"; [[ -b "$NETAC_RECOVERY" ]] || NETAC_RECOVERY="${NETAC}p1"
NETAC_SWAP="${NETAC}2";     [[ -b "$NETAC_SWAP"     ]] || NETAC_SWAP="${NETAC}p2"
NETAC_VAR="${NETAC}3";      [[ -b "$NETAC_VAR"      ]] || NETAC_VAR="${NETAC}p3"

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

log "Creating filesystems on LUKS mappers..."
mkfs.btrfs -f -L ArchRoot /dev/mapper/cryptroot
mkfs.ext4  -F -L ArchVar  /dev/mapper/cryptvar
# Swap is encrypted via /dev/urandom per boot (see /etc/crypttab in chroot.sh)
# so we don't mkswap here — crypttab's `swap` option does it each boot against
# /dev/mapper/cryptswap. The live ISO doesn't need swap (16 GB RAM is plenty
# for pacstrap), so there's no benefit to swapon-ing a plaintext fallback.
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
    sddm hyprland xdg-desktop-portal-hyprland \
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
log "Staging chroot script..."
cp "$REPO_ROOT/phase-2-arch-install/chroot.sh" /mnt/root/chroot.sh
chmod +x /mnt/root/chroot.sh

# Hand the pre-hashed passwords to the chroot via a root-owned mode-600
# file. chroot.sh reads + shreds it. cleanup_on_fail also rm -f's it so an
# abort mid-chroot doesn't leave hashes behind on the freshly-installed fs.
(umask 077 && printf '%s\n%s\n' "$ROOT_PW_HASH" "$TOM_PW_HASH" > /mnt/root/.pw)

# Hand the LUKS partition UUIDs to chroot.sh (no passphrase — that stays
# in-memory here). chroot.sh needs these for /etc/crypttab.initramfs +
# /etc/crypttab + kernel cmdline. Use UUID (LUKS header) for cryptroot +
# cryptvar so the mapping survives partition-table renumbering; PARTUUID
# for cryptswap because there's no LUKS header (random-key plain dm-crypt).
LUKS_ROOT_UUID=$(blkid -s UUID -o value "$SAMSUNG_ROOT")
LUKS_VAR_UUID=$(blkid -s UUID -o value "$NETAC_VAR")
SWAP_PARTUUID=$(blkid -s PARTUUID -o value "$NETAC_SWAP")
[[ -n "$LUKS_ROOT_UUID" && -n "$LUKS_VAR_UUID" && -n "$SWAP_PARTUUID" ]] \
    || die "Failed to resolve LUKS UUIDs (blkid returned empty)."
(umask 077 && cat > /mnt/root/.luks <<EOF
LUKS_ROOT_UUID=$LUKS_ROOT_UUID
LUKS_VAR_UUID=$LUKS_VAR_UUID
SWAP_PARTUUID=$SWAP_PARTUUID
EOF
)

arch-chroot /mnt /root/chroot.sh
rm -f /mnt/root/.pw /mnt/root/.luks

# Passphrase was only needed for luksFormat + luksAddKey; scrub from memory.
unset LUKS_PW

# ---------- 12. recovery partition (SKIPPED in clone variant) ----------
# The repo clone doesn't carry the Arch ISO (gitignored). Leaving
# NETAC_RECOVERY empty is safe — systemd-boot entry for recovery will
# just fail to boot until you populate it. To fill it later:
#   sudo dd if=/path/to/archlinux-x86_64.iso of=$NETAC_RECOVERY bs=4M conv=fsync
warn "Skipping recovery-partition ISO write — clone variant. Populate $NETAC_RECOVERY manually later."

# ---------- 13. post-install hook ----------
# Stage phase-3 script where the user can run it after first login.
mkdir -p /mnt/home/tom
cp "$REPO_ROOT/phase-3-arch-postinstall/postinstall.sh" /mnt/home/tom/postinstall.sh 2>/dev/null || warn "phase-3 script missing — you can copy it later."
# p10k.zsh sidecar — postinstall.sh's SCRIPT_DIR lookup expects it next to itself.
cp "$REPO_ROOT/phase-3-arch-postinstall/p10k.zsh" /mnt/home/tom/p10k.zsh 2>/dev/null || true
# Dotfiles (end-4/dots-hyprland) are cloned from GitHub by postinstall.sh at
# first boot — keeps the USB lean and the dots current. Network required.
arch-chroot /mnt chown -R tom:tom /home/tom

# ---------- 14. cleanup ----------
log "Syncing + unmounting..."
sync
umount -R /mnt
# Close LUKS mappers so a retry (or a manual `cryptsetup luksFormat` later)
# doesn't trip on "device still in use". No swap was mounted — cryptswap is
# a boot-time construct — so no swapoff needed here.
cryptsetup close cryptvar  || true
cryptsetup close cryptroot || true

cat <<EOF

Done. Remove the USB and reboot.

First boot asks for the LUKS passphrase (you set it at the top of this run).
Log in as 'tom', then:
    ./postinstall.sh           # installs yay, zgenom, illogical-impulse dots,
                               # catppuccin, chezmoi, fingerprint, TPM2 enroll
                               # for silent LUKS unlock, etc.
EOF
