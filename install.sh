#!/usr/bin/env bash

set -e

echo "==> Updating system..."
apt update -y

echo "==> Installing dependencies..."
apt install -y curl git

echo "==> Cloning Xray-manager..."

if [ -d "Xray-manager" ]; then
  rm -rf Xray-manager
fi

git clone https://github.com/7o1ove/Xray-manager.git

cd Xray-manager

chmod +x *.sh

echo "==> Installation completed."
echo "Run: bash xray-manager.sh"