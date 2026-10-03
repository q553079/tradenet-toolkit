# Contrib Scripts

This directory contains standalone scripts that are useful alongside the main
TradeNet toolkit but are not part of the default client/server deployment flow.

## Start-ClashHotspot.ps1 / .cmd

Starts the Windows mobile hotspot using the current Meta TUN adapter as its
upstream and a compatible 2.4 GHz band. Requires Windows PowerShell 5.1 and an
enabled Clash TUN. Adapter GUIDs are resolved at invocation rather than embedded.
The script preserves the saved hotspot name/password, restarts the hotspot, and
does not install an automatic switching task. Use `-UpstreamAdapterName` to
select a physical adapter before turning off TUN.

See [the hotspot guide](../doc/Clash-TUN-Hotspot.zh-CN.md) for configuration and
the observed Wi-Fi 7 / 5 GHz startup failure.

## hysteria2.sh

`hysteria2.sh` is a self-contained Hysteria2 deployment script with a polished
terminal UI and end-to-end server bootstrap behavior.

Notable characteristics:

- installs Hysteria2 directly from the upstream installer
- generates certificates and server/client config
- opens firewall ports automatically
- performs bandwidth probing and writes speed-based settings
- removes BBR-related sysctl settings and applies its own network tuning

Use it as a separate deployment path, not as a drop-in replacement for the
default `TradeNet` WireGuard + `udp2raw` stack.
