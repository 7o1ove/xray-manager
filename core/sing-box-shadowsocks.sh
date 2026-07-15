#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

SING_BOX_DIR="/etc/sing-box"
CONFIG_FILE="${SING_BOX_DIR}/config.json"
PROTOCOL_CONFIG="${SING_BOX_DIR}/protocols/shadowsocks.json"
CLIENT_FILE="${SING_BOX_DIR}/client/shadowsocks.txt"
BUILD_CONFIG_SCRIPT="${SCRIPT_DIR}/config/sing-box-build-config.sh"

METHOD="2022-blake3-aes-256-gcm"

ensure_dependencies(){
    local missing=()
    local package

    for package in curl coreutils iproute2; do
        if ! dpkg -s "$package" >/dev/null 2>&1; then
            missing+=("$package")
        fi
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        info "正在安装 Sing-box Shadowsocks 环境依赖..."
        apt update
        apt install -y "${missing[@]}"
    fi
}

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

ensure_dependencies

info "正在检查 Sing-box..."

if command -v sing-box >/dev/null 2>&1; then
    SING_BOX_BIN="$(command -v sing-box)"
elif [[ -x /usr/local/bin/sing-box ]]; then
    SING_BOX_BIN="/usr/local/bin/sing-box"
elif [[ -x /usr/bin/sing-box ]]; then
    SING_BOX_BIN="/usr/bin/sing-box"
else
    error "请先安装 Sing-box。"
    exit 1
fi

mkdir -p "${SING_BOX_DIR}/protocols" "${SING_BOX_DIR}/client"

SERVER_IP=$(
    curl -4 -fsSL https://api.ipify.org ||
    curl -6 -fsSL https://api64.ipify.org ||
    echo "Unknown"
)

read -r -p "$(prompt_text "端口（留空随机，输入 0 取消）: ")" PORT
cancel_input "$PORT" && exit "$INPUT_CANCEL_STATUS"
PORT=$(resolve_port "$PORT") || exit 1

info "正在生成 Shadowsocks 2022 密钥..."
PASSWORD=$("$SING_BOX_BIN" generate rand --base64 32 | xargs)

if [[ -z "$PASSWORD" ]]; then
    error "Shadowsocks 密钥生成失败。"
    exit 1
fi

info "正在写入 Sing-box Shadowsocks 协议配置..."

OLD_PORT=$(json_number_field "$PROTOCOL_CONFIG" "listen_port")

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

cat > "$PROTOCOL_CONFIG" <<EOF
{
  "type": "shadowsocks",
  "tag": "shadowsocks-in",
  "listen": "::",
  "listen_port": ${PORT},
  "tcp_fast_open": true,
  "method": "${METHOD}",
  "password": "${PASSWORD}"
}
EOF

if ! bash "$BUILD_CONFIG_SCRIPT"; then
    rollback_config
    exit 1
fi

[[ -n "$PROTOCOL_BACKUP" ]] && rm -f "$PROTOCOL_BACKUP"
[[ -n "$CONFIG_BACKUP" ]] && rm -f "$CONFIG_BACKUP"

info "正在更新防火墙..."

if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}/tcp" comment "Sing-box Shadowsocks TCP" >/dev/null
    ufw allow "${PORT}/udp" comment "Sing-box Shadowsocks UDP" >/dev/null
fi

info "正在启动 Sing-box..."
systemctl restart sing-box
sleep 1

if ! systemctl is-active --quiet sing-box; then
    banner "Sing-box 启动失败" "$RED"
    journalctl -u sing-box -n 20 --no-pager
    exit 1
fi

if [[ -n "$OLD_PORT" && "$OLD_PORT" != "$PORT" ]]; then
    remove_ufw_port_rule "$OLD_PORT" tcp
    remove_ufw_port_rule "$OLD_PORT" udp
fi

SS_BASE64=$(printf "%s:%s" "$METHOD" "$PASSWORD" | base64 | tr '/+' '_-' | tr -d '=\n')
LINK_HOST=$(uri_host "$SERVER_IP")
YAML_SERVER=$(yaml_quote "$SERVER_IP")
YAML_METHOD=$(yaml_quote "$METHOD")
YAML_PASSWORD=$(yaml_quote "$PASSWORD")

SS_LINK="ss://${SS_BASE64}@${LINK_HOST}:${PORT}"

cat > "$CLIENT_FILE" <<EOF
SS Link:
${SS_LINK}

Mihomo / Clash:
- name: Sing-box Shadowsocks
  type: ss
  server: ${YAML_SERVER}
  port: ${PORT}
  cipher: ${YAML_METHOD}
  password: ${YAML_PASSWORD}
  udp: true
EOF

banner "Sing-box Shadowsocks 安装成功" "$GREEN"
kv "Server IP :" "$SERVER_IP"
kv "Port      :" "$PORT"
kv "Method    :" "$METHOD"
kv "Password  :" "$PASSWORD"
echo
label " Shadowsocks Link"
echo
value "$SS_LINK"
echo
label " Sing-box 主配置文件"
path_value "$CONFIG_FILE"
echo
label " Shadowsocks 协议配置文件"
path_value "$PROTOCOL_CONFIG"
echo
label " 连接信息文件"
path_value "$CLIENT_FILE"
echo
label " Mihomo / Clash YAML"
echo
sed -n '/^Mihomo \/ Clash:/,$p' "$CLIENT_FILE" | tail -n +2 | while IFS= read -r line; do
    value "$line"
done
echo
divider "$GREEN"
