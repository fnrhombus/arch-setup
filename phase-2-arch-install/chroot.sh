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
hwclock --systohc

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
# Note: Windows Boot Manager auto-discovered by systemd-boot if present at
# \EFI\Microsoft\Boot\bootmgfw.efi (Windows install writes it there).

# ---------- TPM2 stack (for pinpam in phase-3) ----------
log "Installing TPM2 userspace..."
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

# ---------- PAM: fingerprint for sudo (fprintd prompts touch-finger) ----------
log "Wiring fprintd into sudo PAM stack..."
if ! grep -q pam_fprintd /etc/pam.d/sudo; then
    sed -i '1i auth       sufficient   pam_fprintd.so' /etc/pam.d/sudo
fi

# ---------- services ----------
log "Enabling services..."
systemctl enable NetworkManager
systemctl enable sddm
systemctl enable bluetooth
systemctl enable fprintd

log "Chroot config done. Exiting chroot."
log "NEXT: boot into Arch, log in as tom, then run ~/postinstall.sh"
log "      — that enrolls your fingerprint and wires pinpam for TPM-PIN sudo."
