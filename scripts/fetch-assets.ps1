# scripts/fetch-assets.ps1
#
# Populate ./assets/ with the latest Arch Linux ISO + Ventoy Windows installer.
# Idempotent: skips files that already exist unless -Force. Called by
# `pnpm restore` (see package.json).
#
# Scope:
#   - Arch Linux ISO (latest) + .sig + sha256sums
#   - Ventoy latest release: windows zip + extracted tree
#   - Windows 11 consumer multi-edition ISO via Fido
#     (https://github.com/pbatard/Fido). The multi-edition ISO contains
#     Home/Pro/Pro-N/Edu/Workstations; autounattend.xml picks "Windows
#     11 Pro" from install.wim at install time. -Rel Latest tracks the
#     current MS release (25H2 today; will roll forward as MS ships).
#     On Fido failure falls back to manual-download instructions.
#
#     We do NOT verify a hash on the Win11 ISO — MS doesn't ship one in
#     any auto-fetchable feed and Fido doesn't return one. Trust Fido.

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
# -Win 11 + -Rel Latest + -Ed 'Windows 11' = current Win 11 multi-edition
# consumer ISO (Home/Pro/Pro-N/Edu/Workstations). autounattend.xml picks
# "Windows 11 Pro" from install.wim at install time. -Rel literal version
# strings ('25H2', '24H2', etc.) aren't reliably accepted across Fido
# versions — Latest is the safe value, MS rolling forward is what we want
# anyway.
#
# Canonical on-disk name: Win11_25H2_English_x64_v2.iso. ventoy.json's
# auto_install plugin matches this exact path, so Fido's output is renamed
# to it regardless of the actual filename Fido downloaded with. Bump this
# + ventoy.json together when MS ships 26H2.
#
# No hash verification — Fido provides no hash, MS doesn't ship one in any
# auto-fetchable feed. Trust Fido.
$canonicalIso = 'Win11_25H2_English_x64_v2.iso'
$win11ok = $false

$win11 = Get-ChildItem $assetsDir -Filter 'Win11_*x64*.iso' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($win11 -and -not $Force) {
    # Symlink? Resolve and size-check the target so broken links get caught.
    $actual = if ($win11.LinkType) { Get-Item $win11.Target -ErrorAction SilentlyContinue } else { $win11 }
    if ($actual -and $actual.Length -gt 1GB) {
        # If there's a sidecar (e.g. user dropped in their own ISO and
        # recorded its hash, or a previous run wrote one), verify against
        # it. Match means "use this, it's exactly what we expect" — strongest
        # possible reason to skip Fido. Mismatch is logged loudly but does
        # NOT trigger a redownload (`-Force` is the explicit "wipe what's
        # there and start over" knob); the user may have intentionally
        # swapped in a different build.
        $sidecarPath = "$($actual.FullName).sha256"
        if (Test-Path $sidecarPath) {
            $expectedLine = Get-Content $sidecarPath |
                Where-Object { $_ -match "\s+$([regex]::Escape($win11.Name))`$" } |
                Select-Object -First 1
            if ($expectedLine) {
                $expectedHash = ($expectedLine -split '\s+')[0].ToLower()
                Write-Host "[hash] verifying $($win11.Name) against sidecar (~30 s)..."
                $actualHash = (Get-FileHash -Path $actual.FullName -Algorithm SHA256).Hash.ToLower()
                if ($actualHash -eq $expectedHash) {
                    Write-Host "[ok  ] Windows 11 ISO present + sidecar hash matches: $($win11.Name) ($([math]::Round($actual.Length/1GB,1)) GB)"
                } else {
                    Write-Host "[warn] $($win11.Name) hash differs from sidecar:" -ForegroundColor Yellow
                    Write-Host "       expected $expectedHash" -ForegroundColor Yellow
                    Write-Host "       actual   $actualHash"   -ForegroundColor Yellow
                    Write-Host "       Using the ISO present (not overwriting). -Force to redownload." -ForegroundColor Yellow
                }
            } else {
                Write-Host "[ok  ] Windows 11 ISO present (sidecar exists but no entry for $($win11.Name)): $($win11.Name) ($([math]::Round($actual.Length/1GB,1)) GB)"
            }
        } else {
            Write-Host "[ok  ] Windows 11 ISO present (no sidecar): $($win11.Name) ($([math]::Round($actual.Length/1GB,1)) GB)"
        }
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
    # WebRequest's caching + progress apply.
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

  3. Re-run ``pnpm restore`` to re-stage.

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
