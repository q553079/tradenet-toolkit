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

function ConvertTo-OrderedClone {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $copy[$key] = ConvertTo-OrderedClone -Value $Value[$key]
        }
        return $copy
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += ,(ConvertTo-OrderedClone -Value $item)
        }
        return $items
    }

    return $Value
}

function Test-ConfigKey {
    param(
        [Parameter(Mandatory)]$Map,
        [Parameter(Mandatory)][string]$Key
    )

    if ($null -eq $Map) {
        return $false
    }

    if ($Map -is [System.Collections.IDictionary]) {
        return $Map.Contains($Key)
    }

    return $null -ne $Map.PSObject.Properties[$Key]
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory)]$Map,
        [Parameter(Mandatory)][string]$Key,
        $Default = $null
    )

    if (-not (Test-ConfigKey -Map $Map -Key $Key)) {
        return $Default
    }

    if ($Map -is [System.Collections.IDictionary]) {
        return $Map[$Key]
    }

    return $Map.PSObject.Properties[$Key].Value
}

function Get-NormalizedStringArray {
    param($Value)

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Value)) {
        if ($null -eq $item) {
            continue
        }

        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $items.Add($text)
    }

    return @($items)
}

function Merge-UniqueStringArray {
    param(
        $BaseValues,
        $AdditionalValues
    )

    $merged = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($value in (Get-NormalizedStringArray -Value $BaseValues)) {
        if ($seen.Add($value)) {
            $merged.Add($value)
        }
    }

    foreach ($value in (Get-NormalizedStringArray -Value $AdditionalValues)) {
        if ($seen.Add($value)) {
            $merged.Add($value)
        }
    }

    return @($merged)
}

if (-not (Test-Path -LiteralPath $ProfilePath)) {
    throw "Deployment profile not found: $ProfilePath"
}

if (-not (Test-Path -LiteralPath $ServerArtifactPath)) {
    throw "Server artifact not found: $ServerArtifactPath"
}

$profile = Import-PowerShellDataFile -Path $ProfilePath
$serverArtifact = Get-Content -Raw -Path $ServerArtifactPath | ConvertFrom-Json
$clientProfile = $profile.Client
$clientDeployment = $clientProfile.Deployment
$splitRoutingOverrides = Get-ConfigValue -Map $profile -Key "SplitRouting" -Default ([ordered]@{})

$installWireGuardTunnel = if ($null -eq $clientDeployment["InstallWireGuardTunnel"]) { $false } else { [bool]$clientDeployment["InstallWireGuardTunnel"] }
$installWatchdogTask = if ($null -eq $clientDeployment["InstallWatchdogTask"]) { $false } else { [bool]$clientDeployment["InstallWatchdogTask"] }
$replaceWatchdogTask = if ($null -eq $clientDeployment["ReplaceWatchdogTask"]) { $true } else { [bool]$clientDeployment["ReplaceWatchdogTask"] }
$startWatchdogAfterInstall = if ($null -eq $clientDeployment["StartWatchdogAfterInstall"]) { $true } else { [bool]$clientDeployment["StartWatchdogAfterInstall"] }
$watchdogTaskName = if ($clientDeployment["WatchdogTaskName"]) { [string]$clientDeployment["WatchdogTaskName"] } else { "TradeNet-Watchdog" }
$watchdogStartupDelaySeconds = if ($null -ne $clientDeployment["WatchdogStartupDelaySeconds"]) { [int]$clientDeployment["WatchdogStartupDelaySeconds"] } else { 20 }
$watchdogRestartIntervalMinutes = if ($null -ne $clientDeployment["WatchdogRestartIntervalMinutes"]) { [int]$clientDeployment["WatchdogRestartIntervalMinutes"] } else { 1 }
$watchdogRestartCount = if ($null -ne $clientDeployment["WatchdogRestartCount"]) { [int]$clientDeployment["WatchdogRestartCount"] } else { 999 }
$watchdogIgnoreManualStopOnBoot = if ($null -eq $clientDeployment["IgnoreManualStopOnBoot"]) { $true } else { [bool]$clientDeployment["IgnoreManualStopOnBoot"] }
$syncClashProfile = if ($null -eq $clientDeployment["SyncClashProfile"]) { $false } else { [bool]$clientDeployment["SyncClashProfile"] }
$backupClashProfileBeforeSync = if ($null -eq $clientDeployment["BackupClashProfileBeforeSync"]) { $true } else { [bool]$clientDeployment["BackupClashProfileBeforeSync"] }
$clashVergeProfilePath = if (Test-ConfigKey -Map $clientProfile -Key "ClashVergeProfilePath") { [string](Get-ConfigValue -Map $clientProfile -Key "ClashVergeProfilePath") } else { "" }

