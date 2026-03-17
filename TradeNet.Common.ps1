[Console]::InputEncoding = [System.Text.UTF8Encoding]::new()
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
Set-StrictMode -Version Latest

$script:TradeNetRoot = $PSScriptRoot
$script:TradeNetLockStream = $null

function Merge-TradeNetConfig {
    param(
        [hashtable]$Base,
        [hashtable]$Override
    )

    foreach ($key in $Override.Keys) {
        $Base[$key] = $Override[$key]
    }

    return $Base
}

function Get-TradeNetConfig {
    $config = [ordered]@{
        ScriptRoot            = $script:TradeNetRoot
        Udp2rawExe            = "D:\TradeNet\bin\udp2raw_mp.exe"
        Udp2rawDev            = "\Device\NPF_{CHANGE_ME}"
        Udp2rawListenHost     = "127.0.0.1"
        Udp2rawListenPort     = 24008
        VpsIp                 = "203.0.113.10"
        Udp2rawRemotePort     = 4000
        Udp2rawPassword       = "CHANGE_ME"
        WireGuardServiceName  = "WireGuardTunnel`$tradenet"
        LocalGateway          = "192.168.0.1"
        WireGuardGui          = "C:\Program Files\WireGuard\wireguard.exe"
        WgExe                 = "C:\Program Files\WireGuard\wg.exe"
        MihomoExe             = "C:\Program Files\Clash Verge\verge-mihomo.exe"
        LogDir                = (Join-Path $script:TradeNetRoot "logs")
        StateDir              = (Join-Path $script:TradeNetRoot "state")
        StateFile             = (Join-Path (Join-Path $script:TradeNetRoot "state") "tradenet-state.json")
        LockFile              = (Join-Path (Join-Path $script:TradeNetRoot "state") "tradenet.lock")
        ManualStopFlag        = (Join-Path (Join-Path $script:TradeNetRoot "state") "manual-stop.flag")
        SplitRoutingExamplePath = (Join-Path $script:TradeNetRoot "TradeNet.SplitRouting.example.psd1")
        SplitRoutingProfilePath = (Join-Path $script:TradeNetRoot "TradeNet.SplitRouting.psd1")
        SplitRoutingConfigPath  = (Join-Path (Join-Path $script:TradeNetRoot "mihomo") "tradenet-split.yaml")
        SplitRoutingStateFile   = (Join-Path (Join-Path $script:TradeNetRoot "state") "split-routing-state.json")
        SplitRoutingDocsPath    = (Join-Path $script:TradeNetRoot "SplitRouting.md")
        StartupTimeoutSeconds = 20
        ServiceTimeoutSeconds = 20
        MonitorRefreshSeconds = 2
        AutoRestartEnabled    = $false
        AutoRestartThreshold  = 3
        AutoRestartCooldown   = 20
        WatchdogTaskName      = "TradeNet-Watchdog"
        WatchdogStartupDelaySeconds = 20
        WatchdogRestartIntervalMinutes = 1
        WatchdogRestartCount  = 999
        WatchdogIgnoreManualStopOnBoot = $true
        OpenWireGuardGui      = $true
        OpenPingWindows       = $true
        PingTargets           = @(
            @{
                Title = "PING-WG-10.77.0.1"
                Host  = "10.77.0.1"
            },
            @{
                Title = "PING-DNS-8.8.8.8"
                Host  = "8.8.8.8"
            }
        )
    }

    $overridePath = Join-Path $script:TradeNetRoot "TradeNet.Config.psd1"
    if (Test-Path -LiteralPath $overridePath) {
        $override = Import-PowerShellDataFile -Path $overridePath
        $config = Merge-TradeNetConfig -Base $config -Override $override
    }

    $config["Udp2rawListen"] = "{0}:{1}" -f $config.Udp2rawListenHost, $config.Udp2rawListenPort
    $config["Udp2rawRemote"] = "{0}:{1}" -f $config.VpsIp, $config.Udp2rawRemotePort

    return [pscustomobject]$config
}

function Ensure-TradeNetDirectory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function New-TradeNetLogContext {
    param(
        [pscustomobject]$Config,
        [string]$Prefix
    )

    Ensure-TradeNetDirectory -Path $Config.LogDir
    Ensure-TradeNetDirectory -Path $Config.StateDir

    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    return [pscustomobject]@{
        Timestamp      = $timestamp
        MainLog        = Join-Path $Config.LogDir ("{0}_{1}.log" -f $Prefix, $timestamp)
        Udp2rawOutLog  = Join-Path $Config.LogDir ("udp2raw_out_{0}.log" -f $timestamp)
        Udp2rawErrLog  = Join-Path $Config.LogDir ("udp2raw_err_{0}.log" -f $timestamp)
    }
}

