# scripts/prune-usb.ps1
#
# Removes stale files from the Ventoy USB that no longer exist in the repo.
# Kept as its own script so the copy (`pnpm stage`) and the delete (this
# script) are separate, reviewable operations — and so `pnpm prune:usb`
# can be run standalone after the repo layout changes.
#
# Logic:
#   - In the 6 repo-managed subdirs (ventoy/, phase-*/, docs/, runbook/):
#     anything on the USB that isn't in the repo source is deleted. These
#     dirs are wholly repo-owned, so mirror-style pruning is safe. Empty
#     subdirectories left behind are also removed.
#   - At the USB root: files not in the current stage allowlist are
#     deleted, EXCEPT `.iso` files (likely user-added Ventoy bootables)
#     and unknown subdirectories (never recursively nuke a tree we don't
#     recognise). Those are reported and left alone.
#
# The allowlist ($rootFiles / $dirs) must stay in sync with the matching
# arrays in scripts/stage-usb.ps1 — if you add a new file to staging,
# add it here too or the next prune will delete it.
#
# Called by:
#   - `pnpm prune:usb`  (manual, standalone)
#   - `pnpm stage`      (chained after stage-usb.ps1)

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Write-Header([string]$text, [string]$color = 'Green') {
    Write-Host ""
    Write-Host "=================================================================" -ForegroundColor $color
    Write-Host " $text" -ForegroundColor $color
    Write-Host "=================================================================" -ForegroundColor $color
}

# ---------- locate the Ventoy data partition ----------
$vol = Get-Volume -ErrorAction SilentlyContinue |
    Where-Object { $_.FileSystemLabel -eq 'Ventoy' -and $_.DriveLetter } |
    Select-Object -First 1

if (-not $vol) {
    Write-Host "[skip] No Ventoy USB detected — nothing to prune." -ForegroundColor Yellow
    exit 2
}

$usb = "$($vol.DriveLetter):\"

# Sanity: the Ventoy install writes a tiny (~32 MB) FAT "VTOYEFI" partition
# on the same disk. If it's missing, the stick is mislabeled, not a Ventoy
# install — abort before we delete anything from the wrong drive.
$part = Get-Partition -DriveLetter $vol.DriveLetter -ErrorAction Stop
$companions = Get-Partition -DiskNumber $part.DiskNumber
$vtoyEfi = $companions | Where-Object { $_.Size -gt 30MB -and $_.Size -lt 40MB }
if (-not $vtoyEfi) {
    Write-Header "Disk $($part.DiskNumber) looks mislabeled" 'Red'
    Write-Host "Found a volume labeled 'Ventoy' at $usb, but its disk has no"   -ForegroundColor Red
    Write-Host "~32 MB VTOYEFI companion partition. Bailing so we don't"         -ForegroundColor Red
    Write-Host "delete from the wrong drive."                                    -ForegroundColor Red
    exit 1
}
Write-Host "[ok  ] Ventoy data partition: $usb (VTOYEFI companion confirmed)"

# ---------- allowlist (must match stage-usb.ps1) ----------
$rootFiles = @(
    'archlinux-x86_64.iso',
    'archlinux-x86_64.iso.sig',
    'archlinux-sha256sums.txt',
    'Win11_25H2_English_x64_v2.iso',
    'autounattend.xml',
    'CLAUDE.md',
    'phase-6-grow-windows.sh'
)
$dirs = @('ventoy', 'phase-1-windows', 'phase-2-arch-install', 'phase-3-arch-postinstall', 'docs', 'runbook')

$knownRoot = @{}
foreach ($n in $rootFiles) { $knownRoot[$n.ToLower()] = $true }
foreach ($n in $dirs)      { $knownRoot[$n.ToLower()] = $true }
$knownRoot['system volume information'] = $true  # OS metadata (NTFS/exFAT), never touch

$repoRoot = Split-Path -Parent $PSScriptRoot

# ---------- prune managed subdirs ----------
$subdirPruned = 0
foreach ($d in $dirs) {
    $src = Join-Path $repoRoot $d
    $dst = Join-Path $usb $d
    if (-not (Test-Path $dst)) { continue }

    $srcRel = @{}
    if (Test-Path $src) {
        Get-ChildItem -Path $src -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $srcRel[$_.FullName.Substring($src.Length).TrimStart('\').ToLower()] = $true
        }
    }

    Get-ChildItem -Path $dst -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($dst.Length).TrimStart('\').ToLower()
        if (-not $srcRel.ContainsKey($rel)) {
            Remove-Item -LiteralPath $_.FullName -Force
            $display = $_.FullName.Substring($dst.Length).TrimStart('\')
            Write-Host "[prune] $d\$display"
            $subdirPruned++
        }
    }

    # Clean empty dirs that the prune (or prior stage drift) left behind.
    # Walk deepest-first so parents are seen as empty only after their
    # children have been removed.
    $emptyDirs = Get-ChildItem -Path $dst -Recurse -Directory -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending
    foreach ($dir in $emptyDirs) {
        if (-not (Get-ChildItem -Path $dir.FullName -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $dir.FullName -Force
            $display = $dir.FullName.Substring($dst.Length).TrimStart('\')
            Write-Host "[prune] $d\$display\  (empty dir)"
        }
    }
}

# ---------- prune root extras ----------
$rootPruned = 0
Get-ChildItem -Path $usb -Force -ErrorAction SilentlyContinue | ForEach-Object {
    if ($knownRoot.ContainsKey($_.Name.ToLower())) { return }
    if ($_.PSIsContainer) {
        Write-Host "[keep ] $($_.Name)\ (unknown directory — not auto-pruned)" -ForegroundColor Yellow
        return
    }
    if ($_.Extension -eq '.iso') {
        Write-Host "[keep ] $($_.Name) (unknown .iso — likely a user-added Ventoy bootable)" -ForegroundColor Cyan
        return
    }
    Remove-Item -LiteralPath $_.FullName -Force
    Write-Host "[prune] $($_.Name)"
    $rootPruned++
}

Write-Header ("Prune complete: {0} subdir file(s), {1} root file(s)" -f $subdirPruned, $rootPruned)
