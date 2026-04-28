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
    # even on abort.
    rm -f /mnt/root/.pw /mnt/root/.luks 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true
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
[[ -e /dev/mapper/cryptroot ]] && {
    log "Closing stale mapper /dev/mapper/cryptroot from a previous run..."
    cryptsetup close cryptroot 2>/dev/null || warn "  couldn't close cryptroot — continuing anyway"
}

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

# ---------- 1. locate disk by size ----------
# decisions.md §Q9: Samsung 512 GB nominal (~476 GiB actual). The Netac
# (if present) is intentionally left untouched — slated for replacement
# with a new SSD, and the design is now single-disk-on-Samsung so the
# new drive can be migrated to via a one-line dd of the LUKS partition.
SAMSUNG=""
while read -r dev size; do
    gib=$(( size / 1024 / 1024 / 1024 ))
    if (( gib >= 450 && gib <= 520 )); then SAMSUNG="/dev/$dev"; fi
done < <(lsblk -b -d -n -o NAME,SIZE -e 7,11)  # exclude loop + rom

[[ -n "$SAMSUNG" ]] || die "No 450-520 GiB disk detected (expected Samsung SSD 840 PRO 512GB ~ 476 GiB)."

log "Samsung (install target — full disk wipe): $SAMSUNG"

# ---------- 2. network ----------
# Embedded Wi-Fi profiles. Mirror these in chroot.sh WIFI_PROFILES and in
# autounattend.xml's FirstLogon Wi-Fi block. Format: "SSID:PSK"
WIFI_PROFILES=(
    "ATTgs5BwGZ:t8ueiz43ueaf"
    "rhombus:n3wPassword"
    "rhombus_legacy:n3wPassword"
    "Ganymede:n3wPassword"
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
# script — used to luksFormat the single root volume — then unset before
# exit. Never touches disk.
command -v openssl >/dev/null || die "openssl not found in live env — needed for password hashing + LUKS key generation."
log "Collecting passwords now (you won't be prompted again during install)."
log "After the two account passwords, a 48-char LUKS recovery key will be generated and displayed for you to photograph."
ROOT_PW_HASH=$(prompt_password "root")
TOM_PW_HASH=$(prompt_password "tom")
LUKS_PW=$(gen_and_show_luks_passphrase)

# ---------- 3. confirm ----------
cat <<EOF

About to:
  - WIPE $SAMSUNG entirely (GPT label, all existing partitions destroyed)
  - Lay out 2 partitions on it:
      - EFI System partition, 1 GiB FAT32 (mounted at /boot — UKIs land here)
      - LUKS2 + btrfs (rest, ~475 GiB) with subvolumes @, @home, @snapshots, @swap
  - Inside the btrfs, create a 16 GiB NoCOW swapfile (hibernate-ready)
  - pacstrap a full Arch system and configure per decisions.md

If you have a Netac SSD or other disks plugged in, they will be left UNTOUCHED.

EOF
confirm "Proceed?"

# ---------- 4. Samsung: full disk wipe + new GPT layout ----------
log "Wiping $SAMSUNG and creating fresh GPT layout..."
sgdisk --zap-all "$SAMSUNG"
sgdisk \
    --new=1:0:+1G  --typecode=1:ef00 --change-name=1:EFI       \
    --new=2:0:0    --typecode=2:8309 --change-name=2:ArchRoot  \
    "$SAMSUNG"
# typecode ef00 = EFI System; typecode 8309 = "Linux LUKS" (more specific
# than 8300 / Linux filesystem; helps tools like blkid + GPT-aware loaders
# identify the partition unambiguously).
partprobe "$SAMSUNG"
udevadm settle

# Resolve the partitions by PARTLABEL — robust against sda1 vs nvme0n1p1
# device-naming differences and against any future GPT table reshuffles.
SAMSUNG_EFI=$(lsblk -ln -o NAME,PARTLABEL "$SAMSUNG" | awk '$2 == "EFI"      {print $1; exit}')
SAMSUNG_ROOT=$(lsblk -ln -o NAME,PARTLABEL "$SAMSUNG" | awk '$2 == "ArchRoot" {print $1; exit}')
[[ -n "$SAMSUNG_EFI"  ]] || die "Could not find EFI partition after sgdisk — check lsblk output."
[[ -n "$SAMSUNG_ROOT" ]] || die "Could not find ArchRoot partition after sgdisk — check lsblk output."
SAMSUNG_EFI="/dev/$SAMSUNG_EFI"
SAMSUNG_ROOT="/dev/$SAMSUNG_ROOT"
log "EFI System partition: $SAMSUNG_EFI"
log "Linux root partition: $SAMSUNG_ROOT"

# ---------- 6. LUKS format + open ----------
# Single LUKS2 volume on the Samsung. The passphrase is the ONLY key at
# install time; §5b below enrolls TPM2 against a signed-PCR-11 policy so
# first boot is silent. Passphrase stays as the recovery fallback.
#
# luksFormat defaults: LUKS2 + argon2id KDF + aes-xts-plain64. --batch-mode
# suppresses the "THIS WILL OVERWRITE DATA" confirmation (we already got
# the user's `yes` in §3). --key-file=- reads the passphrase from stdin so
# it never appears in `ps`.
log "Encrypting Samsung root ($SAMSUNG_ROOT) with LUKS2..."
printf '%s' "$LUKS_PW" | cryptsetup luksFormat --type luks2 --batch-mode \
    --label ArchRootLUKS --key-file=- "$SAMSUNG_ROOT"
printf '%s' "$LUKS_PW" | cryptsetup open --key-file=- "$SAMSUNG_ROOT" cryptroot

# ---------- 5a. PCR signing keypair (UKI + signed-policy seal) ----------
# Generate an RSA-2048 keypair used to sign UKI PCR predictions. ukify
# (called by mkinitcpio in chroot.sh) embeds the signed predictions in the
# UKI's `.pcrsig` PE section; systemd-cryptsetup at boot presents that
# signature to the TPM, the TPM verifies it with the matching public key,
# unseals the LUKS master key. See docs/tpm-luks-bitlocker-parity.md.
#
# Key persistence: lives at /etc/systemd/tpm2-pcr-{private,public}.pem on
# the LUKS root (i.e. /mnt during install). Chicken-and-egg-safe — the TPM
# unseals LUKS without needing the private key; the private key only
# matters at UKI-build time, which only happens on a booted system where
# the TPM has already unsealed the disk. So an attacker who can read the
# private key already had root.
log "Generating PCR signing keypair (RSA-2048) at /etc/systemd/tpm2-pcr-{private,public}.pem..."
install -d -m 755 /mnt/etc/systemd
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out /mnt/etc/systemd/tpm2-pcr-private.pem 2>/dev/null
openssl rsa -in /mnt/etc/systemd/tpm2-pcr-private.pem \
    -pubout -out /mnt/etc/systemd/tpm2-pcr-public.pem 2>/dev/null
chmod 600 /mnt/etc/systemd/tpm2-pcr-private.pem
chmod 644 /mnt/etc/systemd/tpm2-pcr-public.pem
chown root:root /mnt/etc/systemd/tpm2-pcr-{private,public}.pem

# ---------- 5b. TPM2 autounlock at install time (BitLocker-style) ----------
# Enroll TPM2 NOW, while $LUKS_PW is still in memory, so the very first
# boot of the installed system is silent — no passphrase prompt at all.
# The 48-digit recovery key becomes pure escrow: typed only if PCR values
# drift (BIOS / secure-boot changes) or for disaster recovery.
#
# Policy: signed PCR 11 (UKI self-measurement + phase markers).
#   --tpm2-public-key + --tpm2-public-key-pcrs=11 seals to a POLICY, not a
#   value: "unseal if you see a UKI signed by our keypair." That policy
#   matches across boots even though PCR 11 itself changes — what matters
#   is that the UKI's embedded signature covers the current PCR 11 value.
#   Earlier --tpm2-pcrs=0+7 attempts failed because PCR 0+7 measured by the
#   live ISO did NOT match PCR 0+7 measured by the installed system on
#   first boot (firmware code paths differ when the bootloader differs).
#   Signed-policy is invariant to that drift by design.
#
# PCR 7 binding gets ADDED in postinstall §7.5 as "stage 2" — once the
# installed system has booted and PCR 7 is stable + measurable, postinstall
# re-seals adding --tpm2-pcrs=7 alongside the signed PCR 11. That makes
# Secure Boot toggle a meaningful event (PCR 7 changes → recovery key
# prompt → user reseals), matching BitLocker's behavior.
#
# Failure paths fall through to passphrase boot (no TPM, broken TPM, missing
# ukify/openssl, old systemd-cryptenroll): postinstall §7.5 will retry the
# enrollment from the running system.
TPM_ENROLLED_AT_INSTALL=0
if [[ -c /dev/tpm0 || -c /dev/tpmrm0 ]] && command -v systemd-cryptenroll >/dev/null; then
    log "Enrolling TPM2 (signed PCR 11 policy) on cryptroot so first boot is silent..."
    _kf=$(mktemp /run/luks-pw-XXXXXX)
    chmod 600 "$_kf"
    printf '%s' "$LUKS_PW" > "$_kf"
    if systemd-cryptenroll --unlock-key-file="$_kf" \
        --tpm2-device=auto \
        --tpm2-public-key=/mnt/etc/systemd/tpm2-pcr-public.pem \
        --tpm2-public-key-pcrs=11 \
        "$SAMSUNG_ROOT"; then
        log "  cryptroot: TPM2 enrolled (signed PCR 11)."
        TPM_ENROLLED_AT_INSTALL=1
    else
        warn "  cryptroot: TPM2 enroll failed — postinstall §7.5 will retry."
    fi
    shred -u "$_kf" 2>/dev/null || rm -f "$_kf"
elif [[ ! -c /dev/tpm0 && ! -c /dev/tpmrm0 ]]; then
    warn "No TPM2 device (/dev/tpm{,rm}0 missing). First boot will prompt for the LUKS passphrase; postinstall §7.5 will retry."
else
    warn "systemd-cryptenroll missing in live ISO. First boot will prompt for the LUKS passphrase; postinstall §7.5 will retry."
fi

log "Creating btrfs on /dev/mapper/cryptroot + EFI on $SAMSUNG_EFI..."
mkfs.btrfs -f -L ArchRoot /dev/mapper/cryptroot
mkfs.fat   -F32 -n EFI    "$SAMSUNG_EFI"

# ---------- 7. btrfs subvolumes ----------
# @swap is a dedicated subvolume so root snapshots don't drag the swapfile
# into them (which would defeat snapshot rollback on a hibernate-resume).
log "Creating btrfs subvolumes (@, @home, @snapshots, @swap)..."
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@swap
umount /mnt

# ---------- 8. mount ----------
log "Mounting filesystems..."
MOPTS="noatime,compress=zstd:3,space_cache=v2,ssd"
mount -o "$MOPTS,subvol=@"          /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,boot,swap}
mount -o "$MOPTS,subvol=@home"      /dev/mapper/cryptroot /mnt/home
mount -o "$MOPTS,subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots
# @swap mounts WITHOUT compression (mandatory for a btrfs swapfile —
# kernel rejects swapon on a compressed file).
mount -o noatime,subvol=@swap       /dev/mapper/cryptroot /mnt/swap
mount "$SAMSUNG_EFI" /mnt/boot