function Write-TradeNetLog {
    param(
        [string]$Message,
        [string]$Path,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO",
        [switch]$NoConsole
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    if ($Path) {
        Add-Content -Path $Path -Value $line -Encoding UTF8
    }

    if (-not $NoConsole) {
        $color = switch ($Level) {
            "WARN" { "Yellow" }
            "ERROR" { "Red" }
            default { "Gray" }
        }

        Write-Host $line -ForegroundColor $color
    }
}

function Test-TradeNetAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Assert-TradeNetAdministrator {
    if (-not (Test-TradeNetAdministrator)) {
        throw "TradeNet 脚本需要以管理员身份运行，否则无法操作路由和 WireGuard 服务。"
    }
}

function Enter-TradeNetLock {
    param(
        [pscustomobject]$Config,
        [int]$TimeoutSeconds = 15
    )

    Ensure-TradeNetDirectory -Path $Config.StateDir
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        try {
            $script:TradeNetLockStream = [System.IO.File]::Open(
                $Config.LockFile,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            return
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 500
        }
    }

    throw "另一个 TradeNet 操作正在执行，锁文件: $($Config.LockFile)"
}

function Exit-TradeNetLock {
    if ($script:TradeNetLockStream) {
        $script:TradeNetLockStream.Dispose()
        $script:TradeNetLockStream = $null
    }
}

function Save-TradeNetState {
    param(
        [pscustomobject]$Config,
        [hashtable]$State
    )

    Ensure-TradeNetDirectory -Path $Config.StateDir
    $State | ConvertTo-Json -Depth 6 | Set-Content -Path $Config.StateFile -Encoding UTF8
}

function Load-TradeNetState {
    param([pscustomobject]$Config)

    if (-not (Test-Path -LiteralPath $Config.StateFile)) {
        return $null
    }

    try {
        return Get-Content -Raw -Path $Config.StateFile | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Clear-TradeNetState {
    param([pscustomobject]$Config)

    if (Test-Path -LiteralPath $Config.StateFile) {
        Remove-Item -LiteralPath $Config.StateFile -Force
    }
}

function Set-TradeNetManualStopFlag {
    param([pscustomobject]$Config)

    Ensure-TradeNetDirectory -Path $Config.StateDir
    Set-Content -Path $Config.ManualStopFlag -Value (Get-Date).ToString("o") -Encoding UTF8
}

function Clear-TradeNetManualStopFlag {
    param([pscustomobject]$Config)

    if (Test-Path -LiteralPath $Config.ManualStopFlag) {
        Remove-Item -LiteralPath $Config.ManualStopFlag -Force
    }
}

function Test-TradeNetManualStopFlag {
    param([pscustomobject]$Config)

    return Test-Path -LiteralPath $Config.ManualStopFlag
}

function Load-TradeNetJsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return Get-Content -Raw -Path $Path | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Test-TradeNetPlaceholderValue {
    param([string]$Value)

    return [bool]$Value -and $Value -like "__FILL_*__"
}

function Get-TradeNetSplitRoutingStatus {
    param([pscustomobject]$Config)

    $profileExists = Test-Path -LiteralPath $Config.SplitRoutingProfilePath
    $configExists = Test-Path -LiteralPath $Config.SplitRoutingConfigPath
    $mihomoExists = Test-Path -LiteralPath $Config.MihomoExe
    $profileReady = $false
    $profile = $null

    if ($profileExists) {
        try {
            $profile = Import-PowerShellDataFile -Path $Config.SplitRoutingProfilePath
            $profileReady = `
                -not (Test-TradeNetPlaceholderValue -Value $profile.WireGuard.PrivateKey) -and `
                -not (Test-TradeNetPlaceholderValue -Value $profile.WireGuard.PublicKey) -and `
                [bool]$profile.WireGuard.PrivateKey -and `
                [bool]$profile.WireGuard.PublicKey

            if ($profile.OutputConfigPath) {
                $configExists = Test-Path -LiteralPath $profile.OutputConfigPath
            }

            if ($profile.MihomoExe) {
                $mihomoExists = Test-Path -LiteralPath $profile.MihomoExe
            }
        } catch {
            $profileReady = $false
        }
    }

    $state = Load-TradeNetJsonFile -Path $Config.SplitRoutingStateFile
    $validated = $false
    $validationMessage = "No validation record."
    $generatedAt = $null

    if ($state) {
        $validated = [bool]$state.ValidationPassed
        $validationMessage = if ($state.ValidationMessage) { [string]$state.ValidationMessage } else { $validationMessage }
        if ($state.GeneratedAt) {
            try {
                $generatedAt = [datetime]$state.GeneratedAt
            } catch {
                $generatedAt = $null
            }
        }
    }

    $summary = if (-not $profileExists) {
        "Split profile missing"
    } elseif (-not $profileReady) {
        "Split profile exists but keys are incomplete"
    } elseif (-not $configExists) {
        "Split profile ready, Mihomo YAML not built"
    } elseif ($validated) {
        "Split profile and Mihomo YAML are ready"
    } else {
        "Mihomo YAML exists but validation is missing or failed"
    }

    return [pscustomobject]@{
        ProfileExists      = $profileExists
        ProfileReady       = $profileReady
        ConfigExists       = $configExists
        MihomoExists       = $mihomoExists
        ValidationPassed   = $validated
        ValidationMessage  = $validationMessage
        GeneratedAt        = $generatedAt
        ProfilePath        = $Config.SplitRoutingProfilePath
        ConfigPath         = if ($profile -and $profile.OutputConfigPath) { $profile.OutputConfigPath } else { $Config.SplitRoutingConfigPath }
        DocsPath           = $Config.SplitRoutingDocsPath
        Summary            = $summary
    }
}

function Get-TradeNetProcessByPath {
    param([string]$ExecutablePath)

    $exeName = [System.IO.Path]::GetFileName($ExecutablePath)
    $escapedName = $exeName.Replace("'", "''")

    $matches = Get-CimInstance Win32_Process -Filter "Name = '$escapedName'" -ErrorAction SilentlyContinue
    if (-not $matches) {
        return @()
    }

    return @(
        $matches | Where-Object {
            $_.ExecutablePath -and
            [string]::Equals($_.ExecutablePath, $ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase)
        }
    )
}

function Stop-TradeNetUdp2raw {
    param(
        [pscustomobject]$Config,
        [string]$LogPath,
        [switch]$Quiet
    )

    $processes = Get-TradeNetProcessByPath -ExecutablePath $Config.Udp2rawExe
    if (-not $processes) {
        if (-not $Quiet) {
            Write-TradeNetLog -Message "未发现旧的 udp2raw 进程。" -Path $LogPath
        }
        return
    }

    foreach ($process in $processes) {
        Write-TradeNetLog -Message ("停止旧的 udp2raw 进程 PID={0}" -f $process.ProcessId) -Path $LogPath
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
    }

    Start-Sleep -Seconds 1
}

function Test-TradeNetPortBound {
    param(
        [string]$Address,
        [int]$Port
    )

    $udpMatch = Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object {
        $_.LocalPort -eq $Port -and ($_.LocalAddress -eq $Address -or $_.LocalAddress -eq "0.0.0.0")
    }
    if ($udpMatch) {
        return $true
    }

    $tcpMatch = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object {
        $_.LocalPort -eq $Port -and ($_.LocalAddress -eq $Address -or $_.LocalAddress -eq "0.0.0.0")
    }
    if ($tcpMatch) {
        return $true
    }

    $netstatMatch = netstat -ano | Select-String -SimpleMatch ("{0}:{1}" -f $Address, $Port)
    return [bool]$netstatMatch
}

function Wait-TradeNetPortBound {
    param(
        [string]$Address,
        [int]$Port,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-TradeNetPortBound -Address $Address -Port $Port) {
            return $true
        }

        Start-Sleep -Milliseconds 500
    }

    return $false
}

function Get-TradeNetTailText {
    param(
        [string]$Path,
        [int]$LineCount = 20
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    return (Get-Content -Path $Path -Tail $LineCount -ErrorAction SilentlyContinue | Out-String).Trim()
}

function Ensure-TradeNetHostRoute {
    param(
        [pscustomobject]$Config,
        [string]$LogPath
    )

    $destination = "$($Config.VpsIp)/32"
    $routes = Get-NetRoute -DestinationPrefix $destination -ErrorAction SilentlyContinue
    $matchingRoute = $routes | Where-Object { $_.NextHop -eq $Config.LocalGateway } | Select-Object -First 1

    if ($matchingRoute) {
        Write-TradeNetLog -Message ("VPS 路由已存在: {0} -> {1}" -f $destination, $Config.LocalGateway) -Path $LogPath
        return
    }

    $existingRoute = $routes | Sort-Object RouteMetric | Select-Object -First 1
    if ($existingRoute) {
        Write-TradeNetLog -Message ("发现不同网关的现有路由: {0} -> {1}，尝试覆盖为 {2}" -f $destination, $existingRoute.NextHop, $Config.LocalGateway) -Path $LogPath -Level "WARN"
        $output = (& route.exe change $Config.VpsIp mask 255.255.255.255 $Config.LocalGateway metric 3 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0) {
            Write-TradeNetLog -Message ("已更新 VPS 路由到 {0}" -f $Config.LocalGateway) -Path $LogPath
            return
        }

        Write-TradeNetLog -Message ("route change 失败，准备重建路由。输出: {0}" -f $output) -Path $LogPath -Level "WARN"
        & route.exe delete $Config.VpsIp | Out-Null
    }

    $addOutput = (& route.exe -p add $Config.VpsIp mask 255.255.255.255 $Config.LocalGateway metric 3 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "添加 VPS 路由失败: $addOutput"
    }

    Write-TradeNetLog -Message ("已添加持久路由: {0} -> {1}" -f $destination, $Config.LocalGateway) -Path $LogPath
}

function Test-TradeNetHostRoute {
    param([pscustomobject]$Config)

    $destination = "$($Config.VpsIp)/32"
    $routes = Get-NetRoute -DestinationPrefix $destination -ErrorAction SilentlyContinue
    return [bool]($routes | Where-Object { $_.NextHop -eq $Config.LocalGateway } | Select-Object -First 1)
}

function Wait-TradeNetServiceState {
    param(
        [string]$ServiceName,
        [string]$DesiredState,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($service -and $service.Status.ToString().Equals($DesiredState, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }

        Start-Sleep -Seconds 1
    }

    return $false
}

function Restart-TradeNetWireGuardService {
    param(
        [pscustomobject]$Config,
        [string]$LogPath
    )

    $service = Get-Service -Name $Config.WireGuardServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        throw "WireGuard 服务不存在: $($Config.WireGuardServiceName)"
    }

    if ($service.Status -eq "Running") {
        Write-TradeNetLog -Message ("重启 WireGuard 服务: {0}" -f $Config.WireGuardServiceName) -Path $LogPath
        Stop-Service -Name $Config.WireGuardServiceName -Force -ErrorAction Stop
        if (-not (Wait-TradeNetServiceState -ServiceName $Config.WireGuardServiceName -DesiredState "Stopped" -TimeoutSeconds $Config.ServiceTimeoutSeconds)) {
            throw "WireGuard 服务停止超时: $($Config.WireGuardServiceName)"
        }
    } else {
        Write-TradeNetLog -Message ("启动 WireGuard 服务: {0}" -f $Config.WireGuardServiceName) -Path $LogPath
    }

    Start-Service -Name $Config.WireGuardServiceName -ErrorAction Stop
    if (-not (Wait-TradeNetServiceState -ServiceName $Config.WireGuardServiceName -DesiredState "Running" -TimeoutSeconds $Config.ServiceTimeoutSeconds)) {
        throw "WireGuard 服务启动超时: $($Config.WireGuardServiceName)"
    }
}

function Ensure-TradeNetWireGuardGui {
    param(
        [pscustomobject]$Config,
        [string]$LogPath
    )

    if (-not (Test-Path -LiteralPath $Config.WireGuardGui)) {
        Write-TradeNetLog -Message ("未找到 WireGuard GUI: {0}" -f $Config.WireGuardGui) -Path $LogPath -Level "WARN"
        return
    }

    $runningGui = Get-Process -Name "wireguard" -ErrorAction SilentlyContinue
    if ($runningGui) {
        Write-TradeNetLog -Message "WireGuard GUI 已在运行。" -Path $LogPath
        return
    }

    Write-TradeNetLog -Message "打开 WireGuard GUI。" -Path $LogPath
    Start-Process -FilePath $Config.WireGuardGui | Out-Null
}

function Get-TradeNetPingWindowProcesses {
    param(
        [pscustomobject]$Config,
        [hashtable]$Target
    )

    return @(
        Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -and $_.CommandLine -match [regex]::Escape($Target.Title)
        }
    )
}

function Ensure-TradeNetPingWindows {
    param(
        [pscustomobject]$Config,
        [string]$LogPath
    )

    foreach ($target in $Config.PingTargets) {
        $existing = Get-TradeNetPingWindowProcesses -Config $Config -Target $target
        if ($existing) {
            Write-TradeNetLog -Message ("Ping 窗口已存在: {0}" -f $target.Host) -Path $LogPath
            continue
        }

        $command = "title {0} && ping {1} -t" -f $target.Title, $target.Host
        Start-Process -FilePath "cmd.exe" -ArgumentList "/k", $command -WindowStyle Normal | Out-Null
        Write-TradeNetLog -Message ("已启动 Ping 窗口: {0}" -f $target.Host) -Path $LogPath
        Start-Sleep -Milliseconds 500
    }
}

function Stop-TradeNetPingWindows {
    param(
        [pscustomobject]$Config,
        [string]$LogPath,
        [switch]$Quiet
    )

    $stopped = $false
    foreach ($target in $Config.PingTargets) {
        $processes = Get-TradeNetPingWindowProcesses -Config $Config -Target $target
        foreach ($process in $processes) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
            $stopped = $true
            if (-not $Quiet) {
                Write-TradeNetLog -Message ("已关闭 Ping 窗口: {0}" -f $target.Host) -Path $LogPath
            }
        }
    }

    if (-not $stopped -and -not $Quiet) {
        Write-TradeNetLog -Message "未发现需要关闭的 Ping 窗口。" -Path $LogPath
    }
}

function Resolve-TradeNetWgExe {
    param([pscustomobject]$Config)

    if (Test-Path -LiteralPath $Config.WgExe) {
        return $Config.WgExe
    }

    $wgCommand = Get-Command wg.exe -ErrorAction SilentlyContinue
    if ($wgCommand) {
        return $wgCommand.Source
    }

    return $null
}

function Get-TradeNetWgStatus {
    param([pscustomobject]$Config)

    $service = Get-Service -Name $Config.WireGuardServiceName -ErrorAction SilentlyContinue
    $serviceState = if ($service) { $service.Status.ToString().ToUpperInvariant() } else { "NOT FOUND" }

    $wgExe = Resolve-TradeNetWgExe -Config $Config
    $cliState = "WG.EXE NOT FOUND"
    $handshakeLine = ""
    $transferLine = ""
    $rawText = ""

    if ($wgExe) {
        try {
            $rawText = (& $wgExe show 2>$null | Out-String).Trim()
            if (-not $rawText) {
                $rawText = (& $wgExe 2>$null | Out-String).Trim()
            }

            if ($rawText) {
                $cliState = "CONNECTED"
                $lines = $rawText -split "`r?`n"
                $handshakeLine = ($lines | Where-Object { $_ -match "latest handshake" } | Select-Object -First 1)
                $transferLine = ($lines | Where-Object { $_ -match "^transfer:" -or $_ -match "transfer" } | Select-Object -First 1)
            } else {
                $cliState = "NO OUTPUT"
            }
        } catch {
            $cliState = "WG.EXE ERROR"
        }
    }

    return [pscustomobject]@{
        ServiceState  = $serviceState
        CliState      = $cliState
        HandshakeLine = $handshakeLine
        TransferLine  = $transferLine
        RawText       = $rawText
    }
}

function Invoke-TradeNetPing {
    param(
        [string]$Address,
        [int]$TimeoutMilliseconds = 1000
    )

    $ping = $null
    try {
        $ping = [System.Net.NetworkInformation.Ping]::new()
        $reply = $ping.Send($Address, $TimeoutMilliseconds)
        if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            return [pscustomobject]@{
                Success       = $true
                Display       = "{0} ms" -f $reply.RoundtripTime
                RoundtripTime = $reply.RoundtripTime
            }
        }

        return [pscustomobject]@{
            Success       = $false
            Display       = $reply.Status.ToString()
            RoundtripTime = $null
        }
    } catch {
        return [pscustomobject]@{
            Success       = $false
            Display       = "Error"
            RoundtripTime = $null
        }
    } finally {
        if ($ping) {
            $ping.Dispose()
        }
    }
}

