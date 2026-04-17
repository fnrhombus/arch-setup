#!/usr/bin/env bash
# phase-2-arch-install/install.sh
#
# Run from the Arch live environment (boot the ISO from Ventoy, pick
# "archlinux-2026.04.01-x86_64.iso"). This script reads every decision
# from decisions.md §Q9 and lays down Arch on:
#   - Samsung 512 GB SSD : btrfs in the trailing ~316 GB unallocated space
#                          (EFI/MSR/Windows partitions are left untouched)
#   - Netac 128 GB SSD   : recovery ISO (1.5 GB) + swap (16 GB) + ext4 (~110 GB)
#
# All disk operations are size-gated: the script aborts if the expected
# disks are absent or if anything looks off. Never silently clobbers.
#
# Usage:
#   iwctl                                  # connect wifi (station wlan0 connect <ssid>)
#   mount /dev/disk/by-label/Ventoy /mnt/ventoy   # or wherever Ventoy mounted
#   bash /mnt/ventoy/phase-2-arch-install/install.sh

set -euo pipefail

# ---------- helpers ----------
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
    local prompt="${1:-Continue?}"
    read -rp "$prompt [yes/NO]: " reply
    [[ "$reply" == "yes" ]] || die "Aborted by user."
}

# ---------- 0. sanity ----------
[[ $EUID -eq 0 ]]                       || die "Run as root."
[[ -d /sys/firmware/efi/efivars ]]      || die "Not booted in UEFI mode."
command -v pacstrap >/dev/null          || die "pacstrap missing — not in Arch live env?"

# ---------- 1. locate disks by size ----------
# decisions.md §Q9: Samsung 512 GB (500-600 GB window), Netac 128 GB (100-150 GB window)
SAMSUNG=""
NETAC=""
while read -r dev size; do
    gb=$(( size / 1024 / 1024 / 1024 ))
    if (( gb >= 500 && gb <= 600 )); then SAMSUNG="/dev/$dev"
    elif (( gb >= 100 && gb <= 150 )); then NETAC="/dev/$dev"
    fi
done < <(lsblk -b -d -n -o NAME,SIZE -e 7,11)  # exclude loop + rom

[[ -n "$SAMSUNG" ]] || die "No 500-600 GB disk detected (expected Samsung SSD 840 PRO 512GB)."
[[ -n "$NETAC"   ]] || die "No 100-150 GB disk detected (expected Netac 128GB)."

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

# ---------- 3. confirm ----------
cat <<EOF

About to:
  - Leave Samsung partitions 1, 2, 3 (EFI, MSR, Windows) UNTOUCHED
  - Create one new btrfs partition in the trailing unallocated space of $SAMSUNG
  - WIPE $NETAC entirely (GPT label, 3 new partitions)
  - pacstrap a full Arch system and configure per decisions.md

EOF
confirm "Proceed?"

# ---------- 4. Samsung: add btrfs partition in trailing free space ----------
log "Adding btrfs partition in trailing free space on $SAMSUNG..."
# `sgdisk --largest-new` creates the largest possible new partition from free space.
sgdisk --largest-new=0 --typecode=0:8300 --change-name=0:ArchRoot "$SAMSUNG"
partprobe "$SAMSUNG"; sleep 2

# Find the newly-created partition (highest partition number on Samsung).
SAMSUNG_ROOT=$(lsblk -n -o NAME "$SAMSUNG" | tail -n +2 | tail -1)
SAMSUNG_ROOT="/dev/$SAMSUNG_ROOT"
log "New Linux root partition: $SAMSUNG_ROOT"

# Samsung EFI partition (first partition, created by Windows install).
SAMSUNG_EFI=$(lsblk -n -o NAME,PARTTYPE "$SAMSUNG" | awk '$2 ~ /c12a7328-f81f-11d2-ba4b-00a0c93ec93b/ {print $1; exit}')
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
partprobe "$NETAC"; sleep 2

NETAC_RECOVERY="${NETAC}1"; [[ -b "$NETAC_RECOVERY" ]] || NETAC_RECOVERY="${NETAC}p1"
NETAC_SWAP="${NETAC}2";     [[ -b "$NETAC_SWAP"     ]] || NETAC_SWAP="${NETAC}p2"
NETAC_VAR="${NETAC}3";      [[ -b "$NETAC_VAR"      ]] || NETAC_VAR="${NETAC}p3"

