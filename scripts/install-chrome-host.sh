#!/bin/bash
set -e

# Setup Deci Chrome Extension Native Messaging Host
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MANIFEST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"

echo "==> Creating NativeMessagingHosts directory if needed..."
mkdir -p "$MANIFEST_DIR"

APP_HOST_BIN="/Applications/Deci.app/Contents/MacOS/DeciHost"

echo "==> Compiling DeciHost binary..."
mkdir -p "$(dirname "$APP_HOST_BIN")"
swiftc -O "$PROJECT_DIR/DeciHost/main.swift" -o "$APP_HOST_BIN"
chmod +x "$APP_HOST_BIN"

echo "==> Installing Native Messaging Host manifests..."
cat <<EOF > "$MANIFEST_DIR/com.abraham.deci.json"
{
  "name": "com.abraham.deci",
  "description": "Deci Audio Control Host",
  "path": "$APP_HOST_BIN",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://dhnhdhfcagmpfdoocppooomgljoldhjf/"
  ]
}
EOF

# The legacy host name is gone: Deci no longer answers to it.
rm -f "$MANIFEST_DIR/com.example.advancedaudiocontrol.json"

echo "==> Chrome Native Messaging Host installed successfully!"