function Resolve-TradeNetActiveLogPath {
    param(
        [pscustomobject]$Config,
        [string]$FallbackPath
    )

    $state = Load-TradeNetState -Config $Config
    if ($state -and $state.MainLog -and (Test-Path -LiteralPath $state.MainLog)) {
        return $state.MainLog
    }

    return $FallbackPath
}

function Get-TradeNetRuntimeStatus {
    param([pscustomobject]$Config)

    $udpProcesses = @(Get-TradeNetProcessByPath -ExecutablePath $Config.Udp2rawExe)
    $listenerBound = Test-TradeNetPortBound -Address $Config.Udp2rawListenHost -Port $Config.Udp2rawListenPort
    $routeOk = Test-TradeNetHostRoute -Config $Config
    $wgStatus = Get-TradeNetWgStatus -Config $Config
    $manualStopRequested = Test-TradeNetManualStopFlag -Config $Config

    $gatewayPing = $null
    $internetPing = $null
    if ($Config.PingTargets.Count -ge 1) {
        $gatewayPing = Invoke-TradeNetPing -Address $Config.PingTargets[0].Host
    }

    if ($Config.PingTargets.Count -ge 2) {
        $internetPing = Invoke-TradeNetPing -Address $Config.PingTargets[1].Host
    }

    $reasons = [System.Collections.Generic.List[string]]::new()
    if (-not $routeOk) { $null = $reasons.Add("VPS 主机路由缺失") }
    if ($udpProcesses.Count -eq 0) { $null = $reasons.Add("udp2raw 未运行") }
    if (-not $listenerBound) { $null = $reasons.Add("udp2raw 本地监听缺失") }
    if ($wgStatus.ServiceState -ne "RUNNING") { $null = $reasons.Add("WireGuard 服务未运行") }
    if ($gatewayPing -and -not $gatewayPing.Success) { $null = $reasons.Add("WireGuard 网关不可达") }
    if ($manualStopRequested) { $null = $reasons.Add("当前处于手动停止保护状态") }

    $healthy = $reasons.Count -eq 0
    $autoRestartEligible = (-not $manualStopRequested) -and (
        $udpProcesses.Count -eq 0 -or
        -not $listenerBound -or
        $wgStatus.ServiceState -ne "RUNNING" -or
        ($gatewayPing -and -not $gatewayPing.Success)
    )

    return [pscustomobject]@{
        Timestamp              = Get-Date
        RouteOk                = $routeOk
        Udp2rawRunning         = $udpProcesses.Count -gt 0
        Udp2rawPidText         = if ($udpProcesses) { ($udpProcesses.ProcessId -join ", ") } else { "" }
        ListenerBound          = $listenerBound
        WireGuardServiceState  = $wgStatus.ServiceState
        WireGuardCliState      = $wgStatus.CliState
        HandshakeLine          = $wgStatus.HandshakeLine
        TransferLine           = $wgStatus.TransferLine
        GatewayPingText        = if ($gatewayPing) { $gatewayPing.Display } else { "N/A" }
        GatewayPingOk          = if ($gatewayPing) { $gatewayPing.Success } else { $false }
        InternetPingText       = if ($internetPing) { $internetPing.Display } else { "N/A" }
        InternetPingOk         = if ($internetPing) { $internetPing.Success } else { $false }
        ManualStopRequested    = $manualStopRequested
        Healthy                = $healthy
        AutoRestartEligible    = $autoRestartEligible
        StateText              = if ($manualStopRequested) { "Stopped" } elseif ($healthy) { "Healthy" } else { "Unhealthy" }
        Reasons                = @($reasons.ToArray())
    }
}

