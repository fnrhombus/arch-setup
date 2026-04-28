#!/usr/bin/env bash
# prep-netac-ventoy.sh — turn Metis's internal Netac SSD into a Ventoy boot
# medium for the from-scratch reinstall. Use ONLY when the laptop's USB ports
# don't reliably boot Ventoy (the Metis case). Otherwise just stage a USB stick
# on the dev machine via `pnpm i`.
#
# WHAT IT DOES
#   1. Drains the Netac (swapoff cryptswap, lazy-umount /var/log + /var/cache,
#      force-remove the device-mapper entries). The running Arch session loses
#      /var and swap from this point — reboot ASAP after the script finishes.
#   2. Wipes the Netac's GPT (`sgdisk --zap-all /dev/sdb`).
#   3. Installs Ventoy to the whole Netac disk (creates the data partition +
#      the ~32 MB VTOYEFI companion). `pacman -S ventoy` if not present.
#   4. Mirrors the same payload that scripts/stage-ventoy.ps1 puts on a USB stick:
#      ISOs (Arch + Win11), autounattend.xml, ventoy/ventoy.json, repo dirs.
#
# AFTER IT FINISHES
#   - REBOOT NOW. Don't try to keep using this Arch session.
#   - F12 at the Dell logo → pick the Netac as the boot device.
#   - Ventoy menu appears. Pick Win11 first (Phase 1). Then Arch (Phase 2).
#   - Phase 2's install.sh wipes the entire Netac AGAIN and rebuilds the
#     §Q9 layout (recovery ISO + cryptswap + cryptvar). The Ventoy install is
#     sacrificial — used only for bootstrap.
#
# PREREQUISITES
#   - Run as root.
#   - Both ISOs already downloaded somewhere accessible. Default search path
#     is `<repo>/assets/`. Override with ARCH_ISO=/path/to/foo.iso
#     WIN_ISO=/path/to/bar.iso environment variables. The `pnpm i` flow on the
#     dev machine puts them at the right names; SCP them over to Metis or
#     re-fetch via fetch-assets.ps1 equivalent.
#
# THIS IS A ONE-WAY DOOR. After step 1 the running system can't recover
# without rebooting into the new Netac-Ventoy installer flow. Be ready.

set -euo pipefail

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

confirm_phrase() {
    local prompt="$1" expected="$2" reply
    read -rp "$prompt: " reply
    [[ "$reply" == "$expected" ]] || die "Aborted (didn't type the expected phrase exactly)."
}

# ---------- 0. sanity ----------
[[ $EUID -eq 0 ]] || die "Run as root."
command -v sgdisk     >/dev/null || die "sgdisk missing — install gptfdisk."
command -v cryptsetup >/dev/null || die "cryptsetup missing — required to close cryptvar/cryptswap."
command -v dmsetup    >/dev/null || die "dmsetup missing — required for force-removing device-mapper entries."
command -v rsync      >/dev/null || die "rsync missing — install rsync."
command -v partprobe  >/dev/null || die "partprobe missing — install parted."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
[[ -f "$REPO_ROOT/CLAUDE.md" && -f "$REPO_ROOT/autounattend.xml" ]] \
    || die "Couldn't locate the arch-setup repo at $REPO_ROOT (need CLAUDE.md + autounattend.xml)."

# ---------- 1. detect Netac ----------
# Same size window as install.sh (100-150 GiB).
NETAC=""
for dev in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    bytes=$(lsblk -bdno SIZE "/dev/$dev")
    gib=$((bytes / 1024 / 1024 / 1024))
    (( gib >= 100 && gib <= 150 )) && { NETAC="/dev/$dev"; break; }
done
[[ -n "$NETAC" ]] || die "No 100-150 GiB disk found (expected the Netac 128 GB)."

# Sanity: also confirm Samsung is present and won't be touched.
SAMSUNG=""
for dev in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    [[ "/dev/$dev" == "$NETAC" ]] && continue
    bytes=$(lsblk -bdno SIZE "/dev/$dev")
    gib=$((bytes / 1024 / 1024 / 1024))
    (( gib >= 450 && gib <= 520 )) && { SAMSUNG="/dev/$dev"; break; }
done
[[ -n "$SAMSUNG" ]] || warn "No 450-520 GiB Samsung detected — that's a problem for Phase 2 but not for this script. Continuing."

log "Netac (will be wiped + re-imaged as Ventoy): $NETAC"
[[ -n "$SAMSUNG" ]] && log "Samsung (untouched by this script): $SAMSUNG"

