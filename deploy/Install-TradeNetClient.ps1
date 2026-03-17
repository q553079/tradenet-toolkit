param(
    [string]$ProfilePath = (Join-Path (Split-Path $PSScriptRoot -Parent) "TradeNet.Deployment.psd1"),
    [string]$ServerArtifactPath = (Join-Path (Split-Path $PSScriptRoot -Parent) "artifacts\tradenet-client-artifact.json")
)

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Quote-Psd1String {
    param([string]$Value)
    return "'{0}'" -f ($Value -replace "'", "''")
}

function ConvertTo-Psd1Literal {
    param([Parameter(Mandatory)]$Value, [int]$Indent = 0)

    $prefix = (" " * $Indent)

    if ($Value -is [System.Collections.IDictionary]) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("@{")
        foreach ($key in $Value.Keys) {
            $literal = ConvertTo-Psd1Literal -Value $Value[$key] -Indent ($Indent + 4)
            $literalLines = @($literal -split "`r?`n")
            $lines.Add(("{0}    {1} = {2}" -f $prefix, $key, $literalLines[0]))
            if ($literalLines.Count -gt 1) {
                foreach ($line in $literalLines[1..($literalLines.Count - 1)]) {
                    $lines.Add($line)
                }
            }
        }
        $lines.Add($prefix + "}")
        return [string]::Join([Environment]::NewLine, $lines)
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("@(")
        foreach ($item in $Value) {
            $literal = ConvertTo-Psd1Literal -Value $item -Indent ($Indent + 4)
            $literalLines = @($literal -split "`r?`n")
            $lines.Add(("{0}    {1}" -f $prefix, $literalLines[0]))
            if ($literalLines.Count -gt 1) {
                foreach ($line in $literalLines[1..($literalLines.Count - 1)]) {
                    $lines.Add($line)
                }
            }
        }
        $lines.Add(("{0})" -f $prefix))
        return [string]::Join([Environment]::NewLine, $lines)
    }

    if ($Value -is [bool]) {
        return $(if ($Value) { '$true' } else { '$false' })
    }

    if ($null -eq $Value) {
        return '$null'
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
        return [string]$Value
    }

    return Quote-Psd1String -Value ([string]$Value)
}

if (-not (Test-Path -LiteralPath $ProfilePath)) {
    throw "Deployment profile not found: $ProfilePath"
}

if (-not (Test-Path -LiteralPath $ServerArtifactPath)) {
    throw "Server artifact not found: $ServerArtifactPath"
}

$profile = Import-PowerShellDataFile -Path $ProfilePath
$serverArtifact = Get-Content -Raw -Path $ServerArtifactPath | ConvertFrom-Json
$clientDeployment = $profile.Client.Deployment
$installWatchdogTask = [bool]$clientDeployment["InstallWatchdogTask"]
$replaceWatchdogTask = if ($null -eq $clientDeployment["ReplaceWatchdogTask"]) { $true } else { [bool]$clientDeployment["ReplaceWatchdogTask"] }
$startWatchdogAfterInstall = if ($null -eq $clientDeployment["StartWatchdogAfterInstall"]) { $true } else { [bool]$clientDeployment["StartWatchdogAfterInstall"] }
$watchdogTaskName = if ($clientDeployment["WatchdogTaskName"]) { [string]$clientDeployment["WatchdogTaskName"] } else { "TradeNet-Watchdog" }
$watchdogStartupDelaySeconds = if ($null -ne $clientDeployment["WatchdogStartupDelaySeconds"]) { [int]$clientDeployment["WatchdogStartupDelaySeconds"] } else { 20 }
$watchdogRestartIntervalMinutes = if ($null -ne $clientDeployment["WatchdogRestartIntervalMinutes"]) { [int]$clientDeployment["WatchdogRestartIntervalMinutes"] } else { 1 }
$watchdogRestartCount = if ($null -ne $clientDeployment["WatchdogRestartCount"]) { [int]$clientDeployment["WatchdogRestartCount"] } else { 999 }
$watchdogIgnoreManualStopOnBoot = if ($null -eq $clientDeployment["IgnoreManualStopOnBoot"]) { $true } else { [bool]$clientDeployment["IgnoreManualStopOnBoot"] }
$repoRoot = Split-Path $PSScriptRoot -Parent
$artifactsDir = Join-Path $repoRoot "artifacts"
if (-not (Test-Path -LiteralPath $artifactsDir)) {
    New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null
}