function Start-TradeNetUdp2raw {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$LogContext
    )

    if (-not (Test-Path -LiteralPath $Config.Udp2rawExe)) {
        throw "未找到 udp2raw 可执行文件: $($Config.Udp2rawExe)"
    }

    Stop-TradeNetUdp2raw -Config $Config -LogPath $LogContext.MainLog -Quiet

    $udpArgs = @(
        "-c",
        "-l", $Config.Udp2rawListen,
        "-r", $Config.Udp2rawRemote,
        "-k", $Config.Udp2rawPassword,
        "--raw-mode", "faketcp",
        "--dev", $Config.Udp2rawDev
    )

    Write-TradeNetLog -Message ("启动 udp2raw: {0} {1}" -f $Config.Udp2rawExe, ($udpArgs -join " ")) -Path $LogContext.MainLog

    $process = Start-Process `
        -FilePath $Config.Udp2rawExe `
        -ArgumentList $udpArgs `
        -RedirectStandardOutput $LogContext.Udp2rawOutLog `
        -RedirectStandardError $LogContext.Udp2rawErrLog `
        -WindowStyle Hidden `
        -PassThru

    if (-not (Wait-TradeNetPortBound -Address $Config.Udp2rawListenHost -Port $Config.Udp2rawListenPort -TimeoutSeconds $Config.StartupTimeoutSeconds)) {
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }

        $stderrTail = Get-TradeNetTailText -Path $LogContext.Udp2rawErrLog -LineCount 20
        throw "udp2raw 启动后未在 $($Config.Udp2rawListen) 监听。stderr: $stderrTail"
    }

    Write-TradeNetLog -Message ("udp2raw 已就绪，PID={0}，监听 {1}" -f $process.Id, $Config.Udp2rawListen) -Path $LogContext.MainLog
    return $process
}

