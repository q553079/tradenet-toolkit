@{
    MihomoExe        = "C:\Program Files\Clash Verge\verge-mihomo.exe"
    WorkingDirectory = "D:\TradeNet\mihomo"
    OutputConfigPath = "D:\TradeNet\mihomo\tradenet-split.yaml"

    WireGuard = @{
        Name                = "TradeNet-WG"
        Server              = "127.0.0.1"
        Port                = 24008
        IpCidr              = "10.77.0.2/24"
        PrivateKey          = "__FILL_PRIVATE_KEY__"
        PublicKey           = "__FILL_PUBLIC_KEY__"
        AllowedIPs          = @("0.0.0.0/1", "128.0.0.0/1")
        MTU                 = 1280
        UDP                 = $true
        PersistentKeepalive = 25
    }

    AppRules = @{
        Direct = @(
            "chrome.exe",
            "msedge.exe",
            "firefox.exe",
            "steam.exe",
            "steamwebhelper.exe",
            "gameoverlayui.exe",
            "gameoverlayui64.exe",
            "wegame.exe",
            "tgp_daemon.exe",
            "wegameservice.exe",
            "udp2raw_mp.exe",
            "verge-mihomo.exe",
            "clash-verge.exe"
        )
        TradeNet = @(
            "OFT.Platform.exe",
            "ATASPlatform.exe",
            "Bookmap.exe",
            "RTraderPro.exe",
            "RTrader.exe",
            "RithmicTraderPro.exe"
        )
    }

    DNS = @{
        Enable      = $true
        IPv6        = $false
        EnhancedMode = "redir-host"
        NameServers = @(
            "223.5.5.5",
            "1.1.1.1"
        )
    }

    TUN = @{
        Enable     = $true
        Stack      = "mixed"
        AutoRoute  = $true
        StrictRoute = $true
        DnsHijack  = @("any:53")
    }

    DefaultAction = "DIRECT"
    MixedPort     = 7890
    Controller    = "127.0.0.1:9097"
    LogLevel      = "info"
}