# ---------- 2. locate ISOs ----------
ARCH_ISO="${ARCH_ISO:-$(ls "$REPO_ROOT"/assets/archlinux-*.iso 2>/dev/null | head -1 || true)}"
WIN_ISO="${WIN_ISO:-$(ls "$REPO_ROOT"/assets/Win11_*.iso 2>/dev/null | head -1 || true)}"

[[ -f "$ARCH_ISO" ]] || die "Arch ISO not found. Set ARCH_ISO=/path/to/archlinux-x86_64.iso, or stage assets/ first."
[[ -f "$WIN_ISO"  ]] || die "Win11 ISO not found. Set WIN_ISO=/path/to/Win11_25H2_English_x64_v2.iso, or stage assets/ first."

# Win11 ISO needs to be named exactly what ventoy.json's auto_install expects,
# else the autounattend injection silently no-ops.
EXPECTED_WIN_NAME="Win11_25H2_English_x64_v2.iso"
WIN_BASENAME="$(basename "$WIN_ISO")"
if [[ "$WIN_BASENAME" != "$EXPECTED_WIN_NAME" ]]; then
    warn "Win11 ISO is named '$WIN_BASENAME' but ventoy/ventoy.json expects '$EXPECTED_WIN_NAME'."
    warn "  Will copy as '$EXPECTED_WIN_NAME' on the Ventoy partition so auto_install matches."
fi

ARCH_SIZE=$(numfmt --to=iec --suffix=B "$(stat -c%s "$ARCH_ISO")")
WIN_SIZE=$(numfmt --to=iec --suffix=B "$(stat -c%s "$WIN_ISO")")
log "Arch ISO: $(basename "$ARCH_ISO") ($ARCH_SIZE)"
log "Win11 ISO: $WIN_BASENAME ($WIN_SIZE)"

# ---------- 3. ventoy package ----------
if ! [[ -x /usr/bin/Ventoy2Disk.sh ]] && ! [[ -x /opt/ventoy/Ventoy2Disk.sh ]]; then
    log "Installing ventoy package..."
    pacman -Sy --noconfirm --needed ventoy
fi
VENTOY_BIN=$(command -v Ventoy2Disk.sh 2>/dev/null || echo /opt/ventoy/Ventoy2Disk.sh)
[[ -x "$VENTOY_BIN" ]] || die "Ventoy2Disk.sh not found after install."
log "Ventoy: $VENTOY_BIN"

# ---------- 4. show plan + double-confirm ----------
cat <<EOF

============================================================
  WIPE-AND-VENTOYIFY THE NETAC ($NETAC) — REINSTALL BOOTSTRAP
============================================================