function Start-TradeNetStack {
    param(
        [pscustomobject]$Config,
        [pscustomobject]$LogContext,
        [switch]$OpenWireGuardGui,
        [switch]$OpenPingWindows
    )

    Assert-TradeNetAdministrator

    Write-TradeNetLog -Message "==== Start TradeNet ====" -Path $LogContext.MainLog
    Clear-TradeNetManualStopFlag -Config $Config
    Ensure-TradeNetHostRoute -Config $Config -LogPath $LogContext.MainLog

    $udpProcess = Start-TradeNetUdp2raw -Config $Config -LogContext $LogContext
    Restart-TradeNetWireGuardService -Config $Config -LogPath $LogContext.MainLog

    if ($OpenWireGuardGui) {
        Ensure-TradeNetWireGuardGui -Config $Config -LogPath $LogContext.MainLog
    }

    if ($OpenPingWindows) {
        Ensure-TradeNetPingWindows -Config $Config -LogPath $LogContext.MainLog
    }

    $wgStatus = Get-TradeNetWgStatus -Config $Config
    if ($wgStatus.HandshakeLine) {
        Write-TradeNetLog -Message ("WireGuard 握手状态: {0}" -f $wgStatus.HandshakeLine.Trim()) -Path $LogContext.MainLog
    } else {
        Write-TradeNetLog -Message "WireGuard 已启动，但尚未检测到握手。" -Path $LogContext.MainLog -Level "WARN"
    }

    Save-TradeNetState -Config $Config -State @{
        StartedAt      = (Get-Date).ToString("o")
        Udp2rawPid     = $udpProcess.Id
        Udp2rawExe     = $Config.Udp2rawExe
        ListenEndpoint = $Config.Udp2rawListen
        MainLog        = $LogContext.MainLog
        Udp2rawOutLog  = $LogContext.Udp2rawOutLog
        Udp2rawErrLog  = $LogContext.Udp2rawErrLog
        ServiceName    = $Config.WireGuardServiceName
    }

    return [pscustomobject]@{
        Udp2rawProcess = $udpProcess
        WgStatus       = $wgStatus
    }
}