$repoRoot = Split-Path $PSScriptRoot -Parent
$artifactsDir = Join-Path $repoRoot "artifacts"
$mihomoDir = Join-Path $repoRoot "mihomo"
$stateDir = Join-Path $repoRoot "state"
$splitTemplatePath = Join-Path $repoRoot "TradeNet.SplitRouting.example.psd1"
$tradeConfigPath = Join-Path $repoRoot "TradeNet.Config.psd1"
$splitProfilePath = Join-Path $repoRoot "TradeNet.SplitRouting.psd1"

foreach ($path in @($artifactsDir, $mihomoDir, $stateDir)) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

if (-not (Test-Path -LiteralPath $splitTemplatePath)) {
    throw "Split-routing template not found: $splitTemplatePath"
}

$splitTemplate = ConvertTo-OrderedClone -Value (Import-PowerShellDataFile -Path $splitTemplatePath)

$preflightReport = Join-Path $artifactsDir "client-preflight.txt"
$checks = [System.Collections.Generic.List[string]]::new()
$checks.Add("TradeNet client preflight")
$checks.Add("Generated: $((Get-Date).ToString('o'))")
$checks.Add("Deployment profile: $ProfilePath")
$checks.Add("Server artifact: $ServerArtifactPath")
$checks.Add("Split template: $splitTemplatePath")
$checks.Add("")

if ($clientDeployment.VerifyBinaries) {
    foreach ($entry in @(
        @{ Name = "udp2raw"; Path = $clientProfile.Udp2rawExePath; Required = $true },
        @{ Name = "Mihomo"; Path = $clientProfile.MihomoExe; Required = $false },
        @{ Name = "WireGuard GUI"; Path = $clientProfile.WireGuardGui; Required = $installWireGuardTunnel },
        @{ Name = "wg.exe"; Path = $clientProfile.WgExe; Required = $false }
    )) {
        $pathText = if ([string]::IsNullOrWhiteSpace([string]$entry.Path)) { "<empty>" } else { [string]$entry.Path }
        $exists = $pathText -ne "<empty>" -and (Test-Path -LiteralPath $entry.Path)
        $checks.Add(("{0}: {1} [{2}] ({3})" -f $entry.Name, $(if ($exists) { "OK" } else { "MISSING" }), $pathText, $(if ($entry.Required) { "required" } else { "optional" })))
        if ($entry.Required -and -not $exists) {
            throw "Required binary missing: $pathText"
        }
    }
}

