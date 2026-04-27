# scripts/fetch-assets.ps1
#
# Populate ./assets/ with the latest Arch Linux ISO + Ventoy Windows installer.
# Idempotent: skips files that already exist unless -Force. Called by
# `pnpm restore` (see package.json).
#
# Scope:
#   - Arch Linux ISO (latest) + .sig + sha256sums
#   - Ventoy latest release: windows zip + extracted tree
#   - Windows 11 consumer ISO via Fido (https://github.com/pbatard/Fido):
#     the multi-edition ISO contains Home/Pro/Pro-N/Edu/Workstations;
#     autounattend.xml picks "Windows 11 Pro" from install.wim at install
#     time. On any Fido failure we fall back to manual-download instructions
#     so the pipeline degrades gracefully.

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

# ---------- Windows 11 ISO (via Fido) ----------
# Fido is Pete Batard's (Rufus author) PowerShell scraper for Microsoft's
# session-gated ISO API. We pull -GetUrl out of it, then Invoke-WebRequest
# ourselves so we get the same progress/caching semantics as every other
# asset. On any failure we fall through to manual instructions — Fido does
# occasionally break when MS changes the API, so the path can't be the only
# option.
#
# Canonical on-disk name: Win11_25H2_English_x64_v2.iso. ventoy.json's
# auto_install plugin matches this exact path, so Fido's output is renamed
# to it regardless of the actual release Fido pulled. Bump this + ventoy.json
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
    Write-Host "[info] fetching Windows 11 consumer ISO via Fido (contains Pro — autounattend picks it at install)..."

    $vendorDir = Join-Path $PSScriptRoot 'vendor'
    New-Item -ItemType Directory -Force -Path $vendorDir | Out-Null
    $fidoPath = Join-Path $vendorDir 'Fido.ps1'

    # Cache Fido.ps1 pinned to its latest release tag. Master's HEAD can
    # transiently break when MS flips a header; a tagged release has been
    # tested against current MS endpoints.
    if ($Force -or -not (Test-Path $fidoPath)) {
        try {
            $fidoRel = Invoke-RestMethod 'https://api.github.com/repos/pbatard/Fido/releases/latest' -UseBasicParsing
            $fidoAsset = $fidoRel.assets | Where-Object { $_.name -eq 'Fido.ps1' } | Select-Object -First 1
            if ($fidoAsset) {
                Write-Host "[get ] Fido.ps1 $($fidoRel.tag_name)"
                Invoke-WebRequest -Uri $fidoAsset.browser_download_url -OutFile $fidoPath -UseBasicParsing
            } else {
                # Most Fido releases don't upload Fido.ps1 as an asset; pull
                # from the raw tree at the release tag instead.
                $rawUrl = "https://raw.githubusercontent.com/pbatard/Fido/$($fidoRel.tag_name)/Fido.ps1"
                Write-Host "[get ] Fido.ps1 (raw @ $($fidoRel.tag_name))"
                Invoke-WebRequest -Uri $rawUrl -OutFile $fidoPath -UseBasicParsing
            }
        } catch {
            Write-Host "[warn] Could not fetch Fido.ps1: $_" -ForegroundColor Yellow
        }
    }

    # Ask Fido for just the URL, then pull the ISO ourselves so Invoke-
    # WebRequest's caching + progress apply. -Ed 'Windows 11' is the
    # consumer multi-edition ISO (Home/Pro/Pro N/Edu/Workstations).
    $isoUrl = $null
    if (Test-Path $fidoPath) {
        try {
            $fidoOutput = & $fidoPath -Win 11 -Rel Latest -Arch x64 -Lang English -Ed 'Windows 11' -GetUrl 2>&1
            $isoUrl = $fidoOutput |
                ForEach-Object { [string]$_ } |
                Where-Object { $_ -match '^https?://.*\.iso' } |
                Select-Object -First 1
            if (-not $isoUrl) {
                Write-Host "[warn] Fido returned no URL. Output:" -ForegroundColor Yellow
                $fidoOutput | ForEach-Object { Write-Host "       $_" }
            }
        } catch {
            Write-Host "[warn] Fido threw: $_" -ForegroundColor Yellow
        }
    }

    if ($isoUrl) {
        $isoPath = Join-Path $assetsDir $canonicalIso
        try {
            Write-Host "[get ] $canonicalIso (~5 GB — this is the slow part)"
            Invoke-WebRequest -Uri $isoUrl -OutFile $isoPath -UseBasicParsing
            $isoItem = Get-Item $isoPath
            if ($isoItem.Length -gt 1GB) {
                Write-Host "[ok  ] $canonicalIso ($([math]::Round($isoItem.Length/1GB,1)) GB)"
                $win11ok = $true
            } else {
                Write-Host "[warn] Downloaded ISO is suspiciously small ($($isoItem.Length) bytes) — treating as failure." -ForegroundColor Yellow
                Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Host "[warn] ISO download failed: $_" -ForegroundColor Yellow
        }
    }
}

