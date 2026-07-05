#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/xray-manager"

# shellcheck source=/root/xray-manager/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

XRAY_DIR="/usr/local/etc/xray"

CONFIG_FILE="${XRAY_DIR}/config.json"
PROTOCOL_DIR="${XRAY_DIR}/protocols"
OUTBOUND_FILE="${XRAY_DIR}/outbound.json"

info "Building Xray configuration..."

mkdir -p "$XRAY_DIR"
mkdir -p "$PROTOCOL_DIR"
mkdir -p "$(dirname "$CONFIG_FILE")"

# Find Xray

if command -v xray >/dev/null 2>&1; then

    XRAY_BIN=$(command -v xray)

elif [[ -x /usr/local/bin/xray ]]; then

    XRAY_BIN="/usr/local/bin/xray"

elif [[ -x /usr/bin/xray ]]; then

    XRAY_BIN="/usr/bin/xray"

else

    error "Xray not found."

    exit 1

fi

# Check outbound

if [[ ! -f "$OUTBOUND_FILE" ]]; then

    error "Outbound configuration not found."

    exit 1

fi

# Check inbound

FOUND=false

for FILE in "$PROTOCOL_DIR"/*.json; do

    if [[ -f "$FILE" ]]; then

        FOUND=true

        break

    fi

done

if ! $FOUND; then

    error "No protocol configuration found."

    exit 1

fi

# Write config.json

cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },

  "inbounds": [

EOF

FIRST=true

for FILE in "$PROTOCOL_DIR"/*.json; do

    [[ -f "$FILE" ]] || continue

    if $FIRST; then

        FIRST=false

    else

        echo "," >> "$CONFIG_FILE"

    fi

    cat "$FILE" >> "$CONFIG_FILE"

    echo >> "$CONFIG_FILE"

done

cat >> "$CONFIG_FILE" <<EOF

  ],

  "outbounds": [

EOF

cat "$OUTBOUND_FILE" >> "$CONFIG_FILE"

echo >> "$CONFIG_FILE"

cat >> "$CONFIG_FILE" <<EOF

  ]
}
EOF

# Test

info "Testing configuration..."

if ! "$XRAY_BIN" run -test -config "$CONFIG_FILE"; then

    banner " Configuration test failed" "$RED"

    exit 1

fi

banner " Configuration built successfully" "$GREEN"
echo
label " Config File"
path_value "$CONFIG_FILE"
echo
divider "$GREEN"