$tradeConfig = [ordered]@{
    Udp2rawExe           = $clientProfile.Udp2rawExePath
    Udp2rawDev           = $clientProfile.Udp2rawDev
    Udp2rawListenHost    = "127.0.0.1"
    Udp2rawListenPort    = [int]$serverArtifact.client.wireguard_port
    VpsIp                = $serverArtifact.server.public_endpoint
    Udp2rawRemotePort    = [int]$serverArtifact.udp2raw.listen_port
    Udp2rawPassword      = $serverArtifact.udp2raw.password
    WireGuardServiceName = $clientProfile.WireGuardServiceName
    LocalGateway         = $clientProfile.LocalGateway
    WireGuardGui         = $clientProfile.WireGuardGui
    WgExe                = $clientProfile.WgExe
    MihomoExe            = $clientProfile.MihomoExe
    WatchdogTaskName     = $watchdogTaskName
    WatchdogStartupDelaySeconds = $watchdogStartupDelaySeconds
    WatchdogRestartIntervalMinutes = $watchdogRestartIntervalMinutes
    WatchdogRestartCount = $watchdogRestartCount
    WatchdogIgnoreManualStopOnBoot = $watchdogIgnoreManualStopOnBoot
    OpenWireGuardGui     = [bool]$clientProfile.OpenWireGuardGui
    OpenPingWindows      = [bool]$clientProfile.OpenPingWindows
}

$splitProfile = ConvertTo-OrderedClone -Value $splitTemplate
$splitProfile.MihomoExe = $clientProfile.MihomoExe
$splitProfile.WorkingDirectory = $mihomoDir
$splitProfile.OutputConfigPath = (Join-Path $mihomoDir "tradenet-split.yaml")
$splitProfile.WireGuard.Server = [string]$serverArtifact.client.wireguard_host
$splitProfile.WireGuard.Port = [int]$serverArtifact.client.wireguard_port
$splitProfile.WireGuard.IpCidr = [string]$serverArtifact.client.address
$splitProfile.WireGuard.PrivateKey = [string]$serverArtifact.client.private_key
$splitProfile.WireGuard.PublicKey = [string]$serverArtifact.server.wireguard_public_key
$splitProfile.WireGuard.MTU = [int]$serverArtifact.client.mtu
$splitProfile.WireGuard.UDP = $true
$splitProfile.WireGuard.PersistentKeepalive = [int]$serverArtifact.client.persistent_keepalive
$splitProfile.WireGuard.AllowedIPs = if (Test-ConfigKey -Map $splitRoutingOverrides -Key "WireGuardAllowedIPs") {
    Get-NormalizedStringArray -Value (Get-ConfigValue -Map $splitRoutingOverrides -Key "WireGuardAllowedIPs")
} else {
    Get-NormalizedStringArray -Value (Get-ConfigValue -Map $splitProfile.WireGuard -Key "AllowedIPs")
}
$splitProfile.WireGuard.RemoteDnsResolve = if (Test-ConfigKey -Map $splitRoutingOverrides -Key "WireGuardRemoteDnsResolve") {
    [bool](Get-ConfigValue -Map $splitRoutingOverrides -Key "WireGuardRemoteDnsResolve")
} else {
    [bool](Get-ConfigValue -Map $splitProfile.WireGuard -Key "RemoteDnsResolve")
}
$splitProfile.WireGuard.Dns = if (Test-ConfigKey -Map $splitRoutingOverrides -Key "WireGuardDns") {
    Get-NormalizedStringArray -Value (Get-ConfigValue -Map $splitRoutingOverrides -Key "WireGuardDns")
} else {
    Get-NormalizedStringArray -Value (Get-ConfigValue -Map $splitProfile.WireGuard -Key "Dns")
}
$splitProfile.AppRules.Direct = if (Test-ConfigKey -Map $splitRoutingOverrides -Key "DirectApps") {
    Get-NormalizedStringArray -Value (Get-ConfigValue -Map $splitRoutingOverrides -Key "DirectApps")
} else {
    Get-NormalizedStringArray -Value (Get-ConfigValue -Map $splitProfile.AppRules -Key "Direct")
}
$splitProfile.AppRules.TradeNet = if (Test-ConfigKey -Map $splitRoutingOverrides -Key "TradeApps") {
    Get-NormalizedStringArray -Value (Get-ConfigValue -Map $splitRoutingOverrides -Key "TradeApps")
} else {
    Get-NormalizedStringArray -Value (Get-ConfigValue -Map $splitProfile.AppRules -Key "TradeNet")
}

