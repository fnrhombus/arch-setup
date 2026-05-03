#!/usr/bin/env bash
# phase-2-arch-install/chroot.sh
#
# Runs inside `arch-chroot /mnt` from install.sh. Sets up:
#   - timezone, locale, hostname (= metis)
#   - user tom with wheel/sudo
#   - limine bootloader (UEFI binary at the ESP fallback path
#     \EFI\BOOT\BOOTX64.EFI + a NVRAM entry — fallback-path copy is the
#     load-bearing one since some firmware drops NVRAM entries on update)
#   - hibernate via btrfs swapfile (resume= + resume_offset= in /etc/kernel/cmdline)
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
[[ -n "${LUKS_ROOT_UUID:-}" ]] \
    || die "/root/.luks is missing LUKS_ROOT_UUID."
[[ -n "${SWAP_RESUME_OFFSET:-}" ]] \
    || die "/root/.luks is missing SWAP_RESUME_OFFSET (needed for hibernate resume= in kernel cmdline)."
[[ -n "${SAMSUNG_DISK:-}" && -b "$SAMSUNG_DISK" ]] \
    || die "/root/.luks is missing SAMSUNG_DISK or it isn't a block device."

# ---------- timezone + clock ----------
log "Timezone → America/New_York (adjust in /etc/localtime if wrong)..."
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
# Single-OS Arch (Windows dual-boot was dropped 2026-04-27 per CLAUDE.md),
# so RTC stays in UTC — the Linux default. The OLD chroot.sh wrote LOCAL
# here as a Windows-dualboot accommodation; carrying it forward into the
# single-OS world produced a 4-hour clock skew that propagated through
# every JWT signed against Azure (cert auth's `nbf` claim landed in the
# future from the IdP's perspective), among other woes.
cat > /etc/adjtime <<'EOF'
0.0 0 0.0
0
UTC
EOF
# Enable network time sync so the system clock self-corrects on first
# boot — RTC drift over months in a powered-off laptop is real.
log "Enabling systemd-timesyncd..."
systemctl enable systemd-timesyncd.service

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

# ---------- NVIDIA: display-blacklist, compute-allow (decisions.md §Q5) ----------
# MX250 can't drive Wayland (nvidia-470xx lacks GBM), so the DISPLAY
# modules stay blacklisted — Hyprland runs on Intel UHD 620 only. But
# the kernel module (nvidia) and CUDA (nvidia_uvm) DO load, so headless
# CUDA compute works (photogrammetry: Meshroom / COLMAP; ML; etc.).
# nvidia-470xx-dkms package gets installed by postinstall §3.
log "Configuring NVIDIA: display modules blacklisted, compute (CUDA) allowed..."
cat > /etc/modprobe.d/blacklist-nvidia.conf <<EOF
# nouveau (open driver) would conflict with nvidia-470xx — keep blocked.
blacklist nouveau
# Display modules: never want these loaded; would try to drive Wayland.
blacklist nvidia_drm
blacklist nvidia_modeset
# Note: nvidia + nvidia_uvm are NOT blacklisted — they're needed for CUDA.
# They load on demand when a CUDA app runs (or you can modprobe them
# explicitly). nvidia stays idle when no compute workload is running.
EOF

# ---------- lid-close policy (decisions.md Requirements) ----------
# All lid handling is owned by ~/.local/bin/lid-handler from the user's
# Hyprland session (wired via `binddl` on `Lid Switch` — see rhombu5/dots
# `dot_config/hypr/binds.conf`). Rule: hibernate on close, unless on AC
# with an external monitor attached (then disable eDP-1). Logind needs to
# stay out of the way across the board — defaults are `suspend`, which
# we override to `ignore` everywhere so Hyprland's bindl is the only
# actor. Side effect: at the greeter / TTY (no Hyprland) lid close is a
# no-op, which is fine — those states only exist with the laptop open.
log "Lid-close: hand off to user-session lid-handler (logind ignores)..."
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/10-lid.conf <<EOF
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF

# ---------- crypttab (FDE per decisions.md §Q11) ----------
# Single LUKS volume → single crypttab.initramfs entry.
#
#   /etc/crypttab.initramfs  — baked into initramfs by mkinitcpio's sd-encrypt
#                               hook. Opens cryptroot before the root fs is
#                               mounted. Entry uses `none` for the keyfile so
#                               systemd prompts the user for the passphrase
#                               at boot (TPM2 unlock takes over once enrolled
#                               — see tpm2-device=auto below).
#
# tpm2-device=auto: present iff install.sh successfully enrolled TPM2 at
# format time (BitLocker-style: the very first boot is silent). If
# enrollment failed or no TPM was present, omit the option — leaving it
# in would block boot waiting for a non-existent TPM2 slot
# (systemd/systemd#39049, #36293). Phase-3 postinstall §7.5 retries
# enrollment in that case and rewrites this line on success.
#
# Hibernate uses a swapfile inside the (already-unlocked) btrfs root
# subvolume @swap — see /etc/kernel/cmdline below for resume= +
# resume_offset=. No separate cryptswap volume needed.
log "Writing /etc/crypttab.initramfs (cryptroot only — swap is a btrfs swapfile)..."
if [[ "${TPM_ENROLLED_AT_INSTALL:-0}" == "1" ]]; then
    _crypt_opts="luks,discard,tpm2-device=auto"
    log "  TPM2 already enrolled at install — adding tpm2-device=auto so first boot unlocks silently."
else
    _crypt_opts="luks,discard"
    log "  No TPM2 enrollment yet — first boot will prompt for the passphrase; postinstall §7.5 retries."
fi
cat > /etc/crypttab.initramfs <<EOF
cryptroot UUID=$LUKS_ROOT_UUID none $_crypt_opts
EOF
chmod 600 /etc/crypttab.initramfs

# ---------- mkinitcpio (UKI mode) ----------
# UKI = Unified Kernel Image. A single PE binary that bundles kernel +
# initramfs + cmdline + signed PCR predictions. Built by mkinitcpio via
# ukify. Booted directly by limine via efi_chainload.
#
# Why UKI vs separate vmlinuz/initramfs:
#   - ukify embeds signed PCR 11 predictions in a `.pcrsig` PE section, which
#     systemd-cryptsetup uses at boot to satisfy the signed-PCR-11 LUKS
#     seal policy. This is the foundation of BitLocker-style silent boot —
#     see docs/tpm-luks-bitlocker-parity.md for the full design.
#   - Single binary = simpler limine config (efi_chainload only), no separate
#     module_path lines for kernel + ucode + initramfs.
#
# /etc/kernel/uki.conf tells ukify what to bundle, what cmdline to use, which
# PCRs to predict for, and which key to sign with. Created BEFORE the
# preset edit so mkinitcpio -P picks it up on first run.
log "Configuring ukify (PCR signing keypair from §5a)..."
install -d -m 755 /etc/kernel
cat > /etc/kernel/uki.conf <<EOF
# Consumed by ukify, invoked by mkinitcpio when a preset has default_uki=.
# Signs PCR 11 predictions for these phases — covers initrd-side LUKS unlock
# (after enter-initrd, before leave-initrd). Keys generated in install.sh §5a.
#
# PCRBanks=sha256 sha1 is belt-and-suspenders: install.sh §5-prep tries to
# allocate both banks; if that fails on quirky Intel PTT firmware and the
# TPM ends up sha1-only, the install-time cryptenroll seal will use sha1
# PCR 11 — and ukify needs to sign sha1 PCR 11 too or boot can never unseal.
# Signing both is cheap (~few-KB increase in .pcrsig section).
[UKI]
PCRBanks=sha256 sha1

[PCRSignature:initrd]
PCRPrivateKey=/etc/systemd/tpm2-pcr-private.pem
PCRPublicKey=/etc/systemd/tpm2-pcr-public.pem
Phases=enter-initrd
EOF

# Kernel cmdline lives in /etc/kernel/cmdline (not limine.conf) — UKIs embed
# their cmdline.
#   resume=/dev/mapper/cryptroot      — the LUKS-mapper backing the btrfs
#                                       that holds the swapfile.
#   resume_offset=$SWAP_RESUME_OFFSET  — physical extent offset of the
#                                       swapfile within the btrfs volume,
#                                       captured by install.sh §8.5.
#   rootflags=subvol=@                 — keep root on the @ subvolume.
#   quiet                              — keep boot logs out of the user's face.
cat > /etc/kernel/cmdline <<EOF
root=/dev/mapper/cryptroot rootflags=subvol=@ resume=/dev/mapper/cryptroot resume_offset=$SWAP_RESUME_OFFSET rw quiet
EOF
chmod 644 /etc/kernel/cmdline

log "Regenerating initramfs as UKIs at /boot/EFI/Linux/..."
install -d -m 755 /boot/EFI/Linux
# Explicit btrfs in MODULES= is belt-and-suspenders: `filesystems` hook usually
# pulls it via autodetect, but if autodetect misses it you get an unbootable
# kernel panic ("can't find root fs"). Cheap to force.
# HOOKS ordering: sd-encrypt must sit between `block` (loads block-device
# modules) and `filesystems` (mounts root). It reads /etc/crypttab.initramfs
# at boot and opens cryptroot before `filesystems` tries to mount it.
sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf

# Switch presets to UKI mode + drop fallback build.
#
# UKI sizes: ~80 MB default, ~160 MB fallback (autodetect strips modules
# from the default initramfs; fallback bundles all of them). Two kernels
# × default-only = ~160 MB on the 1 GiB ESP — plenty of room left for
# sbctl-signed copies once Secure Boot is enrolled.
#
# Trade-off vs. keeping fallback: a broken autodetect on the default UKI
# leaves no boot path. Mitigation: linux-lts default UKI IS the regression
# fallback — kernel regressions are the canonical reason fallback exists,
# and LTS covers that. Bad-autodetect is rare on this stable hardware.
#
# Idempotent: multiple sed runs converge.
for _preset in /etc/mkinitcpio.d/linux.preset /etc/mkinitcpio.d/linux-lts.preset; do
    [[ -f "$_preset" ]] || continue
    _kver="${_preset##*/}"; _kver="${_kver%.preset}"   # linux | linux-lts
    sed -i \
        -e 's|^default_image=|#default_image=|' \
        -e 's|^fallback_image=|#fallback_image=|' \
        -e "s|^PRESETS=.*|PRESETS=('default')|" \
        "$_preset"
    grep -q '^default_uki='   "$_preset" || \
        echo "default_uki=\"/boot/EFI/Linux/arch-${_kver}.efi\""           >> "$_preset"
    # Strip any pre-existing fallback_uki line so mkinitcpio doesn't try
    # to build the second image even if PRESETS was edited correctly.
    sed -i '/^fallback_uki=/d' "$_preset"
done
unset _preset _kver

mkinitcpio -P

# ---------- limine bootloader (replaces systemd-boot) ----------
# limine chosen for: snapshot-rollback boot menu via limine-snapper-sync
# (matches our btrfs+snapper setup), bootable-ISO-from-disk support
# (Netac recovery partition becomes reachable), modern actively-developed
# bootloader. Decision: docs/decisions.md §A.
#
# Phase 2 installs limine itself; phase-3 postinstall installs the AUR
# limine-snapper-sync package + enables its hook for auto-regenerating
# entries from new snapper snapshots.
log "Installing limine bootloader..."
pacman -S --noconfirm --needed limine

# UEFI install: copy the limine EFI binary to the ESP fallback path
# (\EFI\BOOT\BOOTX64.EFI). Firmware boots this without needing a NVRAM
# entry — load-bearing because some firmware drops NVRAM entries on
# BIOS update or CMOS reset.
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

# Limine config — written to /boot/limine.conf. Each Linux entry chainloads
# a UKI from /boot/EFI/Linux/ via efi_chainload. UKIs embed their own
# cmdline (/etc/kernel/cmdline, baked in at mkinitcpio -P time), so limine
# doesn't need to specify it.
#
# Why efi_chainload instead of `protocol: linux`: the signed PCR 11
# predictions live inside the UKI's `.pcrsig` PE section. Booting via
# protocol: linux would unpack and re-stitch kernel+initrd, breaking the
# UKI's PE layout and invalidating the signature → TPM refuses to unseal
# the LUKS slot → recovery key prompt on every boot. efi_chainload runs
# the UKI as-is (firmware loads it as a PE binary), preserving sig validity.
#
# SYNTAX-CHECK: limine 8.x config format. If syntax has drifted by the
# time this runs, see https://github.com/limine-bootloader/limine/blob/trunk/CONFIG.md
log "Writing /boot/limine.conf (efi_chainload UKIs)..."
cat > /boot/limine.conf <<'EOF'
timeout: 5
default_entry: 1

/Arch Linux
    protocol: efi_chainload
    image_path: boot():/EFI/Linux/arch-linux.efi

/Arch Linux (LTS)
    protocol: efi_chainload
    image_path: boot():/EFI/Linux/arch-linux-lts.efi
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
# Kernel / mkinitcpio / systemd / limine upgrades regenerate UKIs (which
# rewrites the .pcrsig section). The seal still unseals because the policy
# is "signed by our key", which holds across rebuilds — but if postinstall
# §7.5 added stage-2 PCR 7 binding, we ALSO need to refresh the PCR 7
# binding when firmware/SB state changes. This hook re-runs
# systemd-cryptenroll on every TPM2-enrolled LUKS device using the
# saved policy (signed PCR 11 + optional PCR 7), no-op'ing safely when
# nothing actually drifted.
#
# Auto-discovers devices by scanning /etc/crypttab(.initramfs) for entries
# with tpm2-device=auto.
log "Installing pacman post-upgrade TPM2 reseal hook..."
cat > /etc/pacman.d/hooks/95-tpm2-reseal.hook <<'EOF'
[Trigger]
Operation = Upgrade
Type = Package
Target = linux
Target = linux-lts
Target = mkinitcpio
Target = systemd
Target = limine
Target = sbctl

