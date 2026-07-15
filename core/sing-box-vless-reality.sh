#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

SING_BOX_DIR="/etc/sing-box"
CONFIG_FILE="${SING_BOX_DIR}/config.json"
PROTOCOL_CONFIG="${SING_BOX_DIR}/protocols/vless.json"
CLIENT_FILE="${SING_BOX_DIR}/client/vless.txt"
BUILD_CONFIG_SCRIPT="${SCRIPT_DIR}/config/sing-box-build-config.sh"

FLOW="xtls-rprx-vision"
FINGERPRINT="chrome"

ensure_dependencies(){
    local missing=()
    local package

    for package in curl openssl coreutils iproute2; do
        if ! dpkg -s "$package" >/dev/null 2>&1; then
            missing+=("$package")
        fi
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        info "正在安装 Sing-box VLESS + TCP + XTLS Vision + REALITY 环境依赖..."
        apt update
        apt install -y "${missing[@]}"
    fi
}

check_reality_target(){
    local host="$1"
    local http_version=""
    local curl_output=""

    info "正在检查 Reality 目标站点..."

    if [[ "$host" != *.* ]]; then
        warning "目标站点看起来不像有效域名：${host}"
        return 1
    fi

    if ! curl -V | grep -qi "HTTP2"; then
        error "当前 curl 不支持 HTTP/2，无法执行 --http2 检查。"
        error "请安装支持 HTTP/2 的 curl 后重试。"
        return 2
    fi

    curl_output=$(
        curl -Iv --http2 --tlsv1.3 --tls-max 1.3 \
            --connect-timeout 5 --max-time 10 \
            "https://${host}" 2>&1 || true
    )

    http_version=$(
        curl -sSI --http2 --tlsv1.3 --tls-max 1.3 \
            --connect-timeout 5 --max-time 10 \
            -o /dev/null \
            -w "%{http_version}" \
            "https://${host}" || true
    )

    if echo "$curl_output" | grep -qi "TLSv1\.3" && [[ "$http_version" == "2" ]]; then
        success "Reality 目标站点检查通过：TLS 1.3 / HTTP2 可用。"
        return
    fi

    if ! echo "$curl_output" | grep -qi "TLSv1\.3"; then
        warning "目标站点未通过 TLS 1.3 检查。"
    fi

    if [[ "$http_version" != "2" ]]; then
        warning "目标站点未通过 HTTP/2 检查。"
    fi

    return 1
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

while true; do
    read -r -p "$(prompt_text "Reality SNI（默认 icloud.com，输入 0 取消）: ")" SNI_INPUT
    cancel_input "$SNI_INPUT" && exit "$INPUT_CANCEL_STATUS"

    if ! SNI=$(normalize_reality_sni "$SNI_INPUT"); then
        warning "请重新输入 Reality SNI。"
        echo
        continue
    fi

    if check_reality_target "$SNI"; then
        break
    else
        check_status=$?
    fi

    if [[ "$check_status" -eq 2 ]]; then
        exit 1
    fi

    warning "目标站点检查失败，请重新输入 Reality SNI。"
    echo
done

info "正在生成 UUID..."
UUID=$("$SING_BOX_BIN" generate uuid | xargs)

info "正在生成 Reality 密钥..."
KEY_PAIR=$("$SING_BOX_BIN" generate reality-keypair)
PRIVATE_KEY=$(echo "$KEY_PAIR" | grep '^PrivateKey:' | cut -d':' -f2- | xargs)
PUBLIC_KEY=$(echo "$KEY_PAIR" | grep '^PublicKey:' | cut -d':' -f2- | xargs)

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    error "Reality 密钥生成失败。"
    exit 1
fi

info "正在生成 Short ID..."
SHORT_ID=$(openssl rand -hex 8)

info "正在写入 Sing-box VLESS + TCP + XTLS Vision + REALITY 协议配置..."

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
  "type": "vless",
  "tag": "vless-in",
  "listen": "::",
  "listen_port": ${PORT},
  "tcp_fast_open": true,
  "users": [
    {
      "name": "netkit",
      "uuid": "${UUID}",
      "flow": "${FLOW}"
    }
  ],
  "tls": {
    "enabled": true,
    "reality": {
      "enabled": true,
      "handshake": {
        "server": "${SNI}",
        "server_port": 443
      },
      "private_key": "${PRIVATE_KEY}",
      "short_id": [
        "${SHORT_ID}"
      ]
    }
  }
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
    ufw allow "${PORT}/tcp" comment "Sing-box VLESS REALITY" >/dev/null
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
fi

LINK_HOST=$(uri_host "$SERVER_IP")
YAML_SERVER=$(yaml_quote "$SERVER_IP")
YAML_SNI=$(yaml_quote "$SNI")
YAML_UUID=$(yaml_quote "$UUID")
YAML_FLOW=$(yaml_quote "$FLOW")
YAML_FINGERPRINT=$(yaml_quote "$FINGERPRINT")
YAML_PUBLIC_KEY=$(yaml_quote "$PUBLIC_KEY")
YAML_SHORT_ID=$(yaml_quote "$SHORT_ID")

VLESS_LINK="vless://${UUID}@${LINK_HOST}:${PORT}?encryption=none&flow=${FLOW}&security=reality&type=tcp&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&packetEncoding=xudp"

cat > "$CLIENT_FILE" <<EOF
VLESS Link:
${VLESS_LINK}

Mihomo / Clash:
- name: Sing-box VLESS + TCP + XTLS Vision + REALITY
  type: vless
  server: ${YAML_SERVER}
  port: ${PORT}
  uuid: ${YAML_UUID}
  network: tcp
  tls: true
  udp: true
  flow: ${YAML_FLOW}
  servername: ${YAML_SNI}
  client-fingerprint: ${YAML_FINGERPRINT}
  packet-encoding: xudp
  reality-opts:
    public-key: ${YAML_PUBLIC_KEY}
    short-id: ${YAML_SHORT_ID}
EOF

banner "Sing-box VLESS + TCP + XTLS Vision + REALITY 安装成功" "$GREEN"
kv "Server IP :" "$SERVER_IP"
kv "Port      :" "$PORT"
kv "UUID      :" "$UUID"
kv "SNI       :" "$SNI"
kv "Flow      :" "$FLOW"
echo
label " VLESS Link"
echo
value "$VLESS_LINK"
echo
label " Sing-box 主配置文件"
path_value "$CONFIG_FILE"
echo
label " VLESS + TCP + XTLS Vision + REALITY 协议配置文件"
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
