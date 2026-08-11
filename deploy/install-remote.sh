#!/bin/bash
set -euo pipefail
ROOT="${1:-/tmp/alphabound-deploy}"

echo "[install] alphabound on $(hostname)"
id -u alphabound >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d /var/lib/alphabound alphabound

mkdir -p /opt/alphabound/current /opt/alphabound/ui/current \
  /etc/alphabound/prompts /var/lib/alphabound

install -m 0755 -o root -g root "$ROOT/opt/alphabound/current/alphabound" /opt/alphabound/current/alphabound
install -m 0644 -o root -g root "$ROOT/etc/alphabound/alphabound.toml" /etc/alphabound/alphabound.toml
install -m 0644 -o root -g root "$ROOT/etc/alphabound/prompts/system.md" /etc/alphabound/prompts/system.md
install -m 0644 -o root -g root "$ROOT/etc/alphabound/prompts/reflection.md" /etc/alphabound/prompts/reflection.md

if [[ -f "$ROOT/etc/alphabound/secrets.env" ]]; then
  install -m 0600 -o root -g alphabound "$ROOT/etc/alphabound/secrets.env" /etc/alphabound/secrets.env
else
  test -f /etc/alphabound/secrets.env || install -m 0600 -o root -g alphabound /dev/null /etc/alphabound/secrets.env
fi

chown -R alphabound:alphabound /var/lib/alphabound
chmod 750 /var/lib/alphabound

install -m 0644 -o root -g root "$ROOT/systemd/alphabound.service" /etc/systemd/system/alphabound.service
systemctl daemon-reload
systemctl enable alphabound
systemctl restart alphabound
sleep 2
systemctl --no-pager -l status alphabound || true

echo "[install] health"
curl -sS --max-time 3 http://127.0.0.1:8080/health/live || true
echo
curl -sS --max-time 3 http://127.0.0.1:8080/health/ready || true
echo
echo "[install] done"
