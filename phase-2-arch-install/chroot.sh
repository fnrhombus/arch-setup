#!/usr/bin/env bash
# phase-2-arch-install/chroot.sh
#
# Runs inside `arch-chroot /mnt` from install.sh. Sets up:
#   - timezone, locale, hostname
#   - user tom with wheel/sudo
#   - systemd-boot (shares the EFI Windows created at /boot)
#   - NVIDIA blacklist (MX250 Optimus — Intel iGPU only, decisions.md §Q5)
#   - NetworkManager + SDDM + bluetooth + fprintd enabled
#   - yay build is done in phase-3 (needs non-root + network)

set -euo pipefail
log()  { printf '\033[1;32m[chroot]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[chroot ✗]\033[0m %s\n' "$*" >&2; exit 1; }

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
HOSTNAME="inspiron"
log "Hostname → $HOSTNAME..."
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# ---------- root password ----------
log "Set root password:"
until passwd; do :; done

# ---------- user tom ----------
log "Creating user tom..."
useradd -m -G wheel,video,audio,input,storage -s /bin/zsh tom
log "Set password for tom:"
until passwd tom; do :; done
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
log "Lid-close: ignore on AC, suspend on battery..."
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/10-lid.conf <<EOF
[Login]
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF

# ---------- mkinitcpio ----------
log "Regenerating initramfs..."
# Explicit btrfs in MODULES= is belt-and-suspenders: `filesystems` hook usually
# pulls it via autodetect, but if autodetect misses it you get an unbootable
# kernel panic ("can't find root fs"). Cheap to force.
sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# ---------- systemd-boot ----------
log "Installing systemd-boot to /boot (shared EFI)..."
bootctl --path=/boot install

ROOT_UUID=$(findmnt -n -o UUID /)
cat > /boot/loader/loader.conf <<EOF
default arch.conf
timeout 3
console-mode max
editor yes
EOF
cat > /boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=UUID=$ROOT_UUID rootflags=subvol=@ rw quiet
EOF
cat > /boot/loader/entries/arch-fallback.conf <<EOF
title   Arch Linux (fallback)
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux-fallback.img
options root=UUID=$ROOT_UUID rootflags=subvol=@ rw
EOF
# LTS kernel entry — insurance against a mainline-kernel regression that
# prevents boot. Pick "Arch Linux (LTS)" from the systemd-boot menu if the
# default entry panics/hangs. linux-lts is pacstrapped alongside linux in
# install.sh so the kernel + initramfs files are already at /boot.
cat > /boot/loader/entries/arch-lts.conf <<EOF
title   Arch Linux (LTS)
linux   /vmlinuz-linux-lts
initrd  /intel-ucode.img
initrd  /initramfs-linux-lts.img
options root=UUID=$ROOT_UUID rootflags=subvol=@ rw quiet
EOF
# Note: Windows Boot Manager auto-discovered by systemd-boot if present at
# \EFI\Microsoft\Boot\bootmgfw.efi (Windows install writes it there).

# ---------- TPM2 stack (for pinpam in phase-3) ----------
# Sync the mirror DB first. pacstrap populated /var/lib/pacman/sync from the
# live ISO's snapshot, which can be days old; a stale DB makes `pacman -S`
# error with "target not found" for packages that were just rebuilt. Cheap.
log "Installing TPM2 userspace..."
pacman -Sy --noconfirm
pacman -S --noconfirm --needed tpm2-tss tpm2-tools libsecret gnome-keyring

# ---------- PAM: gnome-keyring auto-unlock on SDDM login ----------
# Adds keyring unlock tied to your SDDM login password, so Bitwarden's stored
# master password becomes readable at session start without extra typing.
log "Wiring gnome-keyring into SDDM PAM stack..."
if ! grep -q pam_gnome_keyring /etc/pam.d/sddm; then
    sed -i '/^auth.*include.*system-login/a auth       optional     pam_gnome_keyring.so' /etc/pam.d/sddm
    sed -i '/^session.*include.*system-login/a session    optional     pam_gnome_keyring.so auto_start' /etc/pam.d/sddm
fi
if ! grep -q pam_gnome_keyring /etc/pam.d/passwd; then
    echo 'password   optional   pam_gnome_keyring.so' >> /etc/pam.d/passwd
fi

# ---------- PAM: fingerprint for sudo + SDDM (fprintd prompts touch-finger) ----------
# `sufficient` means: if fingerprint auth succeeds, skip the rest (password
# not needed); if it fails/is-unavailable, fall through to pam_unix which
# prompts for password as normal. So worst-case failure mode of fprintd
# being sick is "login takes an extra 2-5s then asks for password." No
# lockout scenario exists as long as pam_unix is still in the stack after
# our insert.
log "Wiring fprintd into sudo + SDDM PAM stacks..."
for svc in sudo sddm; do
    if ! grep -q pam_fprintd "/etc/pam.d/$svc"; then
        sed -i '1i auth       sufficient   pam_fprintd.so' "/etc/pam.d/$svc"
    fi
done

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
systemctl enable sddm
systemctl enable bluetooth
systemctl enable fprintd
systemctl enable fstrim.timer

log "Chroot config done. Exiting chroot."
log "NEXT: boot into Arch, log in as tom, then run ~/postinstall.sh"
log "      — that enrolls your fingerprint and wires pinpam for TPM-PIN sudo."
