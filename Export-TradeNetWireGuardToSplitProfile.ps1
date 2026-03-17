param(
    [string]$TunnelName = "v1",
    [string]$ExamplePath = (Join-Path $PSScriptRoot "TradeNet.SplitRouting.example.psd1"),
    [string]$OutputProfilePath = (Join-Path $PSScriptRoot "TradeNet.SplitRouting.psd1")
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
    param(
        [Parameter(Mandatory)]
        $Value,
        [int]$Indent = 0
    )

    $prefix = (" " * $Indent)

    if ($Value -is [System.Collections.IDictionary]) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("@{")
        foreach ($key in $Value.Keys) {
            $literal = ConvertTo-Psd1Literal -Value $Value[$key] -Indent ($Indent + 4)
            $literalLines = @($literal -split "`r?`n")
            if ($literalLines.Count -eq 1) {
                $lines.Add(("{0}    {1} = {2}" -f $prefix, $key, $literalLines[0]))
            } else {
                $lines.Add(("{0}    {1} = {2}" -f $prefix, $key, $literalLines[0]))
                foreach ($line in $literalLines[1..($literalLines.Count - 1)]) {
                    $lines.Add($line)
                }
            }
        }
        $lines.Add(("{0}}" -f $prefix))
        return [string]::Join([Environment]::NewLine, $lines)
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("@(")
        foreach ($item in $Value) {
            $literal = ConvertTo-Psd1Literal -Value $item -Indent ($Indent + 4)
            $literalLines = @($literal -split "`r?`n")
            if ($literalLines.Count -eq 1) {
                $lines.Add(("{0}    {1}" -f $prefix, $literalLines[0]))
            } else {
                $lines.Add(("{0}    {1}" -f $prefix, $literalLines[0]))
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

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
        return [string]$Value
    }

    if ($null -eq $Value) {
        return '$null'
    }

    return Quote-Psd1String -Value ([string]$Value)
}

function Parse-WireGuardConfig {
    param([string[]]$Lines)

    $interface = [ordered]@{}
    $peers = [System.Collections.Generic.List[hashtable]]::new()
    $section = ""
    $currentPeer = $null

    foreach ($rawLine in $Lines) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            continue
        }

        if ($line -match '^\[(.+)\]$') {
            if ($section -eq "Peer" -and $currentPeer) {
                $peers.Add($currentPeer)
                $currentPeer = $null
            }

            $section = $Matches[1]
            if ($section -eq "Peer") {
                $currentPeer = [ordered]@{}
            }
            continue
        }

        if ($line -notmatch '^(?<key>[^=]+?)\s*=\s*(?<value>.+)$') {
            continue
        }

        $key = $Matches["key"].Trim()
        $value = $Matches["value"].Trim()

        switch ($section) {
            "Interface" {
                $interface[$key] = $value
            }
            "Peer" {
                $currentPeer[$key] = $value
            }
        }
    }

    if ($section -eq "Peer" -and $currentPeer) {
        $peers.Add($currentPeer)
    }

    return [pscustomobject]@{
        Interface = $interface
        Peers     = @($peers)
    }
}

function Start-ElevatedExport {
    param(
        [string]$ScriptPath,
        [string]$TunnelName,
        [string]$ExamplePath,
        [string]$OutputProfilePath
    )

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$ScriptPath`"",
        "-TunnelName", "`"$TunnelName`"",
        "-ExamplePath", "`"$ExamplePath`"",
        "-OutputProfilePath", "`"$OutputProfilePath`""
    )

    $process = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $args -Wait -PassThru
    exit $process.ExitCode
}

if (-not (Test-Path -LiteralPath $ExamplePath)) {
    throw "Example profile not found: $ExamplePath"
}

if (-not (Test-Administrator)) {
    try {
        Start-ElevatedExport -ScriptPath $PSCommandPath -TunnelName $TunnelName -ExamplePath $ExamplePath -OutputProfilePath $OutputProfilePath
    } catch {
        throw "Elevation was cancelled or failed: $($_.Exception.Message)"
    }
}

$wgExe = "C:\Program Files\WireGuard\wg.exe"
if (-not (Test-Path -LiteralPath $wgExe)) {
    throw "WireGuard wg.exe not found: $wgExe"
}

$rawConfig = & $wgExe showconf $TunnelName
if ($LASTEXITCODE -ne 0 -or -not $rawConfig) {
    throw "Unable to export WireGuard tunnel configuration for $TunnelName"
}

$parsed = Parse-WireGuardConfig -Lines @($rawConfig)
if (-not $parsed.Interface.PrivateKey) {
    throw "Exported configuration does not contain Interface.PrivateKey"
}

$peer = $parsed.Peers | Where-Object { $_.Endpoint } | Select-Object -First 1
if (-not $peer) {
    $peer = $parsed.Peers | Select-Object -First 1
}

if (-not $peer) {
    throw "Exported configuration does not contain a peer section"
}

$importedProfile = Import-PowerShellDataFile -Path $ExamplePath
$profile = [ordered]@{}
foreach ($key in $importedProfile.Keys) {
    $profile[$key] = $importedProfile[$key]
}

$address = @($parsed.Interface.Address -split ",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+/\d+$' } | Select-Object -First 1
if ($address) {
    $profile.WireGuard.IpCidr = $address
}

$endpointHost = $null
$endpointPort = $null
if ($peer.Endpoint -match '^(?<host>\[[^\]]+\]|[^:]+):(?<port>\d+)$') {
    $endpointHost = $Matches["host"].Trim("[]")
    $endpointPort = [int]$Matches["port"]
}

if ($endpointHost) {
    $profile.WireGuard.Server = $endpointHost
}

if ($endpointPort) {
    $profile.WireGuard.Port = $endpointPort
}

$profile.WireGuard.PrivateKey = $parsed.Interface.PrivateKey
$profile.WireGuard.PublicKey = $peer.PublicKey

if ($peer.AllowedIPs) {
    $profile.WireGuard.AllowedIPs = @($peer.AllowedIPs -split ",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

if ($parsed.Interface.MTU) {
    $profile.WireGuard.MTU = [int]$parsed.Interface.MTU
}

if ($peer.PersistentKeepalive) {
    $profile.WireGuard.PersistentKeepalive = [int]$peer.PersistentKeepalive
}

if (Test-Path -LiteralPath $OutputProfilePath) {
    $backupPath = "{0}.bak_{1}" -f $OutputProfilePath, (Get-Date -Format "yyyyMMdd_HHmmss")
    Copy-Item -LiteralPath $OutputProfilePath -Destination $backupPath -Force
}

$literal = ConvertTo-Psd1Literal -Value $profile
Set-Content -Path $OutputProfilePath -Value $literal -Encoding UTF8

Import-PowerShellDataFile -Path $OutputProfilePath | Out-Null
Write-Host "Exported WireGuard tunnel $TunnelName to $OutputProfilePath" -ForegroundColor Green
