# scripts/fetch-assets.ps1
#
# Populate ./assets/ with the latest Arch Linux ISO + Ventoy Windows installer.
# Idempotent: skips files that already exist unless -Force. Called by
# `pnpm restore` (see package.json).
#
# Scope:
#   - Arch Linux ISO (latest) + .sig + sha256sums
#   - Ventoy latest release: windows zip + extracted tree
#   - Windows 11 consumer multi-edition ISO via Playwright (delegates to
#     scripts/fetch-win11-hash.mjs --download --update). The .mjs drives the
#     official MS download page and grabs both the SHA-256 and the per-
#     session ISO URL from the same browser context. The multi-edition ISO
#     contains Home/Pro/Pro-N/Edu/Workstations; autounattend.xml picks
#     "Windows 11 Pro" from install.wim at install time. On failure we fall
#     back to manual-download instructions so the pipeline degrades
#     gracefully.
#
#     (Fido — https://github.com/pbatard/Fido — was the previous Win11
#     fetcher until 2026-04-27. Removed because Fido provides no hash
#     retrieval, so a fresh download couldn't be reconciled against our
#     pinned in-git sidecar.)

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
$archIso     = Join-Path $assetsDir 'archlinux-x86_64.iso'
$archSigFile = Join-Path $assetsDir 'archlinux-x86_64.iso.sig'
$archSumFile = Join-Path $assetsDir 'archlinux-sha256sums.txt'
Get-WebFile "$archMirror/archlinux-x86_64.iso"     $archIso
Get-WebFile "$archMirror/archlinux-x86_64.iso.sig" $archSigFile
Get-WebFile "$archMirror/sha256sums.txt"           $archSumFile

# Verify ISO integrity. Without this a truncated/corrupt download silently
# stages onto the USB; the laptop then boots far enough to copy airootfs to
# RAM before failing with "Can't find ext4 filesystem" on loop0 — wasting
# 10+ minutes before the user suspects the ISO. Compare against the
# upstream sha256sums.txt we just downloaded (same mirror, same moment).
$expectedLine = Get-Content $archSumFile | Where-Object { $_ -match '\s+archlinux-x86_64\.iso$' } | Select-Object -First 1
if (-not $expectedLine) {
    throw "Could not find archlinux-x86_64.iso entry in $archSumFile — mirror format changed?"
}
$expectedHash = ($expectedLine -split '\s+')[0].ToLower()
$actualHash   = (Get-FileHash -Path $archIso -Algorithm SHA256).Hash.ToLower()
if ($actualHash -ne $expectedHash) {
    Write-Host "[fail] archlinux-x86_64.iso SHA256 mismatch:" -ForegroundColor Red
    Write-Host "       expected $expectedHash" -ForegroundColor Red
    Write-Host "       actual   $actualHash"   -ForegroundColor Red
    Write-Host "       Deleting the corrupt ISO so the next `pnpm restore` re-downloads." -ForegroundColor Red
    Remove-Item $archIso -Force -ErrorAction SilentlyContinue
    throw "archlinux-x86_64.iso failed SHA256 verification — re-run `pnpm restore`."
}
Write-Host "[ok  ] archlinux-x86_64.iso SHA256 matches upstream"

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

# ---------- Windows 11 ISO (via Playwright-driven MS download) ----------
# Fido was here until 2026-04-27 — replaced by scripts/fetch-win11-hash.mjs
# because Fido provides no hash retrieval API, leaving us unable to tell
# whether a fresh download matched the version our in-git sidecar tracked.
# The Playwright script drives the official MS download page directly,
# scraping the authoritative SHA-256 AND grabbing the per-session ISO URL
# from the same browser context — guarantees the download matches what MS
# is currently shipping.
#
# Canonical on-disk name: Win11_25H2_English_x64_v2.iso. ventoy.json's
# auto_install plugin matches this exact path. Bump this + ventoy.json
# together when Microsoft ships 26H2.
$canonicalIso = 'Win11_25H2_English_x64_v2.iso'
$win11ok = $false

$win11 = Get-ChildItem $assetsDir -Filter 'Win11_*x64*.iso' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($win11 -and -not $Force) {
    # Symlink? Resolve and size-check the target so broken links get caught.
    $actual = if ($win11.LinkType) { Get-Item $win11.Target -ErrorAction SilentlyContinue } else { $win11 }
    if ($actual -and $actual.Length -gt 1GB) {
        Write-Host "[ok  ] Windows 11 ISO present: $($win11.Name) ($([math]::Round($actual.Length/1GB,1)) GB)"
        $win11ok = $true
    }
}

if (-not $win11ok) {
    Write-Host "[info] fetching Windows 11 consumer ISO via fetch-win11-hash.mjs (~5 GB, ~10-30 min)..."
    $fetchScript = Join-Path $PSScriptRoot 'fetch-win11-hash.mjs'
    if (-not (Test-Path $fetchScript)) {
        Write-Host "[fail] $fetchScript missing — repo state is wrong, aborting Win11 fetch." -ForegroundColor Red
    } else {
        # The .mjs script downloads + verifies + updates the sidecar in one
        # pass. Inherits stdout/stderr so the user sees its progress display.
        & node $fetchScript --download --update
        if ($LASTEXITCODE -eq 0) {
            $win11ok = $true
        } else {
            Write-Host "[warn] fetch-win11-hash.mjs exited $LASTEXITCODE — see above for details." -ForegroundColor Yellow
        }
    }
}