[Action]
Description = Re-enrolling TPM2 PCR slots on TPM-sealed LUKS volumes...
When = PostTransaction
Exec = /usr/local/sbin/tpm2-reseal-luks
EOF

install -d -m 755 /usr/local/sbin
cat > /usr/local/sbin/tpm2-reseal-luks <<'BASH'
#!/usr/bin/env bash
# Re-enrol every TPM2-sealed LUKS device with the install-time policy
# (signed PCR 11 + PCR 7). Triggered by
# /etc/pacman.d/hooks/95-tpm2-reseal.hook after kernel/UKI/limine/systemd/
# sbctl upgrades, plus manually after Secure-Boot toggle / firmware
# update / TPM clear.
#
# Stage-1 / stage-2 sentinel logic was removed 2026-04-28 — install.sh
# now enrolls signed-PCR-11 + PCR 7 together, so the reseal hook always
# applies the same policy.
set -euo pipefail

PUB=/etc/systemd/tpm2-pcr-public.pem
[[ -f "$PUB" ]] || { echo "tpm2-reseal: $PUB missing — skipping (was the install half-done?)" >&2; exit 0; }

reseal_one() {
    local dev="$1"
    [[ -b "$dev" ]] || { echo "tpm2-reseal: $dev not present (yet?); skipping" >&2; return; }
    echo "tpm2-reseal: re-enrolling TPM2 slot on $dev..."
    systemd-cryptenroll --wipe-slot=tpm2 "$dev" >/dev/null 2>&1 || true
    systemd-cryptenroll --tpm2-device=auto \
        --tpm2-public-key="$PUB" --tpm2-public-key-pcrs=11 \
        --tpm2-pcrs=7 \
        "$dev"
}

scan() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        # Tab-or-space separated: name source key options
        # shellcheck disable=SC2086
        set -- $line
        local src="${2:-}" opts="${4:-}" dev
        [[ "$opts" == *tpm2-device=auto* ]] || continue
        case "$src" in
            UUID=*)     dev="/dev/disk/by-uuid/${src#UUID=}" ;;
            PARTUUID=*) dev="/dev/disk/by-partuuid/${src#PARTUUID=}" ;;
            /dev/*)     dev="$src" ;;
            *)          echo "tpm2-reseal: unknown source format: $src" >&2; continue ;;
        esac
        reseal_one "$dev"
    done < "$file"
}

scan /etc/crypttab.initramfs
scan /etc/crypttab

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

# ---------- TPM2 PCR bank: report current state ----------
# Bank allocation now happens in install.sh §5-prep (BEFORE the install-
# time TPM enrollment in §5b). Reallocating here would be a TPM-firmware-
# level reset that WIPES the install-time seal — we explicitly DON'T want
# that anymore.
#
# Just report what's active so the chroot log shows ground truth for
# debugging. Postinstall §7.5 will reseal as needed using whatever banks
# are active now.
log "TPM2 PCR banks (allocated at install time, not re-allocating here)..."
if command -v tpm2_getcap >/dev/null 2>&1; then
    tpm2_getcap pcrs 2>/dev/null | grep -iE 'sha[0-9]+:' | head -4 || true
fi

# ---------- greetd + ReGreet system-files install (kept for fallback) ----------
# greetd replaced SDDM 2026-04-22; subsequently disabled by postinstall §1f
# (2026-04-30) in favour of bare TTY login → uwsm → Hyprland. We still
# install + configure + enable here so:
#   - first boot before postinstall has a graphical login surface,
#   - the greeter is fully themed/PAM-wired if the user ever re-enables
#     it as a fallback (decisions.md §D, desktop-requirements.md "Login").
# Source files live alongside postinstall in phase-3/system-files/.
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

# ---------- PAM: gnome-keyring auto-unlock on greetd login (fallback only) ----------
# Wires pam_gnome_keyring into the greetd PAM stack so the keyring
# auto-unlocks IF greetd is ever re-enabled. With the active bare-TTY
# login (postinstall §1f), /etc/pam.d/login does NOT include
# pam_gnome_keyring — the keyring stays locked until `bwu` (or anything
# else that hits libsecret) triggers gnome-keyring's own unlock prompt.
# Keeping this wiring here means the fallback path stays fully
# functional without further setup.
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
    "Ganymede:n3wPassword"
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
sed -i -E 's/^#?ParallelDownloads.*$/ParallelDownloads = 10/' /etc/pacman.conf
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
