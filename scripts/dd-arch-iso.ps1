#!/usr/bin/env pwsh
# One-shot: dd the Arch ISO onto a USB stick by disk number.
# Admin required.
param(
    [Parameter(Mandatory)][int]$DiskNumber,
    [Parameter(Mandatory)][string]$IsoPath
)

$ErrorActionPreference = 'Stop'

$disk = Get-Disk -Number $DiskNumber
if ($disk.BusType -ne 'USB') {
    throw "Disk $DiskNumber is BusType=$($disk.BusType), not USB. Refusing to touch."
}
if (-not (Test-Path $IsoPath)) { throw "ISO not found: $IsoPath" }

$isoSize = (Get-Item $IsoPath).Length
$stickSize = $disk.Size
if ($isoSize -gt $stickSize) { throw "ISO ($isoSize) larger than stick ($stickSize)." }

Write-Host "Target: Disk $DiskNumber, $($disk.FriendlyName), $([math]::Round($stickSize/1GB,2)) GB"
Write-Host "Source: $IsoPath ($([math]::Round($isoSize/1MB,1)) MB)"

Write-Host "[1/2] Clearing partition table (and any existing volumes)..."
try {
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
} catch {
    # Disk may already be RAW (e.g. after a prior dd) — nothing to clear.
    Write-Host "  (Clear-Disk: $($_.Exception.Message) — continuing)"
}
Start-Sleep -Milliseconds 500

Write-Host "[2/2] Raw-writing ISO bytes..."
$src  = [System.IO.File]::OpenRead($IsoPath)
$dest = [System.IO.File]::Open("\\.\PhysicalDrive$DiskNumber", 'Open', 'Write', 'ReadWrite')

$bufSize = 4MB
$buf = New-Object byte[] $bufSize
$written = 0L
$lastReport = [DateTime]::Now
try {
    while (($read = $src.Read($buf, 0, $bufSize)) -gt 0) {
        $dest.Write($buf, 0, $read)
        $written += $read
        if (([DateTime]::Now - $lastReport).TotalSeconds -ge 2) {
            $pct = [math]::Round($written * 100.0 / $isoSize, 1)
            Write-Host ("  ... {0} MB / {1} MB  ({2}%)" -f ([math]::Round($written/1MB,1)), ([math]::Round($isoSize/1MB,1)), $pct)
            $lastReport = [DateTime]::Now
        }
    }
    $dest.Flush()
}
finally {
    $dest.Dispose()
    $src.Dispose()
}

Write-Host "Wrote $written bytes."

Start-Sleep -Seconds 2
Update-HostStorageCache

Write-Host ""
Write-Host "=== Result: partitions on disk $DiskNumber ==="
Get-Partition -DiskNumber $DiskNumber | Format-Table PartitionNumber, Type, @{N='SizeMB';E={[math]::Round($_.Size/1MB,1)}}, DriveLetter, IsActive -AutoSize
