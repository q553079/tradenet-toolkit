param(
    [string]$TradeNetProfilePath = (Join-Path $PSScriptRoot "TradeNet.SplitRouting.psd1"),
    [string]$TradeNetConfigPath = (Join-Path $PSScriptRoot "mihomo\tradenet-split.yaml"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "mihomo\tradenet-clash-merged.yaml"),
    [switch]$SkipRefreshTradeNetConfig
)

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-PythonCommand {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        return @($py.Source, "-3")
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        return @($python.Source)
    }

    throw "Python launcher not found. Install Python and ensure 'py' or 'python' is on PATH."
}

if (-not $SkipRefreshTradeNetConfig) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "Build-TradeNetMihomoConfig.ps1") -ProfilePath $TradeNetProfilePath -OutputPath $TradeNetConfigPath
    if ($LASTEXITCODE -ne 0) {
        throw "Build-TradeNetMihomoConfig.ps1 failed."
    }
}

if (-not (Test-Path -LiteralPath $TradeNetConfigPath)) {
    throw "TradeNet YAML not found: $TradeNetConfigPath"
}

$pythonScript = Join-Path $PSScriptRoot "Build-TradeNetClashConfig.py"
if (-not (Test-Path -LiteralPath $pythonScript)) {
    throw "Python helper script not found: $pythonScript"
}

$pythonCommand = @(Get-PythonCommand)
$pythonExe = $pythonCommand[0]
$pythonArgs = @()
if ($pythonCommand.Count -gt 1) {
    $pythonArgs = @($pythonCommand[1..($pythonCommand.Count - 1)])
}

& $pythonExe @pythonArgs $pythonScript --tradenet-config $TradeNetConfigPath --output $OutputPath
if ($LASTEXITCODE -ne 0) {
    throw "Build-TradeNetClashConfig.py failed."
}

if (Test-Path -LiteralPath $TradeNetProfilePath) {
    $profile = Import-PowerShellDataFile -Path $TradeNetProfilePath
    $mihomoExe = $profile.MihomoExe
    if ($mihomoExe -and (Test-Path -LiteralPath $mihomoExe)) {
        & $mihomoExe -t -f $OutputPath
        if ($LASTEXITCODE -ne 0) {
            throw "Mihomo validation failed for $OutputPath"
        }
    }
}

Write-Host "Generated pure TradeNet Clash config." -ForegroundColor Green
Write-Host "TradeNet source: $TradeNetConfigPath" -ForegroundColor Gray
Write-Host "Output: $OutputPath" -ForegroundColor Gray
