# scripts/fetch-assets.ps1
#
# Populate ./assets/ with the latest Arch Linux ISO + Ventoy Windows installer.
# Idempotent: skips files that already exist unless -Force. Called by
# `pnpm restore` (see package.json).
#
# Scope:
#   - Arch Linux ISO (latest) + .sig + sha256sums
#   - Ventoy latest release: windows zip + extracted tree
#
# Out of scope (requires manual download):
#   - Windows 11 ISO. Microsoft gates the ISO behind a per-session API.
#     Use Fido (https://github.com/pbatard/Fido) or the Media Creation Tool.
#     The script warns if no Win11_*x64*.iso is present at the end.

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is 10x faster without progress UI

$repoRoot  = Split-Path -Parent $PSScriptRoot
$assetsDir = Join-Path $repoRoot 'assets'
New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null

function Get-WebFile {
    param([string]$Url, [string]$OutFile)
    if (-not $Force -and (Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 0) {
        Write-Host "[skip] $(Split-Path -Leaf $OutFile) already present"
        return
    }
    Write-Host "[get ] $Url"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

# ---------- Arch Linux ISO (latest) ----------
# rackspace mirror keeps a stable /latest/ path with dated + undated symlinks.
$archMirror = 'https://mirror.rackspace.com/archlinux/iso/latest'
Get-WebFile "$archMirror/archlinux-x86_64.iso"     (Join-Path $assetsDir 'archlinux-x86_64.iso')
Get-WebFile "$archMirror/archlinux-x86_64.iso.sig" (Join-Path $assetsDir 'archlinux-x86_64.iso.sig')
Get-WebFile "$archMirror/sha256sums.txt"           (Join-Path $assetsDir 'archlinux-sha256sums.txt')

# ---------- Ventoy (latest release) ----------
Write-Host "[info] querying Ventoy latest release..."
$rel = Invoke-RestMethod 'https://api.github.com/repos/ventoy/Ventoy/releases/latest' -UseBasicParsing
$winAsset = $rel.assets | Where-Object { $_.name -match '^ventoy-.+-windows\.zip$' } | Select-Object -First 1
if (-not $winAsset) { throw "No ventoy-*-windows.zip in latest release ($($rel.tag_name))." }
$zipOut = Join-Path $assetsDir $winAsset.name
Get-WebFile $winAsset.browser_download_url $zipOut

# Extract. The zip contains a single top-level dir whose name is the
# release tag without the "-windows" suffix (e.g. ventoy-1.1.12/). Clean
# any older extracted ventoy-X.Y.Z/ trees first so we don't leave stale
# boot binaries behind.
$extractedName = $winAsset.name -replace '-windows\.zip$',''
Get-ChildItem $assetsDir -Directory -Filter 'ventoy-*' |
    Where-Object { $_.Name -ne $extractedName } |
    ForEach-Object {
        Write-Host "[clean] old Ventoy tree: $($_.Name)"
        Remove-Item -Recurse -Force $_.FullName
    }
$extractedDir = Join-Path $assetsDir $extractedName
if ($Force -or -not (Test-Path (Join-Path $extractedDir 'Ventoy2Disk.exe') -PathType Leaf)) {
    if (Test-Path $extractedDir) { Remove-Item -Recurse -Force $extractedDir }
    Write-Host "[extract] $($winAsset.name)"
    Expand-Archive -Path $zipOut -DestinationPath $assetsDir -Force
} else {
    Write-Host "[skip] $extractedName already extracted"
}

# ---------- Windows 11 ISO (manual check only — no auto-download) ----------
# Microsoft gates the Win11 ISO behind a per-session API that changes
# without notice; auto-downloading it is inherently fragile. Instead:
# check that a usable ISO exists in assets/ (either a real file or a
# symlink to a real file in Downloads) and print actionable instructions
# if not.
$win11ok = $false
$win11 = Get-ChildItem $assetsDir -Filter 'Win11_*x64*.iso' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($win11) {
    # Symlink? Resolve and size-check the target so broken links get caught.
    $actual = if ($win11.LinkType) { Get-Item $win11.Target -ErrorAction SilentlyContinue } else { $win11 }
    if ($actual -and $actual.Length -gt 1GB) {
        Write-Host "[ok  ] Windows 11 ISO present: $($win11.Name) ($([math]::Round($actual.Length/1GB,1)) GB)"
        $win11ok = $true
    }
}

if (-not $win11ok) {
    Write-Host ""
    Write-Host "=================================================================" -ForegroundColor Red
    Write-Host " MANUAL STEP REQUIRED: Windows 11 ISO not found in assets/       " -ForegroundColor Red
    Write-Host "=================================================================" -ForegroundColor Red
    Write-Host @"

Microsoft does not publish a stable direct-download URL for the Win11
ISO, so this script cannot fetch it. Download it yourself and place
(or symlink) it into assets/ before running phase 1.

  1. Get the ISO:
       Fido.ps1  -> https://github.com/pbatard/Fido
       Media Creation Tool -> https://www.microsoft.com/software-download/windows11
       UUP dump  -> https://uupdump.net/

  2. Put it in assets/ (one of):
       a) copy: copy the .iso into V:\arch-setup@fnrhombus\assets\
       b) symlink (saves 8 GB of duplication):
            New-Item -ItemType SymbolicLink ``
              -Path   'V:\arch-setup@fnrhombus\assets\Win11_25H2_English_x64_v2.iso' ``
              -Target 'D:\Users\Tom\Downloads\Win11_25H2_English_x64_v2.iso'
         (symlinks require an admin shell on Windows, or Dev Mode)

  3. Re-run `pnpm restore` to re-verify.

"@
}

Write-Host "[ok] asset sync complete."

# ---------- Stage onto Ventoy USB (if plugged in) ----------
# Chain into stage-usb.ps1: copy all ISOs + scripts + docs to the Ventoy
# data partition. The stage script soft-exits (code 2) when no Ventoy USB
# is found, so `pnpm i` never fails just because the stick isn't plugged in.
$stageScript = Join-Path $PSScriptRoot 'stage-usb.ps1'
if (Test-Path $stageScript) {
    Write-Host ""
    Write-Host "[info] running stage-usb.ps1 (copies artifacts to Ventoy USB if present)..."
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $stageScript
    $stageExit = $LASTEXITCODE
    if ($stageExit -eq 2) {
        Write-Host "[info] no Ventoy USB detected — skipped USB staging. Run `pnpm stage` later." -ForegroundColor Cyan
    } elseif ($stageExit -ne 0) {
        throw "stage-usb.ps1 failed with exit $stageExit"
    }
}
