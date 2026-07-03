#!/usr/bin/env bash
set -euo pipefail

echo "== services =="
systemctl --no-pager --full status \
  natter-tcp-56001.service \
  natter-udp-56003.service \
  natter-sync.service || true

echo
echo "== state =="
cat /var/lib/natter-sync/state.json || true

echo
echo "== sync log =="
journalctl -u natter-sync.service -n 30 --no-pager -o cat || true
