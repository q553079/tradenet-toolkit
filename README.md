# TradeNet Toolkit

TradeNet Toolkit packages a `udp2raw + WireGuard + optional Mihomo split-routing`
stack into a reusable client/server toolchain.

It is designed for:

- Linux VPS: one script installs WireGuard, `udp2raw`, NAT, and systemd services
- Windows client: one script renders local TradeNet configs, split-routing configs,
  and validates Mihomo YAML
- Existing operators: the included dashboard can monitor the tunnel, rebuild split
  routing config, and inspect logs

## What is included

- `TradeNetDashboard.ps1`: Windows dashboard for start/stop/monitor/logs
- `TradeNetMonitor.ps1`: console watchdog
- `TradeNetAgent.ps1`: headless watchdog for scheduled-task autostart
- `Register-TradeNetWatchdog.ps1`: registers the Windows boot watchdog task
- `Unregister-TradeNetWatchdog.ps1`: removes the Windows boot watchdog task
- `Build-TradeNetMihomoConfig.ps1`: renders and validates Mihomo split-routing YAML
- `Build-TradeNetClashConfig.ps1`: renders a pure `TradeNet` Clash profile for standalone import
- `deploy/server/install-tradenet-server.sh`: Linux VPS installer
- `deploy/server/install-tradenet-tcp-fallback.sh`: optional TCP fallback installer for mobile subscription
- `deploy/Deploy-TradeNetServer.ps1`: uploads and runs the VPS installer over SSH
- `deploy/Install-TradeNetClient.ps1`: renders local `TradeNet.Config.psd1` and
  `TradeNet.SplitRouting.psd1`
- `deploy/Setup-TradeNet.ps1`: one-command server + client bootstrap
- `deploy/Initialize-WindowsSshTarget.ps1`: prepares a Windows machine for SSH-based deployment
- `deploy/Initialize-WindowsSshTarget-OneClick.ps1` and `.cmd`: guided wrapper for first-time Windows target bootstrap
- `deploy/Retry-Initialize-WithPublicDns.ps1` and `.cmd`: retries the Windows target bootstrap with temporary public DNS
- `deploy/Restore-DnsFromBackup.ps1`: restores the original DNS after the retry flow
- `clash-tcp-fallback.yaml`: sanitized mobile subscription template
- `contrib/hysteria2.sh`: standalone Hysteria2 installer provided as an additional
  reference script
- `doc/`: supplementary installation notes and operator-facing reference documents

## Quick start

1. Copy `TradeNet.Deployment.example.psd1`
   to `TradeNet.Deployment.psd1`.
2. Fill the VPS SSH settings, `udp2raw` password, and local client paths.
3. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\Setup-TradeNet.ps1
```

4. After setup completes, open:

```powershell
.\Run-TradeNetDashboard.bat
```

Do not run `Setup-TradeNet.ps1` during active trading. It is a deployment
workflow and may rewrite the server-side WireGuard and `udp2raw` configuration.

## Chinese operation guide

For the full VPS-to-Windows deployment workflow and the current
`Clash Verge / Mihomo` split-routing workflow, including:

- what must be prepared on the VPS and on Windows
- how to fill `TradeNet.Deployment.psd1`
- what the automated deployment does for the server and the client
- how to do the one-time manual Clash Verge import
- how to enable later automatic Clash profile sync
- how to start, stop, verify, and troubleshoot the live stack

see:

- [doc/TradeNet-Deployment.zh-CN.md](doc/TradeNet-Deployment.zh-CN.md)

For the narrower day-2 split-routing usage guide, including:

- the active split-routing design
- how to start and stop `TradeNet`
- how to rebuild and sync the local Clash profile
- how to verify that ATAS / Rithmic is using `udp2raw + TradeNet-WG`

see:

- [doc/Clash-Verge-SplitRouting.zh-CN.md](doc/Clash-Verge-SplitRouting.zh-CN.md)

## Deployment model

### Server

The VPS installer will:

- install WireGuard and supporting packages
- install or reuse `udp2raw` and auto-download the standard Linux release archive when needed
- generate server/client WireGuard keys if not provided
- write `/etc/wireguard/wg0.conf`
- write `/etc/systemd/system/udp2raw.service`
- optionally manage firewall rules and sysctl tuning in a strong-intervention mode
- enable `wg-quick@wg0` and `udp2raw`
- verify listeners and export reusable client artifacts under `/opt/tradenet/artifacts`

Optional mobile fallback:

- `deploy/server/install-tradenet-tcp-fallback.sh` can install a small `shadowsocks-libev + nginx`
  stack on the same VPS
- the script publishes a Clash-compatible subscription YAML over HTTP for phone/iPad import
- the script also writes a reusable summary, a subscription copy, and a short mobile guide under
  `/opt/tradenet/artifacts`
- use the committed `clash-tcp-fallback.yaml` only as a template; do not commit real passwords

### Client

The Windows client installer will:

- generate `TradeNet.Config.psd1`
- generate `TradeNet.SplitRouting.psd1`
- write a reusable WireGuard import file to `artifacts\client-wireguard.conf`
- optionally build a pure `TradeNet` Clash profile via `Build-TradeNetClashConfig.ps1`
- run preflight checks for local binaries
- optionally install or replace the local WireGuard tunnel service when explicitly enabled
- optionally install a SYSTEM-level watchdog scheduled task for boot autostart and crash recovery
- validate `mihomo\tradenet-split.yaml`

### Windows SSH Target

If you need to turn another Windows machine into an SSH deployment target:

- run `deploy/Initialize-WindowsSshTarget-OneClick.ps1` or the matching `.cmd` wrapper as administrator
- use `deploy/Initialize-WindowsSshTarget.ps1` directly when you want non-interactive parameters
- if OpenSSH installation fails because the machine cannot resolve Microsoft or GitHub endpoints, retry with `deploy/Retry-Initialize-WithPublicDns.ps1`
- restore the previous DNS settings afterward with `deploy/Restore-DnsFromBackup.ps1`

## Repository safety

Real secrets are intentionally excluded from git:

- `TradeNet.Config.psd1`
- `TradeNet.SplitRouting.psd1`
- `TradeNet.Deployment.psd1`
- `logs/`, `state/`, `mihomo/`, `artifacts/`

Only example profiles and templates are committed.

## Strong-intervention deployment

The deployment profile includes explicit strong-intervention toggles for both the
server and the client.

Server-side deployment can:

- install missing packages
- manage firewall rules
- apply sysctl gateway tuning
- verify service and listener health after installation

Client-side deployment can:

- verify required binaries before rendering config
- generate a preflight report
- optionally install or replace the local WireGuard tunnel service
- optionally register a system-level watchdog task that auto-starts on boot
- keep the tunnel alive even after the dashboard window is closed

These actions are intentionally controlled by profile flags so you can choose
between a conservative render-only workflow and a more aggressive setup flow.

## Additional scripts

`contrib/hysteria2.sh` is included as a standalone Hysteria2 deployment script.
It is not part of the default `TradeNet` deployment path.

Use it when you want a separate Hysteria2 node workflow with:

- automatic Hysteria2 installation
- certificate generation
- firewall setup
- client config rendering

Review it before production use. It resets firewall rules, rewrites `sysctl`
network settings, and is opinionated about SNI, obfuscation, and BBR removal.