$effectiveCustomRules = if (Test-ConfigKey -Map $splitRoutingOverrides -Key "CustomRules") {
    Get-NormalizedStringArray -Value (Get-ConfigValue -Map $splitRoutingOverrides -Key "CustomRules")
} else {
    Get-NormalizedStringArray -Value (Get-ConfigValue -Map $splitProfile -Key "CustomRules")
}
$splitProfile.CustomRules = Merge-UniqueStringArray -BaseValues $effectiveCustomRules -AdditionalValues (Get-ConfigValue -Map $splitRoutingOverrides -Key "AdditionalRules")

$dnsFallbackFilter = Get-ConfigValue -Map (Get-ConfigValue -Map $splitProfile -Key "DNS") -Key "FallbackFilter"
if ($null -ne $dnsFallbackFilter) {
    $effectiveFallbackDomains = if (Test-ConfigKey -Map $splitRoutingOverrides -Key "FallbackFilterDomains") {
        Get-NormalizedStringArray -Value (Get-ConfigValue -Map $splitRoutingOverrides -Key "FallbackFilterDomains")
    } else {
        Get-NormalizedStringArray -Value (Get-ConfigValue -Map $dnsFallbackFilter -Key "Domain")
    }

    $dnsFallbackFilter.Domain = Merge-UniqueStringArray -BaseValues $effectiveFallbackDomains -AdditionalValues (Get-ConfigValue -Map $splitRoutingOverrides -Key "AdditionalFallbackDomains")
}

if (Test-ConfigKey -Map $splitRoutingOverrides -Key "DefaultAction") {
    $splitProfile.DefaultAction = [string](Get-ConfigValue -Map $splitRoutingOverrides -Key "DefaultAction")
}
if (Test-ConfigKey -Map $splitRoutingOverrides -Key "MixedPort") {
    $splitProfile.MixedPort = [int](Get-ConfigValue -Map $splitRoutingOverrides -Key "MixedPort")
}
if (Test-ConfigKey -Map $splitRoutingOverrides -Key "Controller") {
    $splitProfile.Controller = [string](Get-ConfigValue -Map $splitRoutingOverrides -Key "Controller")
}
if (Test-ConfigKey -Map $splitRoutingOverrides -Key "LogLevel") {
    $splitProfile.LogLevel = [string](Get-ConfigValue -Map $splitRoutingOverrides -Key "LogLevel")
}

Set-Content -Path $tradeConfigPath -Value (ConvertTo-Psd1Literal -Value $tradeConfig) -Encoding UTF8
Set-Content -Path $splitProfilePath -Value (ConvertTo-Psd1Literal -Value $splitProfile) -Encoding UTF8

$wgConfSource = Join-Path $artifactsDir "client-wireguard.conf"
$wgConfTarget = Join-Path $artifactsDir "client-wireguard.import.conf"
if (Test-Path -LiteralPath $wgConfSource) {
    Copy-Item -LiteralPath $wgConfSource -Destination $wgConfTarget -Force
}

