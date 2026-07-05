#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="/root/xray-manager"

# shellcheck source=/root/xray-manager/lib/output.sh
source "${SCRIPT_DIR}/lib/output.sh"

########################################
# Variables
########################################

SSH_CONFIG="/etc/ssh/sshd_config"

FAIL2BAN_CONFIG="/etc/fail2ban/jail.local"

SYSCTL_CONFIG="/etc/sysctl.d/99-z-bbr.conf"

SWAPFILE="/swapfile"

TIMEZONE="Asia/Hong_Kong"

info "Updating package list..."

apt update

info "Installing dependencies..."

apt install -y \
    openssl \
    openssh-server \
    python3-systemd \
    net-tools \
    ufw \
    fail2ban

info "Configuring SSH..."

read -r -p "$(prompt_text "SSH Port: ")" SSH_PORT

if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || \
   [[ "$SSH_PORT" -lt 1 ]] || \
   [[ "$SSH_PORT" -gt 65535 ]]; then

    error "Invalid SSH port."

    exit 1

fi

if ss -ltnH | awk '{print $4}' | grep -q ":${SSH_PORT}$"; then

    error "Port already in use."

    exit 1

fi

echo

read -r -p "$(prompt_text "SSH Public Key: ")" PUBLIC_KEY

if [[ -z "$PUBLIC_KEY" ]]; then

    error "SSH Public Key cannot be empty."

    exit 1

fi

mkdir -p /root/.ssh

chmod 700 /root/.ssh

echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys

chmod 600 /root/.ssh/authorized_keys


info "Applying SSH configuration..."

declare -A SSH_CONFIGS=(
    ["Port"]="$SSH_PORT"
    ["PasswordAuthentication"]="no"
    ["PubkeyAuthentication"]="yes"
    ["PermitRootLogin"]="prohibit-password"
)

NEW_CONFIG=""

for KEY in "${!SSH_CONFIGS[@]}"; do

    sed -i "/^[#[:space:]]*${KEY}[[:space:]]/d" "$SSH_CONFIG"

    NEW_CONFIG+="${KEY} ${SSH_CONFIGS[$KEY]}"$'\n'

done

awk -v CONFIG="$NEW_CONFIG" '

/^[[:space:]]*Match/ && !DONE {

    printf "%s", CONFIG

    DONE=1

}

{

    print

}

END {

    if (!DONE)

        printf "%s", CONFIG

}

' "$SSH_CONFIG" > "${SSH_CONFIG}.tmp"

mv "${SSH_CONFIG}.tmp" "$SSH_CONFIG"

info "Configuring firewall..."

ufw allow "${SSH_PORT}/tcp" comment "SSH"

ufw delete allow 22/tcp >/dev/null 2>&1 || true

ufw delete allow OpenSSH >/dev/null 2>&1 || true

info "Configuring Fail2Ban..."

cat > "$FAIL2BAN_CONFIG" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 604800
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 3
bantime = 604800
EOF


read -r -p "$(prompt_text "Create 1G Swap? [y/n]: ")" CREATE_SWAP

CREATE_SWAP=${CREATE_SWAP:-y}

SWAP_STATUS="Skipped"

if [[ "$CREATE_SWAP" =~ ^[Yy]$ ]]; then

    info "Creating swap..."

    if [[ -z "$(swapon --show)" ]]; then

        fallocate -l 1G "$SWAPFILE" || \
        dd if=/dev/zero of="$SWAPFILE" bs=1M count=1024

        chmod 600 "$SWAPFILE"

        mkswap "$SWAPFILE"

        swapon "$SWAPFILE"

        grep -q "^${SWAPFILE}" /etc/fstab || \
        echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab

        SWAP_STATUS="Created"

    else

        SWAP_STATUS="Already Exists"

    fi

else

    warning "Skipping swap..."

fi

info "Configuring timezone..."

timedatectl set-timezone "$TIMEZONE"

info "Applying system optimization..."

modprobe nf_conntrack 2>/dev/null || true

echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf

cat > "$SYSCTL_CONFIG" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.netfilter.nf_conntrack_max = 32768
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 180
net.netfilter.nf_conntrack_tcp_timeout_established = 3600

net.core.somaxconn = 1024
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_mtu_probing = 1

vm.swappiness = 10
EOF

sysctl --system >/dev/null

info "Restarting services..."

systemctl restart ssh

ufw --force enable >/dev/null

ufw --force reload

systemctl enable fail2ban

systemctl restart fail2ban

banner "     System Configuration Summary" "$GREEN"

kv "SSH Port    :" "$SSH_PORT"
kv "SSH Auth    :" "Key Only"

echo

kv "Firewall    :" "$(ufw status | grep -q active && echo Enabled || echo Disabled)"
kv "Fail2Ban    :" "$(systemctl is-active --quiet fail2ban && echo Enabled || echo Disabled)"

echo

kv "Swap        :" "$SWAP_STATUS"
kv "Timezone    :" "$TIMEZONE"

echo

kv "TCP CC      :" "bbr"
kv "Qdisc       :" "fq"

echo

echo
