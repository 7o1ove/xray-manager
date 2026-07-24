#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

MIHOMO_DIR="/etc/mihomo"
CONFIG_FILE="${MIHOMO_DIR}/config.yaml"
PROTOCOL_CONFIG="${MIHOMO_DIR}/protocols/mieru.yaml"
CLIENT_FILE="${MIHOMO_DIR}/client/mieru.txt"
BUILD_CONFIG_SCRIPT="${SCRIPT_DIR}/config/mihomo-build-config.sh"
MIN_MIHOMO_VERSION="1.19.21"
TRANSPORT="TCP"

rollback_config(){
    if [[ -n "$PROTOCOL_BACKUP" && -f "$PROTOCOL_BACKUP" ]]; then
        mv "$PROTOCOL_BACKUP" "$PROTOCOL_CONFIG"
    else
        rm -f "$PROTOCOL_CONFIG"
    fi

    if [[ -n "$CONFIG_BACKUP" && -f "$CONFIG_BACKUP" ]]; then
        mv "$CONFIG_BACKUP" "$CONFIG_FILE"
    else
        rm -f "$CONFIG_FILE"
    fi
}

for package in curl openssl coreutils iproute2; do
    if ! dpkg -s "$package" >/dev/null 2>&1; then
        info "正在安装 Mihomo Mieru 环境依赖..."
        apt update
        apt install -y curl openssl coreutils iproute2
        break
    fi
done

if command -v mihomo >/dev/null 2>&1; then
    MIHOMO_BIN="$(command -v mihomo)"
elif [[ -x /usr/local/bin/mihomo ]]; then
    MIHOMO_BIN="/usr/local/bin/mihomo"
else
    error "请先安装 Mihomo。"
    exit 1
fi

INSTALLED_VERSION=$(
    "$MIHOMO_BIN" -v 2>/dev/null |
    grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' |
    head -n1 |
    sed 's/^v//' ||
    true
)
if [[ -z "$INSTALLED_VERSION" ]] || \
   ! dpkg --compare-versions "$INSTALLED_VERSION" ge "$MIN_MIHOMO_VERSION"; then
    error "Mieru Listener 需要 Mihomo v${MIN_MIHOMO_VERSION} 或更高版本。"
    error "当前版本：${INSTALLED_VERSION:-未知}，请先更新 Mihomo。"
    exit 1
fi

mkdir -p "${MIHOMO_DIR}/protocols" "${MIHOMO_DIR}/client"

SERVER_IP=$(
    curl -4 -fsSL https://api.ipify.org ||
    curl -6 -fsSL https://api64.ipify.org ||
    echo "Unknown"
)

read -r -p "$(prompt_text "端口（1-19999，留空随机，输入 0 取消）： ")" PORT
cancel_input "$PORT" && exit "$INPUT_CANCEL_STATUS"
PORT=$(resolve_port "$PORT" 1 19999) || exit 1

USERNAME="netkit-$(openssl rand -hex 6)"
PASSWORD=$(openssl rand -hex 16)
if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
    error "Mieru 用户凭据生成失败。"
    exit 1
fi

OLD_PORT=$(yaml_number_field "$PROTOCOL_CONFIG" "port")

PROTOCOL_BACKUP=""
if [[ -f "$PROTOCOL_CONFIG" ]]; then
    PROTOCOL_BACKUP="${PROTOCOL_CONFIG}.bak.$$"
    cp "$PROTOCOL_CONFIG" "$PROTOCOL_BACKUP"
fi

CONFIG_BACKUP=""
if [[ -f "$CONFIG_FILE" ]]; then
    CONFIG_BACKUP="${CONFIG_FILE}.bak.$$"
    cp "$CONFIG_FILE" "$CONFIG_BACKUP"
fi

info "正在写入 Mihomo Mieru Listener..."
cat > "$PROTOCOL_CONFIG" <<EOF
  - name: mieru-in
    type: mieru
    port: ${PORT}
    listen: 0.0.0.0
    transport: ${TRANSPORT}
    users:
      "${USERNAME}": "${PASSWORD}"
EOF

if ! bash "$BUILD_CONFIG_SCRIPT"; then
    rollback_config
    exit 1
fi

if command -v ufw >/dev/null 2>&1; then
    if ! ufw allow "${PORT}/tcp" comment "Mihomo Mieru TCP" >/dev/null; then
        rollback_config
        error "Mieru 防火墙规则添加失败。"
        exit 1
    fi
fi

info "正在启动 Mihomo..."
if ! systemctl restart mihomo; then
    rollback_config
    systemctl restart mihomo 2>/dev/null || true
    if [[ "$OLD_PORT" != "$PORT" ]]; then
        remove_ufw_port_rule "$PORT" tcp
    fi
    error "Mihomo 启动失败。"
    journalctl -u mihomo -n 20 --no-pager
    exit 1
fi

sleep 1
if ! systemctl is-active --quiet mihomo; then
    rollback_config
    systemctl restart mihomo 2>/dev/null || true
    if [[ "$OLD_PORT" != "$PORT" ]]; then
        remove_ufw_port_rule "$PORT" tcp
    fi
    error "Mihomo 启动失败。"
    journalctl -u mihomo -n 20 --no-pager
    exit 1
fi

[[ -n "$PROTOCOL_BACKUP" ]] && rm -f "$PROTOCOL_BACKUP"
[[ -n "$CONFIG_BACKUP" ]] && rm -f "$CONFIG_BACKUP"

if [[ -n "$OLD_PORT" && "$OLD_PORT" != "$PORT" ]]; then
    remove_ufw_port_rule "$OLD_PORT" tcp
fi

LINK_HOST=$(uri_host "$SERVER_IP")
YAML_SERVER=$(yaml_quote "$SERVER_IP")
YAML_USERNAME=$(yaml_quote "$USERNAME")
YAML_PASSWORD=$(yaml_quote "$PASSWORD")
MIERU_LINK="mierus://${USERNAME}:${PASSWORD}@${LINK_HOST}?profile=default&multiplexing=MULTIPLEXING_HIGH&port=${PORT}&protocol=${TRANSPORT}"

cat > "$CLIENT_FILE" <<EOF
Mieru Link:
${MIERU_LINK}

Mihomo / Clash:
- name: Mihomo Mieru
  type: mieru
  server: ${YAML_SERVER}
  port: ${PORT}
  transport: ${TRANSPORT}
  udp: true
  username: ${YAML_USERNAME}
  password: ${YAML_PASSWORD}
  multiplexing: MULTIPLEXING_HIGH
EOF

banner "Mihomo Mieru 安装成功" "$GREEN"
kv "Server IP :" "$SERVER_IP"
kv "Port      :" "$PORT"
kv "Transport :" "$TRANSPORT"
kv "Username  :" "$USERNAME"
kv "Password  :" "$PASSWORD"
kv "UDP Relay :" "已开启（经 TCP）"
echo
label " Mieru Link"
value "$MIERU_LINK"
echo
path_kv "主配置文件      :" "$CONFIG_FILE"
path_kv "协议配置文件    :" "$PROTOCOL_CONFIG"
path_kv "连接信息文件    :" "$CLIENT_FILE"
echo
label " Mihomo / Clash YAML"
echo
sed -n '/^Mihomo \/ Clash:/,$p' "$CLIENT_FILE" | tail -n +2 | while IFS= read -r line; do
    value "$line"
done
echo
divider "$GREEN"