About to:
  1. swapoff /dev/mapper/cryptswap (the active Linux swap on the Netac)
  2. Lazy-umount /var/log + /var/cache + /mnt/netac-var
  3. dmsetup remove --force cryptvar + cryptswap (kills active mappings,
     even with open fds — journald/syslog continue writing to dangling fds
     until reboot)
  4. sgdisk --zap-all $NETAC (destroys the GPT)
  5. Ventoy2Disk.sh -I $NETAC (lays down Ventoy's partition layout)
  6. Mount the new Ventoy data partition
  7. rsync the install payload (ISOs, autounattend.xml, ventoy/, phase-*,
     docs/, runbook/, CLAUDE.md, phase-6-grow-windows.sh)
  8. sync + unmount

ONE-WAY DOOR: after step 1, the running Arch session is unrecoverable.
You're committing to reboot into the new Netac-Ventoy installer flow.

The Samsung ($SAMSUNG) is NOT touched. Windows + the prior Arch root stay
intact — until you boot Phase 2's install.sh, which carves the Samsung's
trailing free space as the new ArchRoot.

EOF

confirm_phrase 'Type "WIPE THE NETAC" to proceed' 'WIPE THE NETAC'

# ---------- 5. drain the Netac ----------
log "swapoff /dev/mapper/cryptswap..."
swapoff /dev/mapper/cryptswap 2>/dev/null || warn "swapoff failed (already off?)"

log "Lazy-umount /var/log /var/cache /mnt/netac-var (open fds keep working until reboot)..."
umount -l /var/log       2>/dev/null || true
umount -l /var/cache     2>/dev/null || true
umount -l /mnt/netac-var 2>/dev/null || true

log "Force-removing device-mapper entries (cryptvar, cryptswap)..."
dmsetup remove --force /dev/mapper/cryptvar  2>/dev/null || warn "cryptvar remove failed (already gone?)"
dmsetup remove --force /dev/mapper/cryptswap 2>/dev/null || warn "cryptswap remove failed (already gone?)"

# Belt-and-suspenders: also tell cryptsetup the mappings are closed (no-op if dmsetup got them).
cryptsetup close cryptvar  2>/dev/null || true
cryptsetup close cryptswap 2>/dev/null || true

# Settle so partition probes find the bare disk.
udevadm settle
sleep 1

# ---------- 6. wipe + Ventoy ----------
log "Wiping $NETAC GPT..."
sgdisk --zap-all "$NETAC"
partprobe "$NETAC"
sleep 1
udevadm settle

log "Installing Ventoy to $NETAC (this prompts internally — answering yes via -I)..."
# Ventoy2Disk.sh uses -i for install (interactive) and -I for forced install
# (skips its own "y/n" confirmation since we did our own up top). exFAT is
# the default data-partition filesystem; suits Win11 + large ISO files.
"$VENTOY_BIN" -I "$NETAC"

# Wait for the new partitions to appear.
sleep 3
partprobe "$NETAC"
udevadm settle
sleep 1

# Find the Ventoy data partition by label.
VENTOY_DATA=""
for try in 1 2 3 4 5; do
    VENTOY_DATA=$(lsblk -lno NAME,LABEL "$NETAC" | awk '$2=="Ventoy"{print "/dev/"$1; exit}')
    [[ -b "$VENTOY_DATA" ]] && break
    sleep 1
done
[[ -b "$VENTOY_DATA" ]] || die "Ventoy data partition (label=Ventoy) didn't appear on $NETAC after install. Inspect with lsblk."
log "Ventoy data partition: $VENTOY_DATA"

# ---------- 7. mount + populate ----------
MNT=$(mktemp -d /tmp/ventoy-mount-XXXXXX)
log "Mounting $VENTOY_DATA at $MNT..."
mount "$VENTOY_DATA" "$MNT"

log "Copying ISOs..."
cp -v "$ARCH_ISO" "$MNT/$(basename "$ARCH_ISO")"
cp -v "$WIN_ISO"  "$MNT/$EXPECTED_WIN_NAME"

# Optional sidecar files (sig + sha) — copy if present, no error if not.
for sidecar in "$REPO_ROOT"/assets/archlinux-x86_64.iso.sig "$REPO_ROOT"/assets/archlinux-sha256sums.txt; do
    [[ -f "$sidecar" ]] && cp -v "$sidecar" "$MNT/"
done

log "Mirroring repo into Ventoy data partition (excluding .git, node_modules, assets, PDFs)..."
log "  (exFAT can't store unix perms/owner/symlinks — rsync errors on those are expected and ignored.)"
# rsync flag breakdown:
#   -r recursive, -t times — what we actually need
#   --no-perms / --no-owner / --no-group — exFAT has no concept of these
#   (no -l): drop symlinks entirely (exFAT can't represent them either).
# Dotfiles live in the separate rhombu5/dots repo and are fetched at
# postinstall time via `chezmoi init --apply` — no copy here.
if ! rsync -rt --info=progress2 \
        --no-perms --no-owner --no-group \
        --exclude='.git' \
        --exclude='node_modules' \
        --exclude='assets' \
        --exclude='runbook/*.pdf' \
        "$REPO_ROOT/" "$MNT/"; then
    warn "rsync exited non-zero — likely exFAT metadata-only errors (Operation not permitted on chown/symlink). File content should be intact; verify by spot-checking $MNT/."
fi

log "Syncing to disk (this may take a minute on a 119 GB partition)..."
sync

log "Unmounting..."
umount "$MNT"
rmdir "$MNT"

# ---------- 8. done ----------
cat <<DONE

============================================================
  PREP COMPLETE — REBOOT NOW
============================================================

The Netac is now a Ventoy boot medium with both ISOs + the
arch-setup repo. Your running Arch session is missing /var
and swap; do NOT continue working in it.

NEXT STEPS:
  1. \`reboot\` (or just hold the power button)
  2. F12 at the Dell logo
  3. Pick the Netac as the boot device (often "Internal SSD"
     or by the Netac model name)
  4. Ventoy menu appears — autosel will pick the Win11 ISO
     after 5 sec, or pick it manually
  5. Phase 1 (Windows install) runs unattended — see
     runbook/INSTALL-RUNBOOK.md §Phase 1
  6. Reboot, F12 again, this time pick archlinux-*.iso
  7. Run install.sh — see runbook/INSTALL-RUNBOOK.md §Phase 2

If you want a Claude session walking you through this on
your phone while the laptop is unbootable, paste the contents
of runbook/phase-0-handoff.md as the first message in a new
Claude conversation.

============================================================
DONE