$preflightReport = Join-Path $artifactsDir "client-preflight.txt"
$checks = [System.Collections.Generic.List[string]]::new()
$checks.Add("TradeNet client preflight")
$checks.Add("Generated: $((Get-Date).ToString('o'))")
$checks.Add("")

if ($profile.Client.Deployment.VerifyBinaries) {
    foreach ($entry in @(
        @{ Name = "udp2raw"; Path = $profile.Client.Udp2rawExePath },
        @{ Name = "WireGuard GUI"; Path = $profile.Client.WireGuardGui },
        @{ Name = "wg.exe"; Path = $profile.Client.WgExe },
        @{ Name = "Mihomo"; Path = $profile.Client.MihomoExe }
    )) {
        $exists = Test-Path -LiteralPath $entry.Path
        $checks.Add(("{0}: {1} [{2}]" -f $entry.Name, $(if ($exists) { "OK" } else { "MISSING" }), $entry.Path))
        if (-not $exists -and $entry.Name -ne "Mihomo") {
            throw "Required binary missing: $($entry.Path)"
        }
    }
}

$tradeConfig = [ordered]@{
    Udp2rawExe           = $profile.Client.Udp2rawExePath
    Udp2rawDev           = $profile.Client.Udp2rawDev
    Udp2rawListenHost    = "127.0.0.1"
    Udp2rawListenPort    = [int]$serverArtifact.client.wireguard_port
    VpsIp                = $serverArtifact.server.public_endpoint
    Udp2rawRemotePort    = [int]$serverArtifact.udp2raw.listen_port
    Udp2rawPassword      = $serverArtifact.udp2raw.password
    WireGuardServiceName = $profile.Client.WireGuardServiceName
    LocalGateway         = $profile.Client.LocalGateway
    WireGuardGui         = $profile.Client.WireGuardGui
    WgExe                = $profile.Client.WgExe
    MihomoExe            = $profile.Client.MihomoExe
    WatchdogTaskName     = $watchdogTaskName
    WatchdogStartupDelaySeconds = $watchdogStartupDelaySeconds
    WatchdogRestartIntervalMinutes = $watchdogRestartIntervalMinutes
    WatchdogRestartCount = $watchdogRestartCount
    WatchdogIgnoreManualStopOnBoot = $watchdogIgnoreManualStopOnBoot
    OpenWireGuardGui     = [bool]$profile.Client.OpenWireGuardGui
    OpenPingWindows      = [bool]$profile.Client.OpenPingWindows
}

$splitProfile = [ordered]@{
    MihomoExe        = $profile.Client.MihomoExe
    WorkingDirectory = (Join-Path $repoRoot "mihomo")
    OutputConfigPath = (Join-Path (Join-Path $repoRoot "mihomo") "tradenet-split.yaml")
    WireGuard        = [ordered]@{
        Name                = "TradeNet-WG"
        Server              = $serverArtifact.client.wireguard_host
        Port                = [int]$serverArtifact.client.wireguard_port
        IpCidr              = $serverArtifact.client.address
        PrivateKey          = $serverArtifact.client.private_key
        PublicKey           = $serverArtifact.server.wireguard_public_key
        AllowedIPs          = @($serverArtifact.client.allowed_routes)
        MTU                 = [int]$serverArtifact.client.mtu
        UDP                 = $true
        PersistentKeepalive = [int]$serverArtifact.client.persistent_keepalive
    }
    AppRules         = [ordered]@{
        Direct   = @($profile.SplitRouting.DirectApps)
        TradeNet = @($profile.SplitRouting.TradeApps)
    }
    DNS              = [ordered]@{
        Enable       = $true
        IPv6         = $false
        EnhancedMode = "redir-host"
        NameServers  = @($serverArtifact.client.dns, "223.5.5.5")
    }
    TUN              = [ordered]@{
        Enable      = $true
        Stack       = "mixed"
        AutoRoute   = $true
        StrictRoute = $true
        DnsHijack   = @("any:53")
    }
    DefaultAction    = "DIRECT"
    MixedPort        = 7890
    Controller       = "127.0.0.1:9097"
    LogLevel         = "info"
}

