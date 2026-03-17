#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must run as root." >&2
    exit 1
  fi
}

log() {
  printf '[TradeNet] %s\n' "$*"
}

to_bool() {
  case "${1:-false}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    echo "Missing required value: ${name}" >&2
    exit 1
  fi
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y wireguard iproute2 iptables curl ca-certificates jq ufw
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y wireguard-tools iproute iptables curl ca-certificates firewalld jq
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y wireguard-tools iproute iptables curl ca-certificates firewalld jq
  else
    echo "Unsupported package manager. Install wireguard, iptables, curl manually." >&2
    exit 1
  fi
}

ensure_udp2raw() {
  if [[ -x "${UDP2RAW_BINARY_PATH}" ]]; then
    return
  fi

  require_value "TRADENET_UDP2RAW_DOWNLOAD_URL" "${UDP2RAW_DOWNLOAD_URL}"
  curl -fsSL "${UDP2RAW_DOWNLOAD_URL}" -o "${UDP2RAW_BINARY_PATH}"
  chmod +x "${UDP2RAW_BINARY_PATH}"
}

generate_key_if_missing() {
  local path="$1"
  if [[ ! -s "${path}" ]]; then
    umask 077
    wg genkey > "${path}"
  fi
}

detect_firewall_backend() {
  if [[ "${FIREWALL_BACKEND}" != "auto" ]]; then
    printf '%s' "${FIREWALL_BACKEND}"
    return
  fi

  if command -v ufw >/dev/null 2>&1; then
    printf 'ufw'
    return
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    printf 'firewalld'
    return
  fi

  printf 'iptables'
}

apply_sysctl_profile() {
  if ! to_bool "${MANAGE_SYSCTL}"; then
    return
  fi

  cat > /etc/sysctl.d/99-tradenet.conf <<EOF
net.ipv4.ip_forward = 1
EOF

  if to_bool "${APPLY_GATEWAY_TUNING}"; then
    cat >> /etc/sysctl.d/99-tradenet.conf <<EOF
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.core.netdev_max_backlog = 4096
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF
  fi

  sysctl --system >/dev/null
}

configure_firewall() {
  if ! to_bool "${MANAGE_FIREWALL}"; then
    return
  fi

  local backend
  backend="$(detect_firewall_backend)"
  log "Configuring firewall via ${backend}"

  case "${backend}" in
    ufw)
      if to_bool "${RESET_FIREWALL}"; then
        yes | ufw reset >/dev/null
      fi
      ufw allow "${SSH_PORT}/tcp" >/dev/null
      if [[ "${UDP2RAW_MODE}" == "faketcp" ]]; then
        ufw allow "${UDP2RAW_LISTEN_PORT}/tcp" >/dev/null
      else
        ufw allow "${UDP2RAW_LISTEN_PORT}/udp" >/dev/null
      fi
      yes | ufw enable >/dev/null
      ;;
    firewalld)
      systemctl enable --now firewalld >/dev/null
      if to_bool "${RESET_FIREWALL}"; then
        firewall-cmd --complete-reload >/dev/null
      fi
      firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" >/dev/null
      if [[ "${UDP2RAW_MODE}" == "faketcp" ]]; then
        firewall-cmd --permanent --add-port="${UDP2RAW_LISTEN_PORT}/tcp" >/dev/null
      else
        firewall-cmd --permanent --add-port="${UDP2RAW_LISTEN_PORT}/udp" >/dev/null
      fi
      firewall-cmd --reload >/dev/null
      ;;
    iptables)
      if ! iptables -C INPUT -p tcp --dport "${SSH_PORT}" -j ACCEPT >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport "${SSH_PORT}" -j ACCEPT
      fi
      if [[ "${UDP2RAW_MODE}" == "faketcp" ]]; then
        if ! iptables -C INPUT -p tcp --dport "${UDP2RAW_LISTEN_PORT}" -j ACCEPT >/dev/null 2>&1; then
          iptables -I INPUT -p tcp --dport "${UDP2RAW_LISTEN_PORT}" -j ACCEPT
        fi
      else
        if ! iptables -C INPUT -p udp --dport "${UDP2RAW_LISTEN_PORT}" -j ACCEPT >/dev/null 2>&1; then
          iptables -I INPUT -p udp --dport "${UDP2RAW_LISTEN_PORT}" -j ACCEPT
        fi
      fi
      ;;
    none)
      ;;
    *)
      echo "Unsupported firewall backend: ${backend}" >&2
      exit 1
      ;;
  esac
}

write_health_report() {
  cat > "${ARTIFACT_DIR}/server-health.txt" <<EOF
TradeNet server health snapshot
Generated at: $(date -Is)

== systemctl ==
$(systemctl is-active "wg-quick@${WG_IFACE}.service" 2>/dev/null || true)
$(systemctl is-active udp2raw.service 2>/dev/null || true)

== listeners ==
$(ss -lntup 2>/dev/null || true)

== wg ==
$(wg show "${WG_IFACE}" 2>/dev/null || true)

== routes ==
$(ip route 2>/dev/null || true)
EOF
}

