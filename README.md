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
- `deploy/server/install-tradenet-server.sh`: Linux VPS installer
- `deploy/Deploy-TradeNetServer.ps1`: uploads and runs the VPS installer over SSH
- `deploy/Install-TradeNetClient.ps1`: renders local `TradeNet.Config.psd1` and
  `TradeNet.SplitRouting.psd1`
- `deploy/Setup-TradeNet.ps1`: one-command server + client bootstrap
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

For the current Windows `Clash Verge / Mihomo` split-routing workflow, including:

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
- install or reuse `udp2raw`
- generate server/client WireGuard keys if not provided
- write `/etc/wireguard/wg0.conf`
- write `/etc/systemd/system/udp2raw.service`
- optionally manage firewall rules and sysctl tuning in a strong-intervention mode
- enable `wg-quick@wg0` and `udp2raw`
- verify listeners and export reusable client artifacts under `/opt/tradenet/artifacts`

### Client

The Windows client installer will:

- generate `TradeNet.Config.psd1`
- generate `TradeNet.SplitRouting.psd1`
- write a reusable WireGuard import file to `artifacts\client-wireguard.conf`
- run preflight checks for local binaries
- optionally install or replace the local WireGuard tunnel service when explicitly enabled
- optionally install a SYSTEM-level watchdog scheduled task for boot autostart and crash recovery
- validate `mihomo\tradenet-split.yaml`

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