function Stop-TradeNetStack {
    param(
        [pscustomobject]$Config,
        [string]$LogPath
    )

    Assert-TradeNetAdministrator
    Write-TradeNetLog -Message "==== Stop TradeNet ====" -Path $LogPath
    Set-TradeNetManualStopFlag -Config $Config

    $service = Get-Service -Name $Config.WireGuardServiceName -ErrorAction SilentlyContinue
    if ($service -and $service.Status -ne "Stopped") {
        Write-TradeNetLog -Message ("停止 WireGuard 服务: {0}" -f $Config.WireGuardServiceName) -Path $LogPath
        Stop-Service -Name $Config.WireGuardServiceName -Force -ErrorAction Stop
        if (-not (Wait-TradeNetServiceState -ServiceName $Config.WireGuardServiceName -DesiredState "Stopped" -TimeoutSeconds $Config.ServiceTimeoutSeconds)) {
            throw "WireGuard 服务停止超时: $($Config.WireGuardServiceName)"
        }
    } else {
        Write-TradeNetLog -Message "WireGuard 服务已经停止。" -Path $LogPath
    }

    Stop-TradeNetUdp2raw -Config $Config -LogPath $LogPath
    Stop-TradeNetPingWindows -Config $Config -LogPath $LogPath
    Clear-TradeNetState -Config $Config
}

