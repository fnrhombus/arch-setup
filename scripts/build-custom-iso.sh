#!/usr/bin/env bash
# scripts/build-custom-iso.sh
#
# Build the fnrhombus/arch-setup custom Arch Linux live ISO.
#
# What this produces:
#   assets/arch-setup-<YYYY.MM.DD>-x86_64.iso
#
# The ISO boots an archiso live environment with a copy of this whole repo
# at /root/arch-setup/ — so the first thing the user does on Metis after
# booting the recovery partition is:
#     sudo bash /root/arch-setup/phase-2-arch-install/install.sh
# No USB-staging, no dm-linear Ventoy passthrough, no "did we remember to
# copy docs/?" — it's all in the ISO.
#
# Environment:
#   - Must run on an Arch Linux host. If you're on Windows, invoke
#     scripts/build-custom-iso.ps1, which delegates to an archlinux WSL
#     distro running this script.
#   - archiso + arch-install-scripts installed on the host (or available
#     inside the container if --docker is used).
#   - Run as a user with sudo rights (mkarchiso requires root — pacstrap
#     and loop-mount operations need real capabilities).
#
# Flags:
#   --docker        Run mkarchiso inside a privileged archlinux/archlinux
#                   container instead of the host. Useful when the host
#                   doesn't have archiso installed, or when running under
#                   WSL where host-native mkarchiso has been observed to
#                   fail on loop-mount quirks.
#   --clean         Wipe work/ before building (force a from-scratch
#                   squashfs regen). Default is to reuse work/ for fast
#                   re-builds when only airootfs overlay files changed.
#   --no-payload    Skip staging the repo into airootfs/root/arch-setup.
#                   Produces a plain live ISO. Used for profile-only
#                   shakedown builds.
#
# Output: $REPO_ROOT/assets/arch-setup-*.iso (gitignored by pattern).
#
# Idempotent: re-run anytime. work/ is reused across runs unless --clean.
# The staged payload at phase-1-iso/airootfs/root/arch-setup/ is cleaned
# up on every exit (trap), so the profile stays clean for git.

set -euo pipefail

# ---------- helpers ----------
log()  { printf '\033[1;32m[iso]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[iso !]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[iso ✗]\033[0m %s\n' "$*" >&2; exit 1; }

USE_DOCKER=0
DO_CLEAN=0
SKIP_PAYLOAD=0
for arg in "$@"; do
    case "$arg" in
        --docker)     USE_DOCKER=1 ;;
        --clean)      DO_CLEAN=1 ;;
        --no-payload) SKIP_PAYLOAD=1 ;;
        -h|--help)
            sed -n '3,/^set -euo/p' "$0" | sed '$d'
            exit 0
            ;;
        *) die "unknown arg: $arg (try --help)" ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_DIR="$REPO_ROOT/phase-1-iso"
OUT_DIR="$REPO_ROOT/assets"
WORK_DIR="$REPO_ROOT/phase-1-iso/work"

[[ -d "$PROFILE_DIR" ]] || die "Profile dir missing: $PROFILE_DIR"
[[ -f "$PROFILE_DIR/profiledef.sh" ]] || die "profiledef.sh missing in $PROFILE_DIR"

# rsync is used to stage the payload. It's in base-devel on Arch; on a
# fresh WSL distro it may need `pacman -S rsync` up front.
command -v rsync >/dev/null || die "rsync not found on host — install with: sudo pacman -S rsync"

mkdir -p "$OUT_DIR"

# ---------- payload staging ----------
# Copy the entire repo (minus build artifacts + the profile dir itself)
# into phase-1-iso/airootfs/root/arch-setup/. The profile's file_permissions
# block sets this dir to 0750 root:root. Cleaned up on exit regardless of
# exit code.
PAYLOAD_DIR="$PROFILE_DIR/airootfs/root/arch-setup"
cleanup_payload() {
    if [[ -d "$PAYLOAD_DIR" ]]; then
        log "cleaning up staged payload at $PAYLOAD_DIR"
        rm -rf "$PAYLOAD_DIR"
    fi
}
trap cleanup_payload EXIT

