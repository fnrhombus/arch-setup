# scripts/probe-rg-adguard.ps1
#
# One-off diagnostic: probe https://msdn.rg-adguard.net/public.php to see
# what hash data we can extract for Win11_25H2_English_x64_v2.iso. Used to
# validate the manual-lookup workflow described in fetch-assets.ps1's
# soft-warn message (when the in-git sidecar drifts from the actual ISO).
#
# Run on the dev machine (any network, doesn't need a Ventoy USB):
#   pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/probe-rg-adguard.ps1
#
# Tries three approaches in order; first one that lands a SHA256 wins:
#   1. GET /public.php — site might render the file table without auth.
#   2. POST /public.php with a search query — typical form-based search.
#   3. files.rg-adguard.net — sister catalogue site, GUID-based browsing.
#
# Output:
#   - Saves raw HTML responses under $PSScriptRoot/probe-out/ for inspection.
#   - Prints any 64-hex SHA256 strings found near the filename.
#
# This is not robust scraping — it's a "what does the site even return"
# probe. Use the output to decide whether stage-time auto-lookup is feasible
# or whether the manual-update-the-sidecar workflow is the right call.

[CmdletBinding()]
param(
    [string]$IsoFilename = 'Win11_25H2_English_x64_v2.iso',
    [string]$SearchTerm  = 'Win11_25H2_English_x64'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$outDir = Join-Path $PSScriptRoot 'probe-out'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# Browser-ish UA — rg-adguard 403s on default IWR UA.
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

function Save-Response {
    param([string]$Name, [string]$Body)
    $path = Join-Path $outDir "$Name.html"
    Set-Content -Path $path -Value $Body -Encoding UTF8
    Write-Host "  saved $path ($($Body.Length) chars)"
}

function Find-Sha256NearFilename {
    param([string]$Body, [string]$Filename)
    # Look for any 64-char hex string that appears within ~500 chars of the
    # filename. Either order — filename followed by hash, or vice versa.
    $hits = @()
    $fnEsc = [regex]::Escape($Filename)
    $patterns = @(
        "$fnEsc[\s\S]{0,500}?([0-9a-fA-F]{64})",
        "([0-9a-fA-F]{64})[\s\S]{0,500}?$fnEsc"
    )
    foreach ($p in $patterns) {
        $matches = [regex]::Matches($Body, $p)
        foreach ($m in $matches) {
            $hits += $m.Groups[1].Value.ToLower()
        }
    }
    return $hits | Select-Object -Unique
}

function Print-AllSha256 {
    param([string]$Body)
    $matches = [regex]::Matches($Body, '\b[0-9a-fA-F]{64}\b')
    if ($matches.Count -eq 0) {
        Write-Host "  (no 64-hex strings in body)" -ForegroundColor DarkGray
        return
    }
    Write-Host "  $($matches.Count) total 64-hex strings in response:"
    $matches | ForEach-Object { $_.Value.ToLower() } | Select-Object -Unique | ForEach-Object {
        Write-Host "    $_"
    }
}

Write-Host ""
Write-Host "================================================================="
Write-Host " Probing rg-adguard for $IsoFilename"
Write-Host "================================================================="

# ---------- 1. GET /public.php (no params) ----------
Write-Host ""
Write-Host "[1] GET https://msdn.rg-adguard.net/public.php" -ForegroundColor Cyan
try {
    $r1 = Invoke-WebRequest -Uri 'https://msdn.rg-adguard.net/public.php' `
        -UserAgent $ua -UseBasicParsing -MaximumRedirection 5
    Write-Host "  HTTP $($r1.StatusCode), $([math]::Round($r1.Content.Length/1KB,1)) KB"
    Save-Response 'msdn-public-get' $r1.Content
    $hits = Find-Sha256NearFilename -Body $r1.Content -Filename $IsoFilename
    if ($hits) {
        Write-Host "  FOUND near filename: $($hits -join ', ')" -ForegroundColor Green
    } else {
        Write-Host "  no SHA256 near $IsoFilename in body"
        Print-AllSha256 -Body $r1.Content
    }
} catch {
    Write-Host "  failed: $_" -ForegroundColor Red
}

# ---------- 2. POST /public.php with search term ----------
Write-Host ""
Write-Host "[2] POST https://msdn.rg-adguard.net/public.php (search=$SearchTerm)" -ForegroundColor Cyan
try {
    $r2 = Invoke-WebRequest -Uri 'https://msdn.rg-adguard.net/public.php' `
        -Method POST `
        -Body @{ search = $SearchTerm } `
        -ContentType 'application/x-www-form-urlencoded' `
        -UserAgent $ua -UseBasicParsing -MaximumRedirection 5
    Write-Host "  HTTP $($r2.StatusCode), $([math]::Round($r2.Content.Length/1KB,1)) KB"
    Save-Response 'msdn-public-post' $r2.Content
    $hits = Find-Sha256NearFilename -Body $r2.Content -Filename $IsoFilename
    if ($hits) {
        Write-Host "  FOUND near filename: $($hits -join ', ')" -ForegroundColor Green
    } else {
        Write-Host "  no SHA256 near $IsoFilename in body"
        Print-AllSha256 -Body $r2.Content
    }
} catch {
    Write-Host "  failed: $_" -ForegroundColor Red
}

# ---------- 3. files.rg-adguard.net root ----------
Write-Host ""
Write-Host "[3] GET https://files.rg-adguard.net" -ForegroundColor Cyan
try {
    $r3 = Invoke-WebRequest -Uri 'https://files.rg-adguard.net' `
        -UserAgent $ua -UseBasicParsing -MaximumRedirection 5
    Write-Host "  HTTP $($r3.StatusCode), $([math]::Round($r3.Content.Length/1KB,1)) KB"
    Save-Response 'files-root' $r3.Content
    $hits = Find-Sha256NearFilename -Body $r3.Content -Filename $IsoFilename
    if ($hits) {
        Write-Host "  FOUND near filename: $($hits -join ', ')" -ForegroundColor Green
    } else {
        Write-Host "  no SHA256 near $IsoFilename in body (root page is probably just navigation)"
    }
} catch {
    Write-Host "  failed: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "================================================================="
Write-Host " Done. Inspect $outDir/*.html for the raw responses."
Write-Host " Look for: form action URLs, hidden inputs, AJAX endpoints in JS,"
Write-Host " or anything that looks like a structured data feed."
Write-Host "================================================================="
