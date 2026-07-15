#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/netkit"

# shellcheck source=/root/netkit/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

SING_BOX_DIR="/etc/sing-box"
CONFIG_FILE="${SING_BOX_DIR}/config.json"
PROTOCOL_DIR="${SING_BOX_DIR}/protocols"
CONFIG_TMP="${CONFIG_FILE}.tmp.$$"

info "正在构建 Sing-box 配置..."

mkdir -p "$SING_BOX_DIR" "$PROTOCOL_DIR"

if command -v sing-box >/dev/null 2>&1; then
    SING_BOX_BIN="$(command -v sing-box)"
elif [[ -x /usr/local/bin/sing-box ]]; then
    SING_BOX_BIN="/usr/local/bin/sing-box"
elif [[ -x /usr/bin/sing-box ]]; then
    SING_BOX_BIN="/usr/bin/sing-box"
else
    error "未检测到 Sing-box。"
    exit 1
fi

FOUND=false

for file in "$PROTOCOL_DIR"/*.json; do
    if [[ -f "$file" ]]; then
        FOUND=true
        break
    fi
done

if ! $FOUND; then
    error "未找到 Sing-box 协议配置。"
    exit 1
fi

trap 'rm -f "$CONFIG_TMP"' EXIT

cat > "$CONFIG_TMP" <<EOF
{
  "log": {
    "level": "error",
    "timestamp": true
  },
  "inbounds": [
EOF

FIRST=true

for file in "$PROTOCOL_DIR"/*.json; do
    [[ -f "$file" ]] || continue

    if $FIRST; then
        FIRST=false
    else
        echo "," >> "$CONFIG_TMP"
    fi

    cat "$file" >> "$CONFIG_TMP"
    echo >> "$CONFIG_TMP"
done

cat >> "$CONFIG_TMP" <<EOF
  ]
}
EOF

info "正在测试 Sing-box 配置..."

if ! "$SING_BOX_BIN" check -c "$CONFIG_TMP"; then
    banner "Sing-box 配置测试失败" "$RED"
    exit 1
fi

mv "$CONFIG_TMP" "$CONFIG_FILE"
trap - EXIT

banner "Sing-box 配置构建成功" "$GREEN"
echo
label " Sing-box 主配置文件"
path_value "$CONFIG_FILE"
echo
divider "$GREEN"
