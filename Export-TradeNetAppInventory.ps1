param(
    [string]$OutputPath = (Join-Path $PSScriptRoot ("state\app-inventory_{0}.json" -f (Get-Date -Format "yyyy-MM-dd_HH-mm-ss")))
)

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$patterns = 'chrome|msedge|firefox|OFT\.Platform|atas|steam|wegame|rith|rtrader|rithmic|bookmap|cqg|mihomo|clash'
$roots = @(
    "C:\Program Files",
    "C:\Program Files (x86)",
    "D:\",
    "D:\Program Files (x86)"
)

$dir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$processes = @(
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match $patterns } |
        Select-Object ProcessName, Id, Path
)

$tcp = @(
    Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        ForEach-Object {
            $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -match $patterns) {
                [pscustomobject]@{
                    ProcessName   = $proc.ProcessName
                    PID           = $_.OwningProcess
                    LocalAddress  = $_.LocalAddress
                    LocalPort     = $_.LocalPort
                    RemoteAddress = $_.RemoteAddress
                    RemotePort    = $_.RemotePort
                }
            }
        }
)

$udp = @(
    Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
        ForEach-Object {
            $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -match $patterns) {
                [pscustomobject]@{
                    ProcessName  = $proc.ProcessName
                    PID          = $_.OwningProcess
                    LocalAddress = $_.LocalAddress
                    LocalPort    = $_.LocalPort
                }
            }
        }
)

$programDirs = @(
    foreach ($root in $roots) {
        if (Test-Path $root) {
            Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'ATAS|Steam|WeGame|Rith|RTrader|Rithmic|Bookmap|CQG|Clash|Mihomo' } |
                Select-Object -ExpandProperty FullName
        }
    }
)

$result = [pscustomobject]@{
    GeneratedAt = (Get-Date).ToString("o")
    Processes   = $processes
    Tcp         = $tcp
    Udp         = $udp
    ProgramDirs = $programDirs
}

$result | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Host "Inventory written to $OutputPath" -ForegroundColor Green
Write-Host ""
Write-Host "Processes:" -ForegroundColor Cyan
$processes | Sort-Object ProcessName, Id | Format-Table -AutoSize
Write-Host ""
Write-Host "Established TCP:" -ForegroundColor Cyan
$tcp | Sort-Object ProcessName, RemoteAddress, RemotePort | Format-Table -AutoSize