function ConvertTo-TradeNetTaskDelay {
    param([int]$Seconds)

    $safeSeconds = [math]::Max(0, $Seconds)
    $hours = [math]::Floor($safeSeconds / 3600)
    $minutes = [math]::Floor(($safeSeconds % 3600) / 60)
    $remainingSeconds = $safeSeconds % 60
    return "PT{0}H{1}M{2}S" -f $hours, $minutes, $remainingSeconds
}

function Get-TradeNetWatchdogTaskStatus {
    param([pscustomobject]$Config)

    $taskName = [string]$Config.WatchdogTaskName
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) {
        return [pscustomobject]@{
            Exists         = $false
            TaskName       = $taskName
            State          = "NotInstalled"
            Enabled        = $false
            LastRunTime    = $null
            NextRunTime    = $null
            LastTaskResult = $null
            Summary        = "未安装"
        }
    }

    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    $state = [string]$task.State
    $enabled = $state -ne "Disabled"
    $lastTaskResult = if ($taskInfo) { $taskInfo.LastTaskResult } else { $null }
    $lastResultText = if ($null -eq $lastTaskResult) {
        "N/A"
    } else {
        "0x{0:X8}" -f ([uint32]$lastTaskResult)
    }
    $lastRunText = if ($taskInfo -and $taskInfo.LastRunTime -and $taskInfo.LastRunTime.Year -gt 2000) {
        $taskInfo.LastRunTime.ToString("yyyy-MM-dd HH:mm:ss")
    } else {
        "未运行"
    }

    return [pscustomobject]@{
        Exists         = $true
        TaskName       = $taskName
        State          = $state
        Enabled        = $enabled
        LastRunTime    = if ($taskInfo) { $taskInfo.LastRunTime } else { $null }
        NextRunTime    = if ($taskInfo) { $taskInfo.NextRunTime } else { $null }
        LastTaskResult = $lastTaskResult
        Summary        = ("{0} | 最近运行: {1} | 结果: {2}" -f $state, $lastRunText, $lastResultText)
    }
}