verify_install() {
  if ! to_bool "${VERIFY_AFTER_INSTALL}"; then
    return
  fi

  systemctl is-active --quiet "wg-quick@${WG_IFACE}.service"
  systemctl is-active --quiet udp2raw.service

  if [[ "${UDP2RAW_MODE}" == "faketcp" ]]; then
    ss -lnt | grep -q ":${UDP2RAW_LISTEN_PORT} "
  else
    ss -lnu | grep -q ":${UDP2RAW_LISTEN_PORT} "
  fi

  ss -lnu | grep -q ":${WG_LISTEN_PORT} "
}

json_array_from_csv() {
  local csv="$1"
  local first=1
  local item
  printf "["
  IFS=',' read -ra items <<< "${csv}"
  for item in "${items[@]}"; do
    item="$(echo "${item}" | xargs)"
    if [[ -z "${item}" ]]; then
      continue
    fi
    if [[ "${first}" -eq 0 ]]; then
      printf ", "
    fi
    printf "\"%s\"" "${item}"
    first=0
  done
  printf "]"
}

require_root

WG_IFACE="${TRADENET_WG_IFACE:-wg0}"
PUBLIC_INTERFACE="${TRADENET_PUBLIC_INTERFACE:-eth0}"
PUBLIC_ENDPOINT="${TRADENET_PUBLIC_ENDPOINT:-}"
WG_SUBNET="${TRADENET_WG_SUBNET:-10.77.0.0/24}"
SERVER_ADDRESS="${TRADENET_SERVER_ADDRESS:-10.77.0.1/24}"
CLIENT_ADDRESS="${TRADENET_CLIENT_ADDRESS:-10.77.0.2/24}"
CLIENT_ALLOWED_IP="${TRADENET_CLIENT_ALLOWED_IP:-10.77.0.2/32}"
WG_LISTEN_PORT="${TRADENET_WG_LISTEN_PORT:-24008}"
WG_MTU="${TRADENET_WG_MTU:-1360}"
CLIENT_LISTEN_PORT="${TRADENET_CLIENT_LISTEN_PORT:-45001}"
CLIENT_DNS="${TRADENET_CLIENT_DNS:-1.1.1.1}"
CLIENT_ALLOWED_ROUTES="${TRADENET_CLIENT_ALLOWED_ROUTES:-0.0.0.0/1,128.0.0.0/1}"
PERSISTENT_KEEPALIVE="${TRADENET_PERSISTENT_KEEPALIVE:-25}"
CLIENT_WG_HOST="${TRADENET_CLIENT_WG_HOST:-127.0.0.1}"
CLIENT_WG_PORT="${TRADENET_CLIENT_WG_PORT:-24008}"
UDP2RAW_BINARY_PATH="${TRADENET_UDP2RAW_BINARY_PATH:-/usr/local/bin/udp2raw}"
UDP2RAW_DOWNLOAD_URL="${TRADENET_UDP2RAW_DOWNLOAD_URL:-}"
UDP2RAW_PASSWORD="${TRADENET_UDP2RAW_PASSWORD:-}"
UDP2RAW_LISTEN_PORT="${TRADENET_UDP2RAW_LISTEN_PORT:-4000}"
UDP2RAW_MODE="${TRADENET_UDP2RAW_MODE:-faketcp}"
STATE_ROOT="${TRADENET_STATE_ROOT:-/opt/tradenet}"
ARTIFACT_DIR="${STATE_ROOT}/artifacts"
WG_DIR="/etc/wireguard"
MANAGE_FIREWALL="${TRADENET_MANAGE_FIREWALL:-true}"
FIREWALL_BACKEND="${TRADENET_FIREWALL_BACKEND:-auto}"
RESET_FIREWALL="${TRADENET_RESET_FIREWALL:-false}"
SSH_PORT="${TRADENET_SSH_PORT:-22}"
MANAGE_SYSCTL="${TRADENET_MANAGE_SYSCTL:-true}"
APPLY_GATEWAY_TUNING="${TRADENET_APPLY_GATEWAY_TUNING:-true}"
VERIFY_AFTER_INSTALL="${TRADENET_VERIFY_AFTER_INSTALL:-true}"

require_value "TRADENET_PUBLIC_ENDPOINT" "${PUBLIC_ENDPOINT}"
require_value "TRADENET_UDP2RAW_PASSWORD" "${UDP2RAW_PASSWORD}"

install_packages
ensure_udp2raw

mkdir -p "${WG_DIR}" "${ARTIFACT_DIR}"
chmod 700 "${WG_DIR}"

SERVER_KEY_PATH="${WG_DIR}/server.key"
CLIENT_KEY_PATH="${WG_DIR}/client.key"
SERVER_PUB_PATH="${WG_DIR}/server.pub"
CLIENT_PUB_PATH="${WG_DIR}/client.pub"

generate_key_if_missing "${SERVER_KEY_PATH}"
generate_key_if_missing "${CLIENT_KEY_PATH}"