# ---------- Windows 11 ISO source-hash verify (soft) ----------
# Verify the ISO in assets/ against the in-git sidecar
# (assets/Win11_*.iso.sha256). When fetch-win11-hash.mjs ran above, this
# is tautologically true — the script wrote the sidecar from the same
# download it just verified. When the ISO was already present (the
# pre-existing-asset path), this catches "is the file on disk what we
# last recorded". Soft warn on mismatch — the user explicitly chose to
# trust whatever ISO is in assets/.
$win11Iso = Get-ChildItem $assetsDir -Filter 'Win11_*x64*.iso' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($win11Iso) {
    $sumPath = Join-Path $assetsDir "$($win11Iso.Name).sha256"
    if (-not (Test-Path $sumPath)) {
        Write-Host "[warn] $($win11Iso.Name).sha256 missing — can't verify source ISO" -ForegroundColor Yellow
    } else {
        $expectedLine = Get-Content $sumPath | Where-Object { $_ -match "\s+$([regex]::Escape($win11Iso.Name))`$" } | Select-Object -First 1
        if ($expectedLine) {
            $expectedHash = ($expectedLine -split '\s+')[0].ToLower()
            Write-Host "[hash] verifying $($win11Iso.Name) against in-git sidecar (~30 s)..."
            $actualHash = (Get-FileHash -Path $win11Iso.FullName -Algorithm SHA256).Hash.ToLower()
            if ($actualHash -ne $expectedHash) {
                Write-Host "[warn] $($win11Iso.Name) doesn't match the in-git sidecar:" -ForegroundColor Yellow
                Write-Host "       expected $expectedHash (in git)" -ForegroundColor Yellow
                Write-Host "       actual   $actualHash"             -ForegroundColor Yellow
                Write-Host ""
                Write-Host "Cross-check against the live MS hash:" -ForegroundColor Yellow
                Write-Host "  pnpm hash:win11" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "If the MS hash matches `$actualHash`:" -ForegroundColor Yellow
                Write-Host "  -> MS rolled to a newer build. Update the sidecar:" -ForegroundColor Yellow
                Write-Host "       pnpm hash:win11:update" -ForegroundColor Cyan
                Write-Host "     git commit it (bump the canonical filename + ventoy.json too" -ForegroundColor Yellow
                Write-Host "     if MS also bumped the version string)." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "If the MS hash matches `$expectedHash`:" -ForegroundColor Yellow
                Write-Host "  -> Your local copy is corrupt. Re-run pnpm restore:force." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "Continuing with the ISO present." -ForegroundColor Yellow
            } else {
                Write-Host "[ok  ] $($win11Iso.Name) matches the in-git sidecar"
            }
        }
    }
}

if (-not $win11ok) {
    Write-Host ""
    Write-Host "=================================================================" -ForegroundColor Red
    Write-Host " MANUAL STEP REQUIRED: Windows 11 ISO not found in assets/       " -ForegroundColor Red
    Write-Host "=================================================================" -ForegroundColor Red
    Write-Host @"

The Playwright path (fetch-win11-hash.mjs) failed — most likely because
``pnpm i`` hasn't run yet (Playwright + Chromium aren't installed) or
Microsoft restructured the download page selectors.

Fixes, in order of likelihood:

  1. ``pnpm i`` + retry: pulls Playwright + Chromium (~150 MB), then
     ``pnpm fetch:win11`` does the download + verify + sidecar in one pass.

  2. ``pnpm hash:win11 -- --debug`` to open a visible Chromium and watch
     which selector failed; report back so we can update the script.

  3. Manual download as a last resort:
       Microsoft UI        -> https://www.microsoft.com/software-download/windows11
       Media Creation Tool -> same page, "Create Windows 11 Installation Media"
       UUP dump            -> https://uupdump.net/  (assembles from Windows Update)

     Drop the ISO in assets/ as $canonicalIso (copy or symlink), then
     re-run ``pnpm restore`` to verify + stage. Click "Verify your download"
     on the MS page and update assets/$canonicalIso.sha256 if it differs.

"@
}

Write-Host "[ok] asset sync complete."

# ---------- Stage onto Ventoy boot medium (USB or internal Netac-Ventoy) ----------
# Chain into stage-ventoy.ps1: copy all ISOs + scripts + docs to the Ventoy
# data partition. The stage script soft-exits (code 2) when no Ventoy medium
# is found, so `pnpm i` never fails just because nothing's plugged in.
$stageScript = Join-Path $PSScriptRoot 'stage-ventoy.ps1'
if (Test-Path $stageScript) {
    Write-Host ""
    Write-Host "[info] running stage-ventoy.ps1 (copies artifacts to Ventoy medium if present)..."
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $stageScript
    $stageExit = $LASTEXITCODE
    if ($stageExit -eq 2) {
        Write-Host "[info] no Ventoy medium detected — skipped staging. Run `pnpm stage` later." -ForegroundColor Cyan
    } elseif ($stageExit -ne 0) {
        throw "stage-ventoy.ps1 failed with exit $stageExit"
    }
}
