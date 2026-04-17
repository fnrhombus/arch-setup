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

# Extract. The zip contains a single top-level dir matching its basename
# (e.g. ventoy-1.1.12/). Nuke any older extracted ventoy-*/ trees first so we
# don't leave stale boot binaries behind.
$extractedName = [IO.Path]::GetFileNameWithoutExtension($winAsset.name)
Get-ChildItem $assetsDir -Directory -Filter 'ventoy-*' |
    Where-Object { $_.Name -ne $extractedName } |
    ForEach-Object {
        Write-Host "[clean] old Ventoy tree: $($_.Name)"
        Remove-Item -Recurse -Force $_.FullName
    }
$extractedDir = Join-Path $assetsDir $extractedName
if ($Force -or -not (Test-Path (Join-Path $extractedDir 'Ventoy2Disk.exe') -PathType Leaf)) {
    # Probe without full recursion: zip may nest a same-named dir.
    if (Test-Path $extractedDir) { Remove-Item -Recurse -Force $extractedDir }
    Write-Host "[extract] $($winAsset.name)"
    Expand-Archive -Path $zipOut -DestinationPath $assetsDir -Force
} else {
    Write-Host "[skip] $extractedName already extracted"
}

# ---------- Windows 11 ISO (manual) ----------
$win11 = Get-ChildItem $assetsDir -Filter 'Win11_*x64*.iso' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $win11) {
    Write-Warning @"
No Windows 11 ISO found in assets/. Obtain one manually:
  - Fido.ps1  (https://github.com/pbatard/Fido)  -> programmatic MS API
  - Media Creation Tool  (microsoft.com/software-download/windows11)
Drop Win11_*_x64*.iso into assets/ before running phase 1.
"@
}

Write-Host ""
Write-Host "[ok] asset sync complete."
