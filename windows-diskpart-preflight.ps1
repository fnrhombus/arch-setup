# windows-diskpart-preflight.ps1
#
# Runs in the windowsPE pass of autounattend.xml, BEFORE diskpart.
# Locates the Samsung SSD 840 PRO 512GB (decisions.md §Q9) by size,
# substitutes its disk number into windows-diskpart.txt, writes the
# substituted script to X:\diskpart-runtime.txt.
#
# Fails loudly (exit 1) if zero OR multiple disks match the expected size —
# never silently clobbers the wrong drive. Netac 128GB is outside the 500-600
# GB window by construction, so it cannot be selected here.
#
# Embed in autounattend.xml as a RunSynchronousCommand that runs BEFORE the
# existing `diskpart.exe /s X:\diskpart.txt ...` call. Update that call to
# read X:\diskpart-runtime.txt instead.

$ErrorActionPreference = 'Stop'

$logPath     = 'X:\preflight.log'
$templatePath = 'X:\windows-diskpart.txt'
$runtimePath = 'X:\diskpart-runtime.txt'

function Log([string]$msg) {
    $line = '{0}  {1}' -f (Get-Date).ToString('s'), $msg
    Add-Content -LiteralPath $logPath -Value $line
    Write-Host $line
}

Log 'Enumerating attached disks:'
$disks = Get-Disk | Sort-Object Number
foreach ($d in $disks) {
    Log ('  #{0}  {1,7:N1} GB  bus={2,-6}  {3}' -f $d.Number, ($d.Size / 1GB), $d.BusType, $d.FriendlyName)
}

$candidates = @($disks | Where-Object { $_.Size -gt 500GB -and $_.Size -lt 600GB })

if ($candidates.Count -eq 0) {
    Log 'FATAL: no disk in 500-600 GB range. Expected Samsung SSD 840 PRO 512GB per decisions.md §Q9.'
    Log 'Check BIOS: SATA should be AHCI, Samsung drive should be detected and cabled.'
    exit 1
}
if ($candidates.Count -gt 1) {
    $nums = ($candidates | ForEach-Object { "#$($_.Number)" }) -join ', '
    Log "FATAL: multiple disks in the 500-600 GB window: $nums. Refuse to guess."
    exit 1
}

$target = $candidates[0]
Log ('Selected disk #{0} ({1}, {2:N1} GB) as Samsung install target.' -f $target.Number, $target.FriendlyName, ($target.Size / 1GB))

if (-not (Test-Path -LiteralPath $templatePath)) {
    Log "FATAL: template not found at $templatePath. Did autounattend stage windows-diskpart.txt?"
    exit 1
}

$body = Get-Content -LiteralPath $templatePath -Raw
$substituted = $body -replace '%DISK%', $target.Number.ToString()

if ($substituted -match '%DISK%') {
    Log 'FATAL: %DISK% token still present after substitution.'
    exit 1
}

Set-Content -LiteralPath $runtimePath -Value $substituted -Encoding ASCII
Log "Wrote $runtimePath. Preflight OK."