if (( SKIP_PAYLOAD )); then
    warn "--no-payload set — the ISO will NOT contain /root/arch-setup."
else
    log "staging repo into $PAYLOAD_DIR..."
    rm -rf "$PAYLOAD_DIR"
    mkdir -p "$PAYLOAD_DIR"
    # rsync with explicit excludes: keep the payload minimal but complete.
    # We want install.sh, chroot.sh, postinstall.sh, docs, runbook, the
    # autounattend.xml (for reference), and top-level CLAUDE.md. We don't
    # want node_modules, the ~5 GB Windows ISO, the archlinux.iso itself
    # (we ARE the archlinux iso), the build work dir, or git internals.
    rsync -a \
        --exclude='/.git/' \
        --exclude='/node_modules/' \
        --exclude='/assets/' \
        --exclude='/phase-1-iso/airootfs/root/arch-setup/' \
        --exclude='/phase-1-iso/work/' \
        --exclude='/phase-1-iso/out/' \
        --exclude='/tmp-download/' \
        --exclude='/staged-azure-ddns/' \
        --exclude='*.pdf' \
        --exclude='.DS_Store' \
        "$REPO_ROOT/" "$PAYLOAD_DIR/"
    # Size-check — if the payload blew past 200 MB we probably fumbled an
    # exclude and are about to bake the Windows ISO into the live image.
    payload_size_kb=$(du -sk "$PAYLOAD_DIR" | awk '{print $1}')
    log "payload size: $(( payload_size_kb / 1024 )) MB"
    if (( payload_size_kb > 200 * 1024 )); then
        die "payload is $(( payload_size_kb / 1024 )) MB — larger than the 200 MB sanity bound. Check rsync excludes in build-custom-iso.sh."
    fi
fi

# ---------- build ----------
if (( DO_CLEAN )) && [[ -d "$WORK_DIR" ]]; then
    log "--clean: removing $WORK_DIR"
    sudo rm -rf "$WORK_DIR"
fi
mkdir -p "$WORK_DIR"

if (( USE_DOCKER )); then
    command -v docker >/dev/null || die "--docker set but docker not installed."
    log "building inside archlinux/archlinux container (--privileged)..."
    # Pull fresh archlinux image each run — it's small and the pacman DB
    # inside needs to be current. The container needs --privileged for
    # loop-mount operations in mkarchiso. Repo is mounted read-write so
    # work/ + out/ persist on the host.
    docker pull archlinux/archlinux:latest >/dev/null
    docker run --rm --privileged \
        -v "$REPO_ROOT:/repo" \
        -w /repo \
        archlinux/archlinux:latest \
        bash -ec '
            pacman -Sy --noconfirm --needed archiso arch-install-scripts
            mkarchiso -v \
                -w /repo/phase-1-iso/work \
                -o /repo/assets \
                /repo/phase-1-iso
        '
else
    command -v mkarchiso >/dev/null || die "mkarchiso not found — install with: sudo pacman -S archiso"
    log "building with host mkarchiso (requires sudo)..."
    sudo mkarchiso -v \
        -w "$WORK_DIR" \
        -o "$OUT_DIR" \
        "$PROFILE_DIR"
fi

# ---------- report ----------
ISO=$(find "$OUT_DIR" -maxdepth 1 -name 'arch-setup-*.iso' -newer "$PROFILE_DIR/profiledef.sh" -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -n1 | cut -d' ' -f2- || true)
if [[ -n "$ISO" && -f "$ISO" ]]; then
    size_mb=$(( $(stat -c%s "$ISO") / 1024 / 1024 ))
    log "built $(basename "$ISO") (${size_mb} MB) in $OUT_DIR/"
    # SHA256 for later verification. archiso writes this alongside the ISO
    # automatically, but double-check it's there.
    if [[ ! -f "${ISO}.sha256" ]]; then
        ( cd "$OUT_DIR" && sha256sum "$(basename "$ISO")" > "$(basename "$ISO").sha256" )
    fi
else
    die "Build finished but no arch-setup-*.iso found in $OUT_DIR — check mkarchiso output."
fi
