#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "run as root"
  exit 1
fi

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

install -d /opt/natter
install -d /etc/natter-sync
install -d /var/lib/natter-sync

install -m 755 "$BASE_DIR/scripts/natter_sync.py" /opt/natter/natter_sync.py
install -m 640 "$BASE_DIR/env/natter-sync.env.example" /etc/natter-sync/natter-sync.env
install -m 640 "$BASE_DIR/env/pages.env.example" /etc/natter-sync/pages.env.example

install -m 644 "$BASE_DIR/systemd/natter-sync.service" /etc/systemd/system/natter-sync.service
install -m 644 "$BASE_DIR/systemd/natter-tcp-56001.service" /etc/systemd/system/natter-tcp-56001.service
install -m 644 "$BASE_DIR/systemd/natter-udp-56003.service" /etc/systemd/system/natter-udp-56003.service

echo "installed:"
echo "  /opt/natter/natter_sync.py"
echo "  /etc/natter-sync/natter-sync.env"
echo "  /etc/natter-sync/pages.env.example"
echo "  /etc/systemd/system/natter-*.service"
echo
echo "next:"
echo "  1. edit /etc/natter-sync/natter-sync.env"
echo "  2. make sure /opt/natter/natter.py exists"
echo "  3. systemctl daemon-reload"
echo "  4. systemctl enable --now natter-tcp-56001.service natter-udp-56003.service natter-sync.service"
