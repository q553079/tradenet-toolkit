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
        AllowedIPs          = @("0.0.0.0/0")
        MTU                 = 1280
        UDP                 = $true
        PersistentKeepalive = 25
        RemoteDnsResolve    = $true
        Dns                 = @(
            "1.1.1.1",
            "8.8.8.8"
        )
    }

    AppRules = @{
        Direct = @(
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
            "LeagueClient.exe",
            "LeagueClientUx.exe",
            "LeagueClientUxRender.exe",
            "League of Legends.exe",
            "cross.exe",
            "Assistant.exe",
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
            "RithmicTraderPro.exe",
            "ChatGPT.exe",
            "Codex.exe"
        )
    }

    CustomRules = @(
        "DOMAIN-SUFFIX,rithmic.com,TradeNet",
        "DOMAIN-SUFFIX,atas.net,TradeNet",
        "DOMAIN-SUFFIX,orderflowtrading.net,TradeNet",
        "DOMAIN-KEYWORD,rithmic,TradeNet",
        "DOMAIN-SUFFIX,github.com,TradeNet",
        "DOMAIN-SUFFIX,githubusercontent.com,TradeNet",
        "DOMAIN-SUFFIX,githubassets.com,TradeNet",
        "DOMAIN-SUFFIX,github.io,TradeNet",
        "DOMAIN-SUFFIX,reddit.com,TradeNet",
        "DOMAIN-SUFFIX,redd.it,TradeNet",
        "DOMAIN-SUFFIX,redditmedia.com,TradeNet",
        "DOMAIN-SUFFIX,redditstatic.com,TradeNet",
        "DOMAIN-SUFFIX,discord.com,TradeNet",
        "DOMAIN-SUFFIX,discord.gg,TradeNet",
        "DOMAIN-SUFFIX,discord.media,TradeNet",
        "DOMAIN-SUFFIX,discordapp.com,TradeNet",
        "DOMAIN-SUFFIX,discordapp.net,TradeNet",
        "DOMAIN-SUFFIX,docker.com,TradeNet",
        "DOMAIN-SUFFIX,docker.io,TradeNet",
        "DOMAIN-SUFFIX,pornhub.com,TradeNet",
        "DOMAIN-SUFFIX,phncdn.com,TradeNet",
        "DOMAIN-SUFFIX,trafficjunky.net,TradeNet",
        "DOMAIN-SUFFIX,xvideos.com,TradeNet",
        "DOMAIN-SUFFIX,xvideos-cdn.com,TradeNet",
        "DOMAIN-SUFFIX,xvideos.co.cz,TradeNet",
        "DOMAIN-SUFFIX,orbsrv.com,TradeNet",
        "DOMAIN-SUFFIX,xlivrdr.com,TradeNet",
        "DOMAIN-SUFFIX,mmcdn.com,TradeNet",
        "DOMAIN-SUFFIX,xnxx.com,TradeNet",
        "DOMAIN-SUFFIX,xhamster.com,TradeNet",
        "DOMAIN-SUFFIX,redtube.com,TradeNet",
        "DOMAIN-SUFFIX,api.deepseek.com,DIRECT",
        "DOMAIN-SUFFIX,platform.deepseek.com,DIRECT",
        "DOMAIN-SUFFIX,deepseek.com,DIRECT",
        "DOMAIN-SUFFIX,openai.com,TradeNet",
        "DOMAIN-SUFFIX,chatgpt.com,TradeNet",
        "DOMAIN-SUFFIX,oaistatic.com,TradeNet",
        "DOMAIN-SUFFIX,oaiusercontent.com,TradeNet",
        "DOMAIN-KEYWORD,antigravity,TradeNet",
        "DOMAIN-KEYWORD,codex,TradeNet",
        "GEOSITE,google,TradeNet",
        "GEOSITE,youtube,TradeNet",
        "DOMAIN-SUFFIX,googlevideo.com,TradeNet",
        "DOMAIN-SUFFIX,ytimg.com,TradeNet",
        "DOMAIN-SUFFIX,tradingview.com,TradeNet",
        "DOMAIN-SUFFIX,missav.ws,TradeNet",
        "DOMAIN-SUFFIX,netflav.com,TradeNet",
        "DOMAIN-SUFFIX,cmegroup.com,TradeNet",
        "DOMAIN-SUFFIX,cboe.com,TradeNet",
        "DOMAIN-SUFFIX,gvt1.com,TradeNet",
        "DOMAIN-SUFFIX,gvt2.com,TradeNet",
        "DOMAIN-SUFFIX,googleapis.com,TradeNet"
    )

    DNS = @{
        Enable             = $true
        IPv6               = $false
        EnhancedMode       = "redir-host"
        DefaultNameServers = @(
            "223.5.5.5",
            "119.29.29.29"
        )
        NameServers        = @(
            "https://doh.pub/dns-query",
            "https://dns.alidns.com/dns-query"
        )
        FallbackNameServers = @(
            "1.1.1.1#TradeNet&disable-ipv6=true",
            "8.8.8.8#TradeNet&disable-ipv6=true"
        )
        ProxyServerNameServers = @(
            "https://doh.pub/dns-query",
            "https://dns.alidns.com/dns-query"
        )
        DirectNameServers = @(
            "https://doh.pub/dns-query",
            "https://dns.alidns.com/dns-query"
        )
        FallbackFilter    = @{
            GeoIp     = $true
            GeoIpCode = "CN"
            Domain    = @(
                "+.openai.com",
                "+.chatgpt.com",
                "+.oaistatic.com",
                "+.oaiusercontent.com",
                "+.github.com",
                "+.githubusercontent.com",
                "+.githubassets.com",
                "+.github.io",
                "+.reddit.com",
                "+.redd.it",
                "+.redditmedia.com",
                "+.redditstatic.com",
                "+.discord.com",
                "+.discord.gg",
                "+.discord.media",
                "+.discordapp.com",
                "+.discordapp.net",
                "+.docker.com",
                "+.docker.io",
                "+.pornhub.com",
                "+.phncdn.com",
                "+.trafficjunky.net",
                "+.xvideos.com",
                "+.xvideos-cdn.com",
                "+.xvideos.co.cz",
                "+.orbsrv.com",
                "+.xlivrdr.com",
                "+.mmcdn.com",
                "+.xnxx.com",
                "+.xhamster.com",
                "+.redtube.com",
                "+.google.com",
                "+.gstatic.com",
                "+.googleapis.com",
                "+.gvt1.com",
                "+.gvt2.com",
                "+.youtube.com",
                "+.youtu.be",
                "+.googlevideo.com",
                "+.ytimg.com"
                "+.tradingview.com",
                "+.missav.ws",
                "+.netflav.com",
                "+.cmegroup.com",
                "+.cboe.com"
            )
        }
    }

    Sniffer = @{
        Enable              = $true
        ForceDnsMapping     = $true
        ParsePureIp         = $true
        OverrideDestination = $true
        HttpPorts           = @(
            "80",
            "8080-8880"
        )
        TlsPorts            = @(
            "443",
            "8443"
        )
        QuicPorts           = @(
            "443",
            "8443"
        )
    }

    TUN = @{
        Enable      = $true
        Stack       = "mixed"
        AutoRoute   = $true
        StrictRoute = $true
        DnsHijack   = @("any:53", "tcp://any:53")
    }

    DefaultAction = "DIRECT"
    MixedPort     = 7890
    Controller    = "127.0.0.1:9097"
    LogLevel      = "info"
}
