# scripts/stage-usb.ps1
#
# Mirrors every artifact the Ventoy USB needs into its data partition:
#   - Arch + Windows 11 ISOs
#   - autounattend.xml
#   - ventoy/ventoy.json (auto-install plugin config)
#   - phase-2-arch-install/ + phase-3-arch-postinstall/
#   - phase-6-grow-windows.sh
#   - phase-1-windows/winget-import.json (apps autounattend installs at first logon)
#   - docs/ (planning/rationale — decisions.md, autounattend-oobe-patch.md, wsl-setup-lessons.md)
#   - runbook/ (read at the laptop — INSTALL-RUNBOOK.md, phase-3-handoff.md,
#     phase-3.5-hardware-handoff.md, GLOSSARY.md, SURVIVAL.md)
#
# Idempotent: re-running is cheap (robocopy skips unchanged files). -Force
# re-copies everything regardless of size match.
#
# Does NOT delete stale files — that's `scripts/prune-usb.ps1`, invoked
# by `pnpm prune:usb` (and chained after this script by `pnpm stage`).
#
# Auto-detection: finds the Ventoy data partition by its "Ventoy" filesystem
# label, sanity-checks by confirming the ~32 MB VTOYEFI companion partition
# is on the same physical disk. Aborts if the stick looks wrong.
#
# Called by:
#   - `pnpm stage`                         (stage then prune)
#   - `pnpm stage:force`                   (re-copy everything, then prune)
#   - scripts/fetch-assets.ps1 end         (auto, if USB present)

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

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
    Write-Header "No Ventoy USB detected" 'Yellow'
    Write-Host @"

No volume labeled 'Ventoy' was found. Either:
  - The USB isn't plugged in → plug it in and re-run `pnpm stage`.
  - Ventoy2Disk.exe hasn't been run on the stick yet → run it first.
  - You renamed the data partition → rename it back to 'Ventoy', or edit
    this script to match.

This is a soft exit (code 2) so postinstall hooks don't fail when the USB
is absent.

"@ -ForegroundColor Yellow
    exit 2
}

$usb = "$($vol.DriveLetter):\"
Write-Host "[ok  ] Ventoy data partition: $usb ($([math]::Round($vol.Size/1GB,1)) GB)"

# Sanity: the Ventoy install writes a tiny (~32 MB) FAT "VTOYEFI" partition
# on the same disk. If it's missing, the stick is mislabeled, not a Ventoy
# install — aborting prevents silently clobbering the wrong drive.
$part = Get-Partition -DriveLetter $vol.DriveLetter -ErrorAction Stop
$companions = Get-Partition -DiskNumber $part.DiskNumber
$vtoyEfi = $companions | Where-Object { $_.Size -gt 30MB -and $_.Size -lt 40MB }
if (-not $vtoyEfi) {
    Write-Header "Disk $($part.DiskNumber) looks mislabeled" 'Red'
    Write-Host "Found a volume labeled 'Ventoy' at $usb, but its disk has no"   -ForegroundColor Red
    Write-Host "~32 MB VTOYEFI companion partition. That's the Ventoy boot"     -ForegroundColor Red
    Write-Host "partition; without it, this is not a real Ventoy stick."         -ForegroundColor Red
    Write-Host "Bailing so we don't overwrite the wrong drive."                  -ForegroundColor Red
    exit 1
}
Write-Host "[ok  ] VTOYEFI companion present — confirmed Ventoy stick."

# ---------- stage ----------
$assets = Join-Path $repoRoot 'assets'

$rootFiles = @(
    (Join-Path $assets 'archlinux-x86_64.iso'),
    (Join-Path $assets 'archlinux-x86_64.iso.sig'),
    (Join-Path $assets 'archlinux-sha256sums.txt'),
    (Join-Path $assets 'Win11_25H2_English_x64_v2.iso'),
    (Join-Path $repoRoot 'autounattend.xml'),
    (Join-Path $repoRoot 'CLAUDE.md'),
    (Join-Path $repoRoot 'phase-6-grow-windows.sh')
)

# USB mirrors the repo layout: docs/ (planning/rationale) + runbook/
# (what the user reads at the laptop). Keeps `runbook/INSTALL-RUNBOOK.md`
# referenceable by the same relative path inside the repo and on the stick.
$dirs = @('ventoy', 'phase-1-windows', 'phase-2-arch-install', 'phase-3-arch-postinstall', 'docs', 'runbook')

foreach ($src in $rootFiles) {
    $leaf = Split-Path -Leaf $src
    if (-not (Test-Path $src)) {
        Write-Host "[miss] $leaf (source missing — run `pnpm restore`?)" -ForegroundColor Yellow
        continue
    }
    $dest = Join-Path $usb $leaf
    if ((-not $Force) -and (Test-Path $dest) -and ((Get-Item $src).Length -eq (Get-Item $dest).Length)) {
        Write-Host "[skip] $leaf (same size)"
        continue
    }
    $sizeMB = [math]::Round((Get-Item $src).Length / 1MB, 0)
    Write-Host "[copy] $leaf ($sizeMB MB)"
    Copy-Item -Path $src -Destination $dest -Force
}

foreach ($d in $dirs) {
    $src = Join-Path $repoRoot $d
    if (-not (Test-Path $src)) {
        Write-Host "[miss] $d\ (source missing)" -ForegroundColor Yellow
        continue
    }
    $dest = Join-Path $usb $d
    # /E   : copy subdirs incl. empty
    # /XO  : skip files in dest that are newer or same (idempotent)
    # /FFT : FAT-timestamp granularity (USB is exFAT — avoids false "newer" matches)
    # /NFL /NDL /NJH /NJS /NP /NC : quiet output (just the counts, no per-file spam)
    # (No /PURGE — deletion is delegated to prune-usb.ps1.)
    $flags = @('/E', '/FFT', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/NC')
    if (-not $Force) { $flags += '/XO' }
    Write-Host "[sync] $d\"
    & robocopy $src $dest @flags | Out-Null
    # robocopy exit codes: 0-7 = success variants, 8+ = real error.
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed for $d\ (exit $LASTEXITCODE)"
    }
}

Write-Header "Ventoy USB staged at $usb"
Write-Host "Boot this stick on the Dell 7786 to start phase 1 (Windows install)." -ForegroundColor Green
Write-Host ""
