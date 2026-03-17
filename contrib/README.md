# Contrib Scripts

This directory contains standalone scripts that are useful alongside the main
TradeNet toolkit but are not part of the default client/server deployment flow.

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