if ($clientDeployment.RunPreflightChecks) {
    $checks.Add("")
    $checks.Add("Tunnel service target: $($clientProfile.WireGuardServiceName)")
    $checks.Add("WireGuard import file: $wgConfTarget")
    $checks.Add("Admin shell: $([bool](Test-Administrator))")
    $checks.Add("Mihomo working directory: $mihomoDir")
    $checks.Add("Rendered config: $tradeConfigPath")
    $checks.Add("Rendered split profile: $splitProfilePath")
    $checks.Add("Rendered Mihomo YAML: $($splitProfile.OutputConfigPath)")
    $checks.Add("TradeNet WG endpoint: $($splitProfile.WireGuard.Server):$($splitProfile.WireGuard.Port)")
    $checks.Add("TradeNet WG allowed IPs: $(@($splitProfile.WireGuard.AllowedIPs) -join ',')")
    $checks.Add("TradeNet WG remote DNS: $([bool]$splitProfile.WireGuard.RemoteDnsResolve)")
    $checks.Add("TradeNet WG DNS: $(@($splitProfile.WireGuard.Dns) -join ',')")
    $checks.Add("Split rules: direct=$(@($splitProfile.AppRules.Direct).Count); tradenet=$(@($splitProfile.AppRules.TradeNet).Count); custom=$(@($splitProfile.CustomRules).Count); default=$($splitProfile.DefaultAction)")
    $checks.Add("Clash Verge sync requested: $syncClashProfile")
    $checks.Add("Clash Verge profile target: $(if ([string]::IsNullOrWhiteSpace($clashVergeProfilePath)) { '<not-set>' } else { $clashVergeProfilePath })")
    $checks.Add("Clash Verge backup before sync: $backupClashProfileBeforeSync")
    $checks.Add("Watchdog task target: $watchdogTaskName")
    $checks.Add("Watchdog install requested: $installWatchdogTask")
}

if ($installWireGuardTunnel) {
    if (-not (Test-Administrator)) {
        throw "InstallWireGuardTunnel requires an elevated PowerShell session."
    }

    if (-not (Test-Path -LiteralPath $wgConfTarget)) {
        throw "WireGuard import file missing: $wgConfTarget"
    }

    $tunnelName = $clientDeployment.TunnelConfigName
    if ($clientDeployment.ReplaceExistingTunnel) {
        & $clientProfile.WireGuardGui /uninstalltunnelservice $tunnelName | Out-Null
        Start-Sleep -Seconds 1
    }

    & $clientProfile.WireGuardGui /installtunnelservice $wgConfTarget | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "WireGuard tunnel installation failed for $tunnelName"
    }

    $checks.Add("WireGuard tunnel installed: $tunnelName")
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "Build-TradeNetMihomoConfig.ps1") -ProfilePath $splitProfilePath -OutputPath $splitProfile.OutputConfigPath
if ($LASTEXITCODE -ne 0) {
    throw "Build-TradeNetMihomoConfig.ps1 failed."
}

$clashProfileBackupPath = $null
if ($syncClashProfile) {
    if ([string]::IsNullOrWhiteSpace($clashVergeProfilePath)) {
        throw "Client.ClashVergeProfilePath must be set when Client.Deployment.SyncClashProfile is true."
    }

    $clashVergeProfileDir = Split-Path -Path $clashVergeProfilePath -Parent
    if ([string]::IsNullOrWhiteSpace($clashVergeProfileDir) -or -not (Test-Path -LiteralPath $clashVergeProfileDir)) {
        throw "Clash Verge profile directory not found: $clashVergeProfileDir"
    }

    if ($backupClashProfileBeforeSync -and (Test-Path -LiteralPath $clashVergeProfilePath)) {
        $clashProfileBackupPath = "{0}.bak_{1}" -f $clashVergeProfilePath, (Get-Date -Format "yyyyMMdd-HHmmss")
        Copy-Item -LiteralPath $clashVergeProfilePath -Destination $clashProfileBackupPath -Force
    }

    Copy-Item -LiteralPath $splitProfile.OutputConfigPath -Destination $clashVergeProfilePath -Force
    $checks.Add("Clash Verge profile synced: $clashVergeProfilePath")
    if ($clashProfileBackupPath) {
        $checks.Add("Clash Verge profile backup: $clashProfileBackupPath")
    }
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
Write-Host "Config: $tradeConfigPath"
Write-Host "Split profile: $splitProfilePath"
Write-Host "Mihomo YAML: $($splitProfile.OutputConfigPath)"
if ($syncClashProfile) {
    Write-Host "Clash Verge profile: $clashVergeProfilePath"
    if ($clashProfileBackupPath) {
        Write-Host "Clash backup: $clashProfileBackupPath"
    }
}
Write-Host "Preflight: $preflightReport"
