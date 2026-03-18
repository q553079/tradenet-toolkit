# TradeNet Split-Routing Plan

Chinese operation guide:

- [doc/Clash-Verge-SplitRouting.zh-CN.md](doc/Clash-Verge-SplitRouting.zh-CN.md)

Current split mode is designed around `Mihomo` TUN plus a local `WireGuard` outbound over `udp2raw`.

Stable design goals:

1. Keep `udp2raw` as the transport shim to the VPS.
2. Use `Mihomo` TUN as the only active split-routing data plane.
3. Route trading apps and a small overseas whitelist through `TradeNet-WG`.
4. Keep everything else `DIRECT` by default.
5. Avoid DNS pollution for Google / YouTube / OpenAI by forcing those lookups to use fallback resolvers through `TradeNet`.

Why this is more stable than the earlier broad rule set:

- We no longer use `GEOSITE,geolocation-!cn,TradeNet`.
- That broad rule was pushing large amounts of unrelated foreign traffic into the VPS path.
- Logs showed this included Windows probes, browser background traffic, Discord, Epic, VS Code telemetry, and other noise.
- The new profile is conservative: only trading apps, `ChatGPT.exe`, `Codex.exe`, and explicit Google / YouTube / OpenAI targets are sent into the tunnel.

Files for this mode:

- `TradeNet.SplitRouting.example.psd1`: editable profile model
- `TradeNet.SplitRouting.psd1`: active local profile
- `Build-TradeNetMihomoConfig.ps1`: renders and validates the Mihomo YAML
- `mihomo\tradenet-split.yaml`: generated runtime config

Current routing strategy:

- `TradeNet-WG` connects to `127.0.0.1:24008`
- `allowed-ips` is `0.0.0.0/0` inside the Mihomo outbound
- DNS uses `redir-host`
- `sniffer` is enabled to recover domains from TLS / HTTP / QUIC
- Google / YouTube / OpenAI DNS lookups are forced to fallback resolvers through `TradeNet`
- default rule remains `MATCH,DIRECT`

Direct traffic that must stay local:

- `udp2raw_mp.exe`
- `verge-mihomo.exe`
- `clash-verge.exe`
- Steam / WeGame / launcher processes listed in the profile

Traffic that is intentionally sent to `TradeNet`:

- trading apps such as `OFT.Platform.exe`, `ATASPlatform.exe`, `Bookmap.exe`
- `ChatGPT.exe`
- `Codex.exe`
- explicit trading domains such as `rithmic.com`, `atas.net`, `orderflowtrading.net`
- explicit domain families for `openai.com`, `chatgpt.com`, `google`, `youtube`, `googlevideo`, `ytimg`, `gvt1`, `gvt2`, `googleapis`

Operational notes:

1. Build with `powershell -ExecutionPolicy Bypass -File .\Build-TradeNetMihomoConfig.ps1`.
2. Confirm the generated YAML passes Mihomo validation.
3. Keep the imported Verge profile in sync with `mihomo\tradenet-split.yaml`.
4. After switching to `TradeNet分流`, test `chat.openai.com`, `chatgpt.com`, `www.google.com`, and `www.youtube.com`.
5. Inspect `service_latest.log` to confirm those requests match `TradeNet[TradeNet-WG]` without `context deadline exceeded` or `network is unreachable`.

Important:

- Do not enable split mode while actively trading.
- Do not run a separate full-tunnel WireGuard data plane at the same time as Mihomo TUN split mode.
- Keep the tunnel bootstrap path itself on `DIRECT`, or the stack can loop back into itself.