# ---------- 8.5 swapfile (NoCOW, hibernate-ready) ----------
# btrfs swapfile requirements (kernel 5.0+, well-established):
#   - subvolume must be NoCOW (chattr +C, applied to empty file BEFORE
#     any data lands)
#   - file must be NOT sparse — use fallocate or dd, not truncate
#   - file must NOT be on a snapshot (the @swap dedicated subvol guards
#     against this)
#   - mount option `compress` must NOT cover the swapfile
#
# Size = 16 GiB (matches RAM, hibernate-image-fits requirement).
log "Creating 16 GiB swapfile at /mnt/swap/swapfile..."
truncate -s 0 /mnt/swap/swapfile
chattr +C /mnt/swap/swapfile
fallocate -l 16G /mnt/swap/swapfile
chmod 600 /mnt/swap/swapfile
mkswap /mnt/swap/swapfile

# Capture the resume_offset for the kernel cmdline (chroot.sh will write
# it into /etc/kernel/cmdline). On btrfs, the offset is reported by
# `btrfs inspect-internal map-swapfile -r` (modern, exact) — stash it now
# while /mnt/swap is mounted.
SWAP_RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile)
[[ -n "$SWAP_RESUME_OFFSET" ]] || die "Couldn't get resume_offset for swapfile."
log "swapfile resume_offset: $SWAP_RESUME_OFFSET"

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
# can install greetd system-files from phase-3-arch-postinstall/system-files/.
# (Dotfiles live in a separate repo — rhombu5/dots — and are fetched by
# postinstall via `chezmoi init --apply`. Nothing dotfile-related is staged
# at install time.)
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
TPM_ENROLLED_AT_INSTALL=$TPM_ENROLLED_AT_INSTALL
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
# Stage phase-3 script + setup-azure-ddns where the user can run them
# after first login. (The full repo is already at /mnt/root/arch-setup/
# from the staging step in §11.)
install -d -m 755 /mnt/home/tom
cp "$SOURCE_DIR/phase-3-arch-postinstall/postinstall.sh"     /mnt/home/tom/postinstall.sh 2>/dev/null \
    || warn "phase-3 script missing — copy it later from /root/arch-setup."
cp "$SOURCE_DIR/phase-3-arch-postinstall/setup-azure-ddns.sh" /mnt/home/tom/setup-azure-ddns.sh 2>/dev/null || true
chmod +x /mnt/home/tom/postinstall.sh /mnt/home/tom/setup-azure-ddns.sh 2>/dev/null || true
# Dotfiles (Claude-authored, chezmoi-managed) live in the rhombu5/dots
# repo and are fetched + applied by postinstall via `chezmoi init --apply`.
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

First boot:
  - SILENT (no LUKS prompt) if TPM2 enrolled successfully — see the
    "Enrolling TPM2 (signed PCR 11 policy)" lines above.
  - Prompts for the 48-digit recovery key if TPM enrollment failed at
    install time. Postinstall §7.5 retries from the running system.

Log in as 'tom', then:
    ./postinstall.sh           # installs yay, zgenom, chezmoi (clones
                               # rhombu5/dots and applies the bare-Hyprland
                               # configs + matugen pipeline),
                               # fingerprint, layers PCR 7 onto the LUKS
                               # TPM seal (stage 2), ufw, metis-ddns,
                               # printer drivers, etc.
EOF