Set-Content -Path (Join-Path $repoRoot "TradeNet.Config.psd1") -Value (ConvertTo-Psd1Literal -Value $tradeConfig) -Encoding UTF8
Set-Content -Path (Join-Path $repoRoot "TradeNet.SplitRouting.psd1") -Value (ConvertTo-Psd1Literal -Value $splitProfile) -Encoding UTF8

$wgConfSource = Join-Path $artifactsDir "client-wireguard.conf"
$wgConfTarget = Join-Path $artifactsDir "client-wireguard.import.conf"
if (Test-Path -LiteralPath $wgConfSource) {
    Copy-Item -LiteralPath $wgConfSource -Destination $wgConfTarget -Force
}

if ($profile.Client.Deployment.RunPreflightChecks) {
    $checks.Add("")
    $checks.Add("Tunnel service target: $($profile.Client.WireGuardServiceName)")
    $checks.Add("WireGuard import file: $wgConfTarget")
    $checks.Add("Admin shell: $([bool](Test-Administrator))")
    $checks.Add("Watchdog task target: $watchdogTaskName")
    $checks.Add("Watchdog install requested: $installWatchdogTask")
}

if ($profile.Client.Deployment.InstallWireGuardTunnel) {
    if (-not (Test-Administrator)) {
        throw "InstallWireGuardTunnel requires an elevated PowerShell session."
    }

    if (-not (Test-Path -LiteralPath $wgConfTarget)) {
        throw "WireGuard import file missing: $wgConfTarget"
    }

    $tunnelName = $profile.Client.Deployment.TunnelConfigName
    if ($profile.Client.Deployment.ReplaceExistingTunnel) {
        & $profile.Client.WireGuardGui /uninstalltunnelservice $tunnelName | Out-Null
        Start-Sleep -Seconds 1
    }

    & $profile.Client.WireGuardGui /installtunnelservice $wgConfTarget | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "WireGuard tunnel installation failed for $tunnelName"
    }

    $checks.Add("WireGuard tunnel installed: $tunnelName")
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "Build-TradeNetMihomoConfig.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "Build-TradeNetMihomoConfig.ps1 failed."
}

if ($installWatchdogTask) {
    if (-not (Test-Administrator)) {
        throw "InstallWatchdogTask requires an elevated PowerShell session."
    }

    $registerArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $repoRoot "Register-TradeNetWatchdog.ps1")
    )
    if ($replaceWatchdogTask) {
        $registerArgs += "-Replace"
    }
    if ($startWatchdogAfterInstall) {
        $registerArgs += "-StartNow"
    }

    & powershell.exe @registerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Register-TradeNetWatchdog.ps1 failed."
    }

    $checks.Add("Watchdog task installed: $watchdogTaskName")
    $checks.Add("Watchdog start requested: $startWatchdogAfterInstall")
}

$checks | Set-Content -Path $preflightReport -Encoding UTF8

Write-Host "Client configuration rendered." -ForegroundColor Green
Write-Host "Config: $(Join-Path $repoRoot 'TradeNet.Config.psd1')"
Write-Host "Split profile: $(Join-Path $repoRoot 'TradeNet.SplitRouting.psd1')"
Write-Host "Preflight: $preflightReport"
