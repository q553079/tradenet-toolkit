# TradeNet Split-Routing Plan

Current TradeNet mode is a global WireGuard tunnel:

- `0.0.0.0/1` and `128.0.0.0/1` are routed to the `v1` interface
- browser, Steam, WeGame, and trading applications all leave through `10.77.0.2`
- this is why per-app routing cannot be solved by `AllowedIPs` alone

The clean split-routing design is:

1. Keep `udp2raw` as the transport shim
2. Stop using `WireGuardTunnel$v1` as the active data plane in split mode
3. Run `Mihomo` TUN as the system traffic entry point
4. Send trading processes to a `WireGuard` outbound that connects to `127.0.0.1:24008`
5. Send browser / Steam / WeGame traffic to `DIRECT`

Files added for this mode:

- `TradeNet.SplitRouting.example.psd1`: editable profile model
- `Build-TradeNetMihomoConfig.ps1`: renders a Mihomo YAML from the profile
- `Export-TradeNetAppInventory.ps1`: captures real process names and live connections

Detected process targets on this machine:

- Trading:
  - `OFT.Platform.exe` (ATAS)
  - `Bookmap.exe`
  - likely `RTraderPro.exe` if the standalone Rithmic terminal is used later
- Direct:
  - `chrome.exe`
  - `steam.exe`
  - `steamwebhelper.exe`
  - `gameoverlayui.exe`
  - `gameoverlayui64.exe`
  - `wegame.exe`
  - `tgp_daemon.exe`
  - `wegameservice.exe`
- Internal direct:
  - `udp2raw_mp.exe`
  - `verge-mihomo.exe`
  - `clash-verge.exe`

Before enabling split mode:

1. Extract the current WireGuard peer material while running an elevated shell.
2. Fill `WireGuard.PrivateKey` and `WireGuard.PublicKey` in `TradeNet.SplitRouting.psd1`.
3. Build the Mihomo config with `Build-TradeNetMihomoConfig.ps1`.
4. Validate the generated YAML with Mihomo's `-t` option.
5. Only after validation, schedule a maintenance window and switch away from the current full-tunnel `WireGuardTunnel$v1`.

Important:

- Do not enable split mode while actively trading.
- Do not run the current full-tunnel WireGuard service and Mihomo TUN as two simultaneous active data planes.
- Keep `udp2raw` and the Mihomo core itself routed `DIRECT`, or the tunnel can loop back into itself.