# ---------- 6. filesystems ----------
log "Creating filesystems..."
mkfs.btrfs -f -L ArchRoot "$SAMSUNG_ROOT"
mkfs.ext4  -F -L ArchVar  "$NETAC_VAR"
mkswap -L ArchSwap "$NETAC_SWAP"
# NETAC_RECOVERY stays raw — we dd the Arch ISO onto it later.

# ---------- 7. btrfs subvolumes ----------
log "Creating btrfs subvolumes..."
mount "$SAMSUNG_ROOT" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt

# ---------- 8. mount ----------
log "Mounting filesystems..."
MOPTS="noatime,compress=zstd:3,space_cache=v2,ssd"
mount -o "$MOPTS,subvol=@"          "$SAMSUNG_ROOT" /mnt
mkdir -p /mnt/{home,.snapshots,boot,var/log,var/cache}
mount -o "$MOPTS,subvol=@home"      "$SAMSUNG_ROOT" /mnt/home
mount -o "$MOPTS,subvol=@snapshots" "$SAMSUNG_ROOT" /mnt/.snapshots
mount "$SAMSUNG_EFI" /mnt/boot
# Netac ext4 at /var: we mount the single ext4 volume at /var and bind-mount
# /var/log and /var/cache from it. Simpler: mount it at an intermediate path
# and bind the two subdirs. But cleanest: put /var itself on Netac. However,
# decisions.md §Q9 says "/var/log + /var/cache on Netac" (not all of /var),
# so use two subdirs + bind mounts so other /var paths stay on btrfs.
mkdir -p /mnt/mnt/netac-var
mount "$NETAC_VAR" /mnt/mnt/netac-var
mkdir -p /mnt/mnt/netac-var/{log,cache}
mount --bind /mnt/mnt/netac-var/log   /mnt/var/log
mount --bind /mnt/mnt/netac-var/cache /mnt/var/cache
swapon "$NETAC_SWAP"

# ---------- 9. pacstrap ----------
log "Running pacstrap (this pulls ~1-2 GB over the network)..."
pacstrap -K /mnt \
    base base-devel linux linux-firmware linux-headers intel-ucode \
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
VENTOY_MNT=$(findmnt -n -o TARGET -S LABEL=Ventoy 2>/dev/null || true)
[[ -n "$VENTOY_MNT" ]] || die "Ventoy USB not mounted — where is chroot.sh?"
cp "$VENTOY_MNT/phase-2-arch-install/chroot.sh" /mnt/root/chroot.sh
chmod +x /mnt/root/chroot.sh
arch-chroot /mnt /root/chroot.sh

# ---------- 12. recovery partition ----------
log "Writing Arch ISO to recovery partition $NETAC_RECOVERY..."
ARCH_ISO=$(ls "$VENTOY_MNT"/archlinux-*.iso | head -1)
[[ -f "$ARCH_ISO" ]] || die "No Arch ISO found on Ventoy."
dd if="$ARCH_ISO" of="$NETAC_RECOVERY" bs=4M status=progress conv=fsync

# ---------- 13. post-install hook ----------
# Stage phase-3 script where the user can run it after first login.
mkdir -p /mnt/home/tom
cp "$VENTOY_MNT/phase-3-arch-postinstall/postinstall.sh" /mnt/home/tom/postinstall.sh 2>/dev/null || warn "phase-3 script missing — you can copy it later."
cp -r "$VENTOY_MNT/phase-3-arch-postinstall/dotfiles" /mnt/home/tom/ 2>/dev/null || true
arch-chroot /mnt chown -R tom:tom /home/tom

# ---------- 14. cleanup ----------
log "Syncing + unmounting..."
sync
swapoff "$NETAC_SWAP" || true
umount -R /mnt

cat <<EOF

Done. Remove the USB and reboot.

After first login as 'tom':
    ./postinstall.sh           # installs yay, zgenom, illogical-impulse dots,
                               # catppuccin, chezmoi, fingerprint, etc.
EOF
