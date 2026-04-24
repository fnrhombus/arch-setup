# scripts/build-custom-iso.ps1
#
# Windows-side wrapper around scripts/build-custom-iso.sh. Delegates the
# real work to the `archlinux` WSL distro (the same one phase 0.5 uses
# for the CLI shakedown — see wsl-setup.sh / wsl-cli-test.sh).
#
# Why WSL and not native Windows: mkarchiso needs a real Linux host with
# pacstrap, loop-mount, and squashfs tooling. None of that runs on pure
# Windows. WSL2 is a real Linux kernel, so it works — but mkarchiso also
# needs root + loop-dev + namespace caps that default WSL sometimes lacks.
# If WSL-direct fails, pass -Docker to run inside a privileged
# archlinux/archlinux container instead; that's the hardened fallback.
#
# Usage:
#   pwsh scripts/build-custom-iso.ps1           # default: WSL direct
#   pwsh scripts/build-custom-iso.ps1 -Docker   # container fallback
#   pwsh scripts/build-custom-iso.ps1 -Clean    # wipe work/ first
#
# The underlying bash script (scripts/build-custom-iso.sh) does the actual
# payload staging + mkarchiso invocation. This wrapper just chooses the
# right shell to run it in.

[CmdletBinding()]
param(
    [switch]$Docker,
    [switch]$Clean,
    [switch]$NoPayload,
    [string]$WslDistro = 'archlinux'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

# Build the arg list the bash script expects.
$bashArgs = @()
if ($Docker)    { $bashArgs += '--docker' }
if ($Clean)     { $bashArgs += '--clean' }
if ($NoPayload) { $bashArgs += '--no-payload' }

# Translate Windows repo path to a WSL path. wslpath -a resolves to the
# /mnt/<drive>/... form that WSL uses for Windows filesystems. Running
# the build there is fine but noticeably slower than running from /home
# inside WSL — if build times get painful, consider `git clone`ing the
# repo into the WSL filesystem instead.
#
# For Docker mode, we still drive it through WSL (Docker Desktop's
# engine is reachable from WSL anyway). The bash script inside WSL runs
# `docker run ...` which Docker Desktop brokers back to the host.

function Invoke-Wsl {
    param([string[]]$Args)
    Write-Host "[iso] wsl -d $WslDistro -- $($Args -join ' ')"
    & wsl.exe -d $WslDistro -- @Args
    if ($LASTEXITCODE -ne 0) {
        throw "WSL exit $LASTEXITCODE"
    }
}

# Sanity: is the distro available?
$distroList = & wsl.exe --list --quiet 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "wsl.exe not available — is WSL installed?"
}
# wsl --list --quiet returns UTF-16-LE; PowerShell usually copes, but the
# occasional null-char shows up. Trim aggressively.
$found = $false
foreach ($line in $distroList) {
    if ($line -replace "`0","" -replace '\s','' -eq $WslDistro) { $found = $true }
}
if (-not $found) {
    Write-Host "[warn] WSL distro '$WslDistro' not found. Available distros:" -ForegroundColor Yellow
    & wsl.exe --list --verbose
    throw "Install an Arch WSL distro first (see docs/wsl-setup-lessons.md)."
}

$wslRepo = & wsl.exe -d $WslDistro -- wslpath -a "$repoRoot"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to translate $repoRoot to a WSL path."
}
$wslRepo = ($wslRepo -replace "`r","").Trim()
Write-Host "[iso] repo at WSL path: $wslRepo"

$cmd = "cd '$wslRepo' && bash scripts/build-custom-iso.sh $($bashArgs -join ' ')"
Invoke-Wsl @('bash','-ec',$cmd)

# Locate the produced ISO on the Windows side.
$assets = Join-Path $repoRoot 'assets'
$iso = Get-ChildItem $assets -Filter 'arch-setup-*.iso' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($iso) {
    $sizeMB = [math]::Round($iso.Length / 1MB, 0)
    Write-Host ""
    Write-Host "[ok  ] produced $($iso.Name) (${sizeMB} MB)" -ForegroundColor Green
    Write-Host "       at $($iso.FullName)" -ForegroundColor Green
} else {
    Write-Host "[warn] build finished but no arch-setup-*.iso found in $assets" -ForegroundColor Yellow
}
