@{
    # 复制为 TradeNet.Config.psd1 后生效。
    Udp2rawExe           = "D:\TradeNet\bin\udp2raw_mp.exe"
    Udp2rawDev           = "\Device\NPF_{CHANGE_ME}"
    Udp2rawListenHost    = "127.0.0.1"
    Udp2rawListenPort    = 24008

    VpsIp                = "203.0.113.10"
    Udp2rawRemotePort    = 4000
    Udp2rawPassword      = "CHANGE_ME"
    LocalGateway         = "192.168.0.1"

    WireGuardServiceName = "WireGuardTunnel`$tradenet"
    WireGuardGui         = "C:\Program Files\WireGuard\wireguard.exe"
    WgExe                = "C:\Program Files\WireGuard\wg.exe"

    StartupTimeoutSeconds = 20
    ServiceTimeoutSeconds = 20
    MonitorRefreshSeconds = 2

    AutoRestartEnabled   = $false
    AutoRestartThreshold = 3
    AutoRestartCooldown  = 20

    OpenWireGuardGui     = $true
    OpenPingWindows      = $true
}
