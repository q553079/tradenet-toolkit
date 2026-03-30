#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must run as root." >&2
    exit 1
  fi
}

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    echo "Missing required value: ${name}" >&2
    exit 1
  fi
}

ensure_packages() {
  apt-get update
  apt-get install -y shadowsocks-libev nginx ca-certificates ufw
}

enable_shadowsocks_service() {
  if systemctl list-unit-files | grep -q '^shadowsocks-libev\.service'; then
    systemctl enable shadowsocks-libev.service >/dev/null
    systemctl restart shadowsocks-libev.service
    return
  fi

  if systemctl list-unit-files | grep -q '^shadowsocks-libev-server@\.service'; then
    systemctl enable shadowsocks-libev-server@config.service >/dev/null
    systemctl restart shadowsocks-libev-server@config.service
    return
  fi

  echo "Unable to find a usable shadowsocks-libev systemd unit." >&2
  exit 1
}

write_subscription() {
  cat > "${SUBSCRIPTION_PATH}" <<EOF
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: false

proxies:
  - name: ${NODE_NAME}
    type: ss
    server: ${PUBLIC_ENDPOINT}
    port: ${SS_PORT}
    cipher: ${SS_CIPHER}
    password: ${SS_PASSWORD}
    udp: false

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - ${NODE_NAME}
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF
}

write_artifacts() {
  cp "${SUBSCRIPTION_PATH}" "${SUBSCRIPTION_ARTIFACT_PATH}"

  cat > "${MOBILE_GUIDE_PATH}" <<EOF
# TradeNet Mobile Subscription

Updated: $(date '+%Y-%m-%d %H:%M %Z')

For iPhone / iPad / mobile Clash import:

- Subscription URL: \`${SUBSCRIPTION_URL}\`
- Node name: \`${NODE_NAME}\`
- Type: \`ss\`
- Server: \`${PUBLIC_ENDPOINT}\`
- Port: \`${SS_PORT}\`
- Cipher: \`${SS_CIPHER}\`
- UDP: \`false\`

Artifact files:

- Subscription copy: \`${SUBSCRIPTION_ARTIFACT_PATH}\`
- Summary: \`${SUMMARY_PATH}\`
EOF
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 80/tcp >/dev/null
    ufw allow "${SS_PORT}/tcp" >/dev/null
  fi
}

write_summary() {
  cat > "${SUMMARY_PATH}" <<EOF
TradeNet TCP fallback deployed.
Public endpoint: ${PUBLIC_ENDPOINT}
Shadowsocks port: ${SS_PORT}
Cipher: ${SS_CIPHER}
Subscription URL: ${SUBSCRIPTION_URL}
Subscription file: ${SUBSCRIPTION_PATH}
Artifact copy: ${SUBSCRIPTION_ARTIFACT_PATH}
Guide: ${MOBILE_GUIDE_PATH}
EOF
}

verify_install() {
  systemctl is-active --quiet nginx

  if systemctl list-unit-files | grep -q '^shadowsocks-libev\.service'; then
    systemctl is-active --quiet shadowsocks-libev.service
  else
    systemctl is-active --quiet shadowsocks-libev-server@config.service
  fi

  ss -lnt | grep -q ":${SS_PORT} "
  ss -lnt | grep -q ':80 '
}

require_root

PUBLIC_ENDPOINT="${TRADENET_TCP_PUBLIC_ENDPOINT:-}"
SS_PORT="${TRADENET_TCP_SS_PORT:-443}"
SS_PASSWORD="${TRADENET_TCP_SS_PASSWORD:-}"
SS_CIPHER="${TRADENET_TCP_SS_CIPHER:-aes-256-gcm}"
SUBSCRIPTION_TOKEN="${TRADENET_TCP_SUBSCRIPTION_TOKEN:-}"
SUBSCRIPTION_PREFIX="${TRADENET_TCP_SUBSCRIPTION_PREFIX:-tcp-fallback}"
NODE_NAME="${TRADENET_TCP_NODE_NAME:-TradeNet_TCP}"
WEB_ROOT="${TRADENET_TCP_WEB_ROOT:-/var/www/html}"
STATE_ROOT="${TRADENET_STATE_ROOT:-/opt/tradenet}"
ARTIFACT_DIR="${STATE_ROOT}/artifacts"

require_value "TRADENET_TCP_PUBLIC_ENDPOINT" "${PUBLIC_ENDPOINT}"
require_value "TRADENET_TCP_SS_PASSWORD" "${SS_PASSWORD}"
require_value "TRADENET_TCP_SUBSCRIPTION_TOKEN" "${SUBSCRIPTION_TOKEN}"

SUBSCRIPTION_BASENAME="${SUBSCRIPTION_PREFIX}-${SUBSCRIPTION_TOKEN}.yaml"
SUBSCRIPTION_PATH="${WEB_ROOT}/${SUBSCRIPTION_BASENAME}"
SUBSCRIPTION_URL="http://${PUBLIC_ENDPOINT}/${SUBSCRIPTION_BASENAME}"
SUBSCRIPTION_ARTIFACT_PATH="${ARTIFACT_DIR}/tcp-fallback-subscription.yaml"
SUMMARY_PATH="${ARTIFACT_DIR}/tcp-fallback-summary.txt"
MOBILE_GUIDE_PATH="${ARTIFACT_DIR}/TradeNet2-Mobile-Subscription.md"

ensure_packages

mkdir -p /etc/shadowsocks-libev "${WEB_ROOT}" "${ARTIFACT_DIR}"

cat > /etc/shadowsocks-libev/config.json <<EOF
{
  "server": "0.0.0.0",
  "server_port": ${SS_PORT},
  "password": "${SS_PASSWORD}",
  "timeout": 300,
  "method": "${SS_CIPHER}",
  "mode": "tcp_only",
  "fast_open": false
}
EOF

write_subscription
write_artifacts
configure_firewall

systemctl enable --now nginx
systemctl restart nginx
enable_shadowsocks_service
write_summary
verify_install

echo "Subscription URL: ${SUBSCRIPTION_URL}"