function Register-TradeNetWatchdogTask {
    param(
        [pscustomobject]$Config,
        [switch]$Replace,
        [switch]$StartNow
    )

    Assert-TradeNetAdministrator

    $agentPath = Join-Path $Config.ScriptRoot "TradeNetAgent.ps1"
    if (-not (Test-Path -LiteralPath $agentPath)) {
        throw "未找到 TradeNetAgent.ps1: $agentPath"
    }

    $existingTask = Get-ScheduledTask -TaskName $Config.WatchdogTaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        if (-not $Replace) {
            throw "开机守护任务已存在: $($Config.WatchdogTaskName)"
        }

        Stop-ScheduledTask -TaskName $Config.WatchdogTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $Config.WatchdogTaskName -Confirm:$false
    }

    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = ConvertTo-TradeNetTaskDelay -Seconds ([int]$Config.WatchdogStartupDelaySeconds)

    $restartIntervalMinutes = [math]::Max(1, [int]$Config.WatchdogRestartIntervalMinutes)
    $restartCount = [math]::Max(1, [int]$Config.WatchdogRestartCount)
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([timespan]::Zero) `
        -MultipleInstances IgnoreNew `
        -RestartCount $restartCount `
        -RestartInterval (New-TimeSpan -Minutes $restartIntervalMinutes) `
        -StartWhenAvailable

    $actionArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -StartupMode' -f $agentPath
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument $actionArgs

    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $description = "TradeNet 后台守护。开机自启，并在后台保活 udp2raw + WireGuard。"

    Register-ScheduledTask `
        -TaskName $Config.WatchdogTaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description $description `
        -Force | Out-Null

    if ($StartNow) {
        Start-ScheduledTask -TaskName $Config.WatchdogTaskName
    }

    return Get-TradeNetWatchdogTaskStatus -Config $Config
}

function Unregister-TradeNetWatchdogTask {
    param([pscustomobject]$Config)

    Assert-TradeNetAdministrator

    $task = Get-ScheduledTask -TaskName $Config.WatchdogTaskName -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName $Config.WatchdogTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $Config.WatchdogTaskName -Confirm:$false
    }
}
