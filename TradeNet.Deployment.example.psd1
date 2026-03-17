@{
    Server = @{
        Host                  = "203.0.113.10"
        Port                  = 22
        User                  = "root"
        Password              = "CHANGE_ME"
        PublicEndpoint        = "203.0.113.10"
        PublicInterface       = "eth0"
        WireGuardInterface    = "wg0"
        WireGuardSubnet       = "10.77.0.0/24"
        ServerAddress         = "10.77.0.1/24"
        ClientAddress         = "10.77.0.2/24"
        ClientAllowedIp       = "10.77.0.2/32"
        WireGuardListenPort   = 24008
        WireGuardMtu          = 1360
        ClientListenPort      = 45001
        ClientDns             = "1.1.1.1"
        ClientAllowedRoutes   = @("0.0.0.0/1", "128.0.0.0/1")
        PersistentKeepalive   = 25
        Udp2rawBinaryPath     = "/usr/local/bin/udp2raw"
        Udp2rawDownloadUrl    = ""
        Udp2rawPassword       = "CHANGE_ME"
        Udp2rawListenPort     = 4000
        Udp2rawMode           = "faketcp"
        ClientWireGuardHost   = "127.0.0.1"
        ClientWireGuardPort   = 24008
        Deployment            = @{
            ManageFirewall     = $true
            FirewallBackend    = "auto"
            ResetFirewall      = $false
            SshPort            = 22
            ManageSysctl       = $true
            ApplyGatewayTuning = $true
            VerifyAfterInstall = $true
        }
    }

    Client = @{
        Udp2rawExePath       = "D:\path\to\udp2raw_mp.exe"
        Udp2rawDev           = "\Device\NPF_{CHANGE_ME}"
        WireGuardServiceName = "WireGuardTunnel`$v1"
        LocalGateway         = "192.168.0.1"
        WireGuardGui         = "C:\Program Files\WireGuard\wireguard.exe"
        WgExe                = "C:\Program Files\WireGuard\wg.exe"
        MihomoExe            = "C:\Program Files\Clash Verge\verge-mihomo.exe"
        OpenWireGuardGui     = $true
        OpenPingWindows      = $true
        Deployment           = @{
            VerifyBinaries         = $true
            RunPreflightChecks     = $true
            InstallWireGuardTunnel = $false
            ReplaceExistingTunnel  = $false
            TunnelConfigName       = "v1"
            InstallWatchdogTask    = $true
            ReplaceWatchdogTask    = $true
            StartWatchdogAfterInstall = $true
            WatchdogTaskName       = "TradeNet-Watchdog"
            WatchdogStartupDelaySeconds = 20
            WatchdogRestartIntervalMinutes = 1
            WatchdogRestartCount   = 999
            IgnoreManualStopOnBoot = $true
        }
    }

    SplitRouting = @{
        DirectApps = @(
            "chrome.exe",
            "msedge.exe",
            "msedgewebview2.exe",
            "firefox.exe",
            "steam.exe",
            "steamservice.exe",
            "steamwebhelper.exe",
            "gameoverlayui.exe",
            "gameoverlayui64.exe",
            "wegame.exe",
            "wegame_env.exe",
            "tgp_daemon.exe",
            "wegameservice.exe",
            "client_launcher.exe",
            "Assistant.exe",
            "udp2raw_mp.exe",
            "verge-mihomo.exe",
            "clash-verge.exe"
        )
        TradeApps = @(
            "OFT.Platform.exe",
            "ATASPlatform.exe",
            "Bookmap.exe",
            "RTraderPro.exe",
            "RTrader.exe",
            "RithmicTraderPro.exe"
        )
    }
}