SERVER_PRIVATE_KEY="$(cat "${SERVER_KEY_PATH}")"
CLIENT_PRIVATE_KEY="$(cat "${CLIENT_KEY_PATH}")"
SERVER_PUBLIC_KEY="$(printf "%s" "${SERVER_PRIVATE_KEY}" | wg pubkey)"
CLIENT_PUBLIC_KEY="$(printf "%s" "${CLIENT_PRIVATE_KEY}" | wg pubkey)"

printf "%s" "${SERVER_PUBLIC_KEY}" > "${SERVER_PUB_PATH}"
printf "%s" "${CLIENT_PUBLIC_KEY}" > "${CLIENT_PUB_PATH}"
chmod 600 "${SERVER_KEY_PATH}" "${CLIENT_KEY_PATH}" "${SERVER_PUB_PATH}" "${CLIENT_PUB_PATH}"

cat > "${WG_DIR}/${WG_IFACE}.conf" <<EOF
[Interface]
Address = ${SERVER_ADDRESS}
ListenPort = ${WG_LISTEN_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}
MTU = ${WG_MTU}

PostUp = iptables -A FORWARD -i ${WG_IFACE} -o ${PUBLIC_INTERFACE} -j ACCEPT
PostUp = iptables -A FORWARD -i ${PUBLIC_INTERFACE} -o ${WG_IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s ${WG_SUBNET} -o ${PUBLIC_INTERFACE} -j MASQUERADE

PostDown = iptables -D FORWARD -i ${WG_IFACE} -o ${PUBLIC_INTERFACE} -j ACCEPT
PostDown = iptables -D FORWARD -i ${PUBLIC_INTERFACE} -o ${WG_IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET} -o ${PUBLIC_INTERFACE} -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_ALLOWED_IP}
EOF
chmod 600 "${WG_DIR}/${WG_IFACE}.conf"

cat > /etc/systemd/system/udp2raw.service <<EOF
[Unit]
Description=udp2raw server for TradeNet
After=network.target wg-quick@${WG_IFACE}.service
Wants=wg-quick@${WG_IFACE}.service

[Service]
Type=simple
ExecStart=${UDP2RAW_BINARY_PATH} -s -l0.0.0.0:${UDP2RAW_LISTEN_PORT} -r127.0.0.1:${WG_LISTEN_PORT} -k "${UDP2RAW_PASSWORD}" --raw-mode ${UDP2RAW_MODE} -a
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

apply_sysctl_profile
configure_firewall

systemctl daemon-reload
systemctl enable --now "wg-quick@${WG_IFACE}.service"
systemctl enable --now udp2raw.service

cat > "${ARTIFACT_DIR}/client-wireguard.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
ListenPort = ${CLIENT_LISTEN_PORT}
Address = ${CLIENT_ADDRESS}
DNS = ${CLIENT_DNS}
MTU = 1280

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
AllowedIPs = ${CLIENT_ALLOWED_ROUTES}
Endpoint = ${CLIENT_WG_HOST}:${CLIENT_WG_PORT}
PersistentKeepalive = ${PERSISTENT_KEEPALIVE}
EOF

cat > "${ARTIFACT_DIR}/tradenet-client-artifact.json" <<EOF
{
  "generated_at": "$(date -Is)",
  "server": {
    "public_endpoint": "${PUBLIC_ENDPOINT}",
    "public_interface": "${PUBLIC_INTERFACE}",
    "wireguard_interface": "${WG_IFACE}",
    "wireguard_subnet": "${WG_SUBNET}",
    "server_address": "${SERVER_ADDRESS}",
    "wireguard_public_key": "${SERVER_PUBLIC_KEY}",
    "wireguard_listen_port": ${WG_LISTEN_PORT}
  },
  "client": {
    "address": "${CLIENT_ADDRESS}",
    "listen_port": ${CLIENT_LISTEN_PORT},
    "dns": "${CLIENT_DNS}",
    "mtu": 1280,
    "private_key": "${CLIENT_PRIVATE_KEY}",
    "allowed_routes": $(json_array_from_csv "${CLIENT_ALLOWED_ROUTES}"),
    "persistent_keepalive": ${PERSISTENT_KEEPALIVE},
    "wireguard_host": "${CLIENT_WG_HOST}",
    "wireguard_port": ${CLIENT_WG_PORT}
  },
  "udp2raw": {
    "password": "${UDP2RAW_PASSWORD}",
    "listen_port": ${UDP2RAW_LISTEN_PORT},
    "mode": "${UDP2RAW_MODE}"
  }
}
EOF

cat > "${ARTIFACT_DIR}/server-summary.txt" <<EOF
TradeNet server bootstrap completed.
Server public endpoint: ${PUBLIC_ENDPOINT}
WireGuard interface: ${WG_IFACE}
WireGuard address: ${SERVER_ADDRESS}
udp2raw listen port: ${UDP2RAW_LISTEN_PORT}
Firewall management: ${MANAGE_FIREWALL} (${FIREWALL_BACKEND})
Artifacts:
  ${ARTIFACT_DIR}/client-wireguard.conf
  ${ARTIFACT_DIR}/tradenet-client-artifact.json
  ${ARTIFACT_DIR}/server-health.txt
EOF

verify_install
write_health_report
wg show "${WG_IFACE}" || true
echo "TradeNet server setup completed."
