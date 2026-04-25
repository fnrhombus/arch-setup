#!/usr/bin/env bash
# phase-2-arch-install/chroot.sh
#
# Runs inside `arch-chroot /mnt` from install.sh. Sets up:
#   - timezone, locale, hostname (= metis)
#   - user tom with wheel/sudo
#   - limine bootloader (shares the EFI Windows created at /boot, written
#     to the fallback path \EFI\BOOT\BOOTX64.EFI so Windows NVRAM resets
#     don't kill us)
#   - persistent LUKS2 cryptswap (hibernate-ready; resume= in cmdline)
#   - NVIDIA blacklist (MX250 Optimus — Intel iGPU only, decisions.md §Q5)
#   - NetworkManager + greetd + bluetooth + fprintd enabled
#   - greetd PAM stack from system-files/pam.d/greetd (gnome-keyring + fprintd)
#   - yay build is done in phase-3 (needs non-root + network)

set -euo pipefail
log()  { printf '\033[1;32m[chroot]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[chroot ✗]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- password hashes from install.sh ----------
# install.sh prompted the user for root+tom passwords up-front and wrote
# SHA-512 crypt hashes to /root/.pw (line 1 = root, line 2 = tom). Apply
# via `chpasswd -e` (-e = encrypted, consumes pre-hashed input). Shred
# the file on exit so no hash lingers on the installed filesystem.
[[ -s /root/.pw ]] || die "/root/.pw missing — install.sh should have pre-hashed both passwords."
{ read -r ROOT_PW_HASH; read -r TOM_PW_HASH; } < /root/.pw
[[ -n "$ROOT_PW_HASH" && -n "$TOM_PW_HASH" ]] || die "/root/.pw is missing one or both hashes."
trap 'shred -u /root/.pw /root/.luks 2>/dev/null || rm -f /root/.pw /root/.luks' EXIT

# ---------- LUKS UUIDs + Samsung disk path from install.sh ----------
# install.sh wrote /root/.luks with LUKS_{ROOT,VAR,SWAP}_UUID and SAMSUNG_DISK
# so this script can write crypttab + register the limine NVRAM entry on the
# correct disk without re-querying blkid (partition devices aren't directly
# visible from inside the chroot anyway).
[[ -s /root/.luks ]] || die "/root/.luks missing — install.sh should have written LUKS UUIDs + SAMSUNG_DISK."
# shellcheck disable=SC1091
. /root/.luks
[[ -n "${LUKS_ROOT_UUID:-}" && -n "${LUKS_VAR_UUID:-}" && -n "${LUKS_SWAP_UUID:-}" ]] \
    || die "/root/.luks is missing one or more UUIDs (LUKS_ROOT_UUID / LUKS_VAR_UUID / LUKS_SWAP_UUID)."
[[ -n "${SAMSUNG_DISK:-}" && -b "$SAMSUNG_DISK" ]] \
    || die "/root/.luks is missing SAMSUNG_DISK or it isn't a block device."

# ---------- timezone + clock ----------
log "Timezone → America/New_York (adjust in /etc/localtime if wrong)..."
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
# Dual-boot clock handling:
#   - Windows keeps the RTC in LOCAL time by default.
#   - Linux (Arch default) reads RTC as UTC.
#   - If Arch writes its UTC system-time back to RTC (`hwclock --systohc`),
#     Windows's next boot reads that UTC value, applies the timezone offset,
#     and the Windows clock jumps forward by 5 hours.
# Fix: tell Arch the RTC is local time by setting /etc/adjtime's mode line
# to LOCAL. NTP will still keep the system clock on UTC internally; only the
# RTC interpretation changes, so Windows stays correct and Arch stays correct.
# Do NOT call `hwclock --systohc` — it would overwrite the RTC with the chroot
# UTC system-time (which is what breaks Windows).
# (An alternative is to teach Windows about UTC via the RealTimeIsUniversal
# registry key — see autounattend-oobe-patch.md if you prefer that route.)
cat > /etc/adjtime <<'EOF'
0.0 0 0.0
0
LOCAL
EOF

# ---------- locale ----------
log "Locale → en_US.UTF-8..."
sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo 'KEYMAP=us'        > /etc/vconsole.conf

# ---------- hostname ----------
HOSTNAME="metis"
log "Hostname → $HOSTNAME..."
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# ---------- root password ----------
log "Applying root password (pre-hashed by install.sh)..."
echo "root:$ROOT_PW_HASH" | chpasswd -e

# ---------- user tom ----------
log "Creating user tom..."
useradd -m -G wheel,video,audio,input,storage -s /bin/zsh tom
log "Applying tom password (pre-hashed by install.sh)..."
echo "tom:$TOM_PW_HASH" | chpasswd -e
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# ---------- NVIDIA blacklist (decisions.md §Q5) ----------
log "Blacklisting NVIDIA modules (MX250 → Intel UHD 620 only)..."
cat > /etc/modprobe.d/blacklist-nvidia.conf <<EOF
blacklist nouveau
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
EOF

# ---------- lid-close policy (decisions.md Requirements) ----------
# HandleLidSwitch=hibernate is dead code today (battery is dead) but live
# the moment a battery returns — no reconfiguration needed. AC remains
# clamshell-friendly via External=ignore. See docs/decisions.md "Battery"
# bullet for full reasoning.
log "Lid-close: ignore on AC, hibernate on battery..."
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/10-lid.conf <<EOF
[Login]
HandleLidSwitch=hibernate
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF

# ---------- crypttab (FDE per decisions.md §Q11) ----------
# Two crypttab files:
#   /etc/crypttab.initramfs  — baked into initramfs by mkinitcpio's sd-encrypt
#                               hook. Opens cryptroot before the root fs is
#                               mounted. Entry uses `none` so systemd prompts
#                               the user for the passphrase at boot (phase-3
#                               systemd-cryptenroll replaces this prompt with
#                               silent TPM2 unlock; the passphrase stays as
#                               a key slot fallback).
#   /etc/crypttab            — read post-init by systemd-cryptsetup@.service.
#                               Opens cryptvar from the on-root keyfile, then
#                               cryptswap with a fresh /dev/urandom key per
#                               boot.
log "Writing /etc/crypttab.initramfs (cryptroot + cryptswap) + /etc/crypttab (cryptvar)..."
# Both cryptroot and cryptswap go in crypttab.initramfs. cryptswap has
# to be opened before pivot so the kernel's resume= codepath (which
# runs in initramfs) can read the hibernate image.
#
# tpm2-device=auto: present iff install.sh successfully enrolled TPM2
# at format time (BitLocker-style: the very first boot is silent). If
# enrollment failed or no TPM was present, omit the option — leaving
# it in would block boot waiting for a non-existent TPM2 slot
# (systemd/systemd#39049, #36293). Phase-3 postinstall §7.5 retries
# enrollment in that case and rewrites these lines on success.
#
# cryptvar opens post-pivot via a keyfile on cryptroot (§7a).
if [[ "${TPM_ENROLLED_AT_INSTALL:-0}" == "1" ]]; then
    _crypt_opts="luks,discard,tpm2-device=auto"
    log "  TPM2 already enrolled at install — adding tpm2-device=auto so first boot unlocks silently."
else
    _crypt_opts="luks,discard"
    log "  No TPM2 enrollment yet — first boot will prompt for the passphrase; postinstall §7.5 retries."
fi
cat > /etc/crypttab.initramfs <<EOF
cryptroot UUID=$LUKS_ROOT_UUID none $_crypt_opts
cryptswap UUID=$LUKS_SWAP_UUID none $_crypt_opts
EOF
cat > /etc/crypttab <<EOF
cryptvar  UUID=$LUKS_VAR_UUID  /etc/cryptsetup-keys.d/cryptvar.key  luks,discard
EOF
chmod 600 /etc/crypttab /etc/crypttab.initramfs

# ---------- fstab fixups for encrypted devices ----------
# genfstab (run in install.sh) emitted entries keyed off the currently-mounted
# /dev/mapper/cryptroot + /dev/mapper/cryptvar, which is correct — those
# mapper names are deterministic across boots. Swap, however, is never mounted
# during install (see install.sh §6), so no swap line exists. Add it now,
# pointing at /dev/mapper/cryptswap so the random-key pipeline lines up.
log "Appending swap line to /etc/fstab (pointing at /dev/mapper/cryptswap)..."
grep -q '^/dev/mapper/cryptswap' /etc/fstab || \
    printf '/dev/mapper/cryptswap\tnone\tswap\tdefaults\t0 0\n' >> /etc/fstab

# ---------- mkinitcpio ----------
log "Regenerating initramfs..."
# Explicit btrfs in MODULES= is belt-and-suspenders: `filesystems` hook usually
# pulls it via autodetect, but if autodetect misses it you get an unbootable
# kernel panic ("can't find root fs"). Cheap to force.
# HOOKS ordering: sd-encrypt must sit between `block` (loads block-device
# modules) and `filesystems` (mounts root). It reads /etc/crypttab.initramfs
# at boot and opens cryptroot before `filesystems` tries to mount it.
sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# ---------- limine bootloader (replaces systemd-boot) ----------
# limine chosen for: snapshot-rollback boot menu via limine-snapper-sync
# (matches our btrfs+snapper setup), bootable-ISO-from-disk support
# (Netac recovery partition becomes reachable), modern actively-developed
# bootloader. Decision: docs/decisions.md §A + reinstall-planning.md §3.
#
# Phase 2 installs limine itself; phase-3 postinstall installs the AUR
# limine-snapper-sync package + enables its hook for auto-regenerating
# entries from new snapper snapshots.
log "Installing limine bootloader..."
pacman -S --noconfirm --needed limine

# UEFI install: copy the limine EFI binary to the ESP fallback path
# (\EFI\BOOT\BOOTX64.EFI). Firmware boots this without needing an NVRAM
# entry — crucial because Windows periodically wipes NVRAM entries for
# non-Windows loaders (per autounattend-oobe-patch.md).
install -d /boot/EFI/BOOT
install -m 644 /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI

# Also register a NVRAM entry so it shows in the boot menu by name.
# `|| true` because efibootmgr can fail in a chroot if /sys/firmware/efi
# isn't mounted — install.sh handles the EFI vars mount.
if [[ -d /sys/firmware/efi/efivars ]]; then
    efibootmgr --quiet --create-only \
        --disk "$SAMSUNG_DISK" --part 1 \
        --label "Limine Boot Manager" \
        --loader '\EFI\BOOT\BOOTX64.EFI' 2>/dev/null \
        || log "  efibootmgr NVRAM entry skipped (may already exist or efivars unavailable)"
fi

# Limine config — written to /boot/limine.conf (limine searches the ESP
# root for this filename). Three entries: linux (default), linux-lts
# (fallback for kernel regressions), linux fallback initramfs.
#
# SYNTAX-CHECK: limine 8.x config format. If syntax has drifted by the
# time this runs, see https://github.com/limine-bootloader/limine/blob/trunk/CONFIG.md
log "Writing /boot/limine.conf..."
cat > /boot/limine.conf <<EOF
timeout: 3
default_entry: 1

/Arch Linux
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    module_path: boot():/intel-ucode.img
    module_path: boot():/initramfs-linux.img
    cmdline: root=/dev/mapper/cryptroot rootflags=subvol=@ resume=/dev/mapper/cryptswap rw quiet

/Arch Linux (LTS)
    protocol: linux
    kernel_path: boot():/vmlinuz-linux-lts
    module_path: boot():/intel-ucode.img
    module_path: boot():/initramfs-linux-lts.img
    cmdline: root=/dev/mapper/cryptroot rootflags=subvol=@ resume=/dev/mapper/cryptswap rw quiet

/Arch Linux (Fallback)
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    module_path: boot():/intel-ucode.img
    module_path: boot():/initramfs-linux-fallback.img
    cmdline: root=/dev/mapper/cryptroot rootflags=subvol=@ resume=/dev/mapper/cryptswap rw

/Windows Boot Manager
    protocol: efi_chainload
    image_path: boot():/EFI/Microsoft/Boot/bootmgfw.efi
EOF

# Pacman hook: re-deploy limine BIOS/UEFI binaries when the limine package
# updates. Without this, a limine package upgrade leaves /boot/EFI/BOOT/
# pointed at a stale copy.
#
# Secure Boot ready: the helper script also re-signs the deployed binary if
# sbctl is set up + SB is enrolled (no-op otherwise). Without this, a limine
# upgrade after enabling SB would brick the next boot — firmware refuses to
# load an unsigned binary even at the fallback path.
install -d /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/95-limine-redeploy.hook <<'EOF'
[Trigger]
Operation = Upgrade
Type = Package
Target = limine

[Action]
Description = Re-deploying limine UEFI binary to ESP after upgrade...
When = PostTransaction
Exec = /usr/local/sbin/limine-redeploy
EOF

cat > /usr/local/sbin/limine-redeploy <<'BASH'
#!/usr/bin/env bash
# Triggered by /etc/pacman.d/hooks/95-limine-redeploy.hook after a `limine`
# package upgrade. Copies the fresh BOOTX64.EFI to the ESP fallback path and,
# if Secure Boot is enrolled via sbctl, re-signs the deployed binary so the
# next boot still passes firmware verification.
set -euo pipefail

SRC=/usr/share/limine/BOOTX64.EFI
DST=/boot/EFI/BOOT/BOOTX64.EFI

[[ -f "$SRC" ]] || { echo "limine-redeploy: $SRC missing"; exit 1; }

install -m 644 "$SRC" "$DST"
echo "limine-redeploy: copied $SRC → $DST"

# Secure Boot resign step (no-op when sbctl isn't set up). sbctl status exits 0
# whether SB is on or off; we look for the explicit "Secure Boot: ✓ Enabled"
# line. `sbctl sign -s <file>` is idempotent — safe on re-runs.
if command -v sbctl >/dev/null 2>&1; then
    if sbctl status 2>/dev/null | grep -qE 'Secure Boot:.*Enabled'; then
        echo "limine-redeploy: Secure Boot enrolled — signing $DST"
        sbctl sign -s "$DST" || echo "limine-redeploy: sbctl sign failed (non-fatal)"
        # Also sign the source so future redeploys start from a signed copy
        # — sbctl's own pacman hook keeps tracked files signed across upgrades,
        # but it only knows about files it's been told about with -s.
        sbctl sign -s "$SRC" 2>/dev/null || true
    fi
fi
BASH
chmod 755 /usr/local/sbin/limine-redeploy

# ---------- Pacman hook: TPM2 PCR re-enrolment after kernel/UKI/limine upgrades ----------
# Every upgrade to linux / linux-lts / mkinitcpio / limine changes PCR 4
# (bootloader/kernel measurement). LUKS volumes sealed against a frozen
# PCR state will refuse to unlock at next boot, falling back to passphrase.
# This hook re-runs systemd-cryptenroll on every TPM2-enrolled LUKS device
# after such an upgrade, picking up the fresh PCR values.
#
# Auto-discovers devices by scanning /etc/crypttab for entries with
# tpm2-device=auto — works even after we add cryptswap to the TPM-sealed
# set in the hibernate refactor.
log "Installing pacman post-upgrade TPM2 reseal hook..."
cat > /etc/pacman.d/hooks/95-tpm2-reseal.hook <<'EOF'
[Trigger]
Operation = Upgrade
Type = Package
Target = linux
Target = linux-lts
Target = mkinitcpio
Target = limine

[Action]
Description = Re-enrolling TPM2 PCR slots on TPM-sealed LUKS volumes...
When = PostTransaction
Exec = /usr/local/sbin/tpm2-reseal-luks
EOF

install -d -m 755 /usr/local/sbin
cat > /usr/local/sbin/tpm2-reseal-luks <<'BASH'
#!/usr/bin/env bash
# Re-enrol every TPM2-sealed LUKS device against the current PCR state.
# Triggered by /etc/pacman.d/hooks/95-tpm2-reseal.hook after kernel/UKI/
# limine upgrades that shift PCR 4.
set -euo pipefail
[[ -f /etc/crypttab ]] || exit 0

# Match crypttab entries whose options field contains tpm2-device=auto.
# Field 2 is the source UUID=... or PARTUUID=... — feed that to
# /dev/disk/by-uuid/$ID resolution, then cryptenroll.
while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    # Tab-or-space separated: name source key options
    set -- $line
    src="${2:-}"
    opts="${4:-}"
    [[ "$opts" == *tpm2-device=auto* ]] || continue
    case "$src" in
        UUID=*)     dev="/dev/disk/by-uuid/${src#UUID=}" ;;
        PARTUUID=*) dev="/dev/disk/by-partuuid/${src#PARTUUID=}" ;;
        /dev/*)     dev="$src" ;;
        *)          echo "tpm2-reseal: unknown source format: $src" >&2; continue ;;
    esac
    [[ -b "$dev" ]] || { echo "tpm2-reseal: $dev not present (yet?); skipping" >&2; continue; }
    echo "tpm2-reseal: re-enrolling TPM2 slot on $dev..."
    systemd-cryptenroll --wipe-slot=tpm2 "$dev" >/dev/null 2>&1 || true
    systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 "$dev"
done < /etc/crypttab.initramfs /etc/crypttab 2>/dev/null

exit 0
BASH
chmod 755 /usr/local/sbin/tpm2-reseal-luks

# ---------- TPM2 stack (for pinpam in phase-3) ----------
# Sync the mirror DB first. pacstrap populated /var/lib/pacman/sync from the
# live ISO's snapshot, which can be days old; a stale DB makes `pacman -S`
# error with "target not found" for packages that were just rebuilt. Cheap.
log "Installing TPM2 userspace..."
pacman -Sy --noconfirm
pacman -S --noconfirm --needed tpm2-tss tpm2-tools libsecret gnome-keyring

# ---------- TPM2 PCR bank: ensure SHA-256 active before any cryptenroll ----------
# Intel PTT firmware on Whiskey Lake (this Dell) ships with only the
# pcr-sha1 bank allocated. systemd-cryptenroll silently falls back to SHA-1
# when SHA-256 isn't available. We allocate both banks here so all sealings
# (root in phase-3, var in phase-3, swap in phase-3 if hibernate is wired,
# pinpam) land in SHA-256 — trending standard, future-proof.
#
# Reallocation is a TPM-firmware-level reset: it WIPES all currently-sealed
# objects. Doing this BEFORE any cryptenroll means there's nothing to wipe.
# Failure mode: some Intel PTT firmwares only allow one bank active at a
# time. If sha256:all+sha1:all is rejected, the script falls back to
# sha256-only (drops sha1 entirely) which is still correct.
log "Allocating TPM2 PCR banks (sha256 + sha1, fallback sha256-only)..."
if command -v tpm2_pcrallocate >/dev/null 2>&1; then
    if ! tpm2_pcrallocate sha256:all+sha1:all 2>/dev/null; then
        log "  sha256+sha1 rejected; trying sha256-only..."
        tpm2_pcrallocate sha256:all 2>/dev/null \
            || log "  WARN: pcrallocate failed entirely; seals will land in whatever bank is active (probably sha1)."
    fi
    # Verify what's active so first-boot logs show ground truth.
    tpm2_getcap pcrs 2>/dev/null | grep -iE 'sha[0-9]+:' | head -4 || true
fi

# ---------- greetd + ReGreet system-files install ----------
# greetd replaced SDDM (decisions.md §D). Source files live alongside
# postinstall in phase-3/system-files/ and are installed here at
# chroot-time so first boot comes up directly into greetd.
log "Installing greetd + ReGreet config + PAM stack..."
# `cage` is a minimal single-app Wayland compositor. ReGreet is a GTK
# Wayland app with no compositor of its own — without cage underneath
# it, GTK has no surface to draw into and fails with "Failed to
# initialize GTK", greetd restart-loops, login screen never appears.
# Standard greetd+ReGreet pairing per the ReGreet README.
pacman -S --noconfirm --needed greetd greetd-regreet cage
GREETD_SRC="/root/arch-setup/phase-3-arch-postinstall/system-files"
if [[ -d "$GREETD_SRC" ]]; then
    install -d -m 755 /etc/greetd
    install -m 644 "$GREETD_SRC/greetd/config.toml"   /etc/greetd/config.toml
    install -m 644 "$GREETD_SRC/greetd/regreet.toml"  /etc/greetd/regreet.toml
    install -m 644 "$GREETD_SRC/pam.d/greetd"         /etc/pam.d/greetd
else
    log "  WARN: $GREETD_SRC not found; greetd installed but unconfigured."
    log "        Expected install.sh to bind /run/ventoy or /root/arch-setup."
fi

# ---------- PAM: gnome-keyring auto-unlock on greetd login ----------
# Keyring unlock tied to greetd login password so Bitwarden's stored
# master password becomes readable at session start without extra typing.
log "Wiring gnome-keyring into greetd PAM stack..."
if [[ -f /etc/pam.d/greetd ]] && ! grep -q pam_gnome_keyring /etc/pam.d/greetd; then
    sed -i '/^auth.*include.*system-login/a auth       optional     pam_gnome_keyring.so' /etc/pam.d/greetd
    sed -i '/^session.*include.*system-login/a session    optional     pam_gnome_keyring.so auto_start' /etc/pam.d/greetd
fi
if ! grep -q pam_gnome_keyring /etc/pam.d/passwd; then
    echo 'password   optional   pam_gnome_keyring.so' >> /etc/pam.d/passwd
fi

# ---------- PAM: sudo (fingerprint optional) ----------
# Phase-3 postinstall §7a OWNS the sudo / hyprlock PAM stacks end-to-end
# (PIN → fingerprint → password). We don't pre-inject fingerprint here
# because it would conflict with postinstall's tee-overwrite. The greetd
# PAM stack we just installed already includes fprintd at sufficient.

# ---------- pre-seed NetworkManager Wi-Fi profiles ----------
# Mirror install.sh WIFI_PROFILES and autounattend.xml Wi-Fi block.
log "Seeding NetworkManager Wi-Fi profiles..."
WIFI_PROFILES=(
    "ATTgs5BwGZ:t8ueiz43ueaf"
    "rhombus:n3wPassword"
    "rhombus_legacy:n3wPassword"
)
mkdir -p /etc/NetworkManager/system-connections
for pair in "${WIFI_PROFILES[@]}"; do
    s="${pair%%:*}"; p="${pair#*:}"
    f="/etc/NetworkManager/system-connections/${s}.nmconnection"
    cat > "$f" <<EOF
[connection]
id=$s
type=wifi
autoconnect=true
autoconnect-priority=10

[wifi]
mode=infrastructure
ssid=$s

[wifi-security]
key-mgmt=wpa-psk
psk=$p

[ipv4]
method=auto

[ipv6]
method=auto
addr-gen-mode=default
EOF
    chmod 600 "$f"
done

# ---------- pacman: color, parallel downloads, verbose ----------
log "Tuning pacman.conf (Color, ParallelDownloads=10, ILoveCandy)..."
sed -i 's/^#Color$/Color/'                       /etc/pacman.conf
sed -i 's/^#VerbosePkgLists$/VerbosePkgLists/'   /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*$/ParallelDownloads = 10/' /etc/pacman.conf
grep -q '^ILoveCandy' /etc/pacman.conf || sed -i '/^ParallelDownloads/a ILoveCandy' /etc/pacman.conf

# ---------- journald: cap size (Netac /var is ~110 GB but log bloat is free to avoid) ----------
log "Capping journald to 200M..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-size.conf <<EOF
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOF

# ---------- bluetooth: auto-enable on boot ----------
log "Bluetooth AutoEnable=true..."
if [[ -f /etc/bluetooth/main.conf ]]; then
    sed -i 's/^#AutoEnable=false/AutoEnable=true/' /etc/bluetooth/main.conf
    grep -q '^AutoEnable=' /etc/bluetooth/main.conf || \
        sed -i '/^\[Policy\]/a AutoEnable=true' /etc/bluetooth/main.conf
    # Final fallback: if both seds silently no-op'd, append a fresh [Policy] block.
    grep -q '^AutoEnable=true' /etc/bluetooth/main.conf || \
        printf '\n[Policy]\nAutoEnable=true\n' >> /etc/bluetooth/main.conf
fi

# ---------- services ----------
log "Enabling services..."
systemctl enable NetworkManager
systemctl enable greetd
systemctl enable bluetooth
systemctl enable fprintd
systemctl enable fstrim.timer

log "Chroot config done. Exiting chroot."
log "NEXT: boot into Arch, log in as tom, then run ~/postinstall.sh"
log "      — that enrolls your fingerprint and wires pinpam for TPM-PIN sudo."