# ---------- Windows 11 ISO source-hash verify ----------
# assets/Win11_25H2_English_x64_v2.iso.sha256 is checked into git (commit
# 19ed2e4 — Microsoft's authoritative hash from microsoft.com/software-
# download/windows11). Verify the downloaded ISO matches it; if not,
# Fido pulled a wrong/corrupt build.
$win11Iso = Get-ChildItem $assetsDir -Filter 'Win11_*x64*.iso' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($win11Iso) {
    $sumPath = Join-Path $assetsDir "$($win11Iso.Name).sha256"
    if (Test-Path $sumPath) {
        $expectedLine = Get-Content $sumPath | Where-Object { $_ -match "\s+$([regex]::Escape($win11Iso.Name))`$" } | Select-Object -First 1
        if ($expectedLine) {
            $expectedHash = ($expectedLine -split '\s+')[0].ToLower()
            Write-Host "[hash] verifying $($win11Iso.Name) against MS-published SHA256 (~30 s)..."
            $actualHash = (Get-FileHash -Path $win11Iso.FullName -Algorithm SHA256).Hash.ToLower()
            if ($actualHash -ne $expectedHash) {
                Write-Host "[fail] $($win11Iso.Name) SHA256 mismatch:" -ForegroundColor Red
                Write-Host "       expected $expectedHash" -ForegroundColor Red
                Write-Host "       actual   $actualHash"   -ForegroundColor Red
                Write-Host "       ISO does not match the official Microsoft hash. Re-run pnpm restore:force." -ForegroundColor Red
            } else {
                Write-Host "[ok  ] $($win11Iso.Name) matches MS-published SHA256"
            }
        }
    } else {
        Write-Host "[warn] $($win11Iso.Name).sha256 missing — can't verify source ISO" -ForegroundColor Yellow
    }
}

if (-not $win11ok) {
    Write-Host ""
    Write-Host "=================================================================" -ForegroundColor Red
    Write-Host " MANUAL STEP REQUIRED: Windows 11 ISO not found in assets/       " -ForegroundColor Red
    Write-Host "=================================================================" -ForegroundColor Red
    Write-Host @"

Fido either failed to download or returned no URL. Microsoft has likely
changed their ISO API — Pete usually ships a Fido fix within a few days.
In the meantime, download the ISO manually and drop it in assets/.

  1. Get the ISO (any of):
       Fido.ps1            -> https://github.com/pbatard/Fido   (may be fixed by now — re-run pnpm restore to retry)
       Microsoft UI        -> https://www.microsoft.com/software-download/windows11
       Media Creation Tool -> same page, "Create Windows 11 Installation Media"
       UUP dump            -> https://uupdump.net/  (assembles from Windows Update)

  2. Put it in assets/ as $canonicalIso (one of):
       a) copy: copy the .iso into V:\arch-setup@fnrhombus\assets\
       b) symlink (saves ~5 GB of duplication):
            New-Item -ItemType SymbolicLink ``
              -Path   'V:\arch-setup@fnrhombus\assets\$canonicalIso' ``
              -Target 'D:\Users\Tom\Downloads\<whatever-MS-called-it>.iso'
         (symlinks need an admin shell on Windows, or Dev Mode)

  3. Re-run ``pnpm restore`` to re-verify + re-stage the USB.

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
