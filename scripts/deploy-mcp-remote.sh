#!/usr/bin/env bash
# Deploy AlphaBound analytics MCP gateway (Streamable HTTP + OAuth 2.1) to remote host via sshx.
# Usage:
#   HOST=my-host ./scripts/deploy-mcp-remote.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${HOST:?set HOST to sshx host name}"
STAGE="${TMPDIR:-/tmp}/alphabound-mcp-deploy"
TAR="${TMPDIR:-/tmp}/alphabound-mcp-deploy.tgz"

echo "[deploy-mcp] preparing alphabound-mcp bundle"
cd "$ROOT/tools/alphabound-mcp"
if [[ ! -d "node_modules" ]]; then
  echo "[deploy-mcp] running npm install --omit=dev"
  npm install --omit=dev
fi

rm -rf "$STAGE"
mkdir -p "$STAGE/mcp" "$STAGE/systemd"
cp -R package.json package-lock.json src node_modules "$STAGE/mcp/"
cp "$ROOT/deploy/alphabound-mcp.service" "$STAGE/systemd/"

cat << 'INSTALL_INNER' > "$STAGE/install.sh"
#!/usr/bin/env bash
set -euo pipefail
SRC="${1:-/tmp/alphabound-mcp-deploy}"
BASE=/opt/alphabound
MCP_DIR="$BASE/mcp"
STATE_DIR=/var/lib/alphabound-mcp
SECRETS_FILE=/etc/alphabound/secrets.env

echo "[mcp-install] installing gateway files to $MCP_DIR"
id -u alphabound >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d /var/lib/alphabound alphabound

mkdir -p "$MCP_DIR" "$STATE_DIR"
rm -rf "$MCP_DIR.tmp"
mkdir -p "$MCP_DIR.tmp"
cp -R "$SRC/mcp/"* "$MCP_DIR.tmp/"
chown -R root:root "$MCP_DIR.tmp"
chmod -R u=rwX,go=rX "$MCP_DIR.tmp"
rm -rf "$MCP_DIR"
mv "$MCP_DIR.tmp" "$MCP_DIR"

chown -R alphabound:alphabound "$STATE_DIR"
chmod 700 "$STATE_DIR"

# Ensure secrets.env has required ALPHABOUND_MCP_* vars
if [[ -f "$SECRETS_FILE" ]]; then
  PUBLIC_URL=""
  if grep -q '^ALPHABOUND_WEBAUTHN_ORIGIN=' "$SECRETS_FILE"; then
    PUBLIC_URL="$(grep '^ALPHABOUND_WEBAUTHN_ORIGIN=' "$SECRETS_FILE" | cut -d= -f2- | tr -d '"'\'' ')"
  fi
  if [[ -z "$PUBLIC_URL" ]]; then
    echo "[mcp-install] ALPHABOUND_WEBAUTHN_ORIGIN not set in $SECRETS_FILE; cannot determine public URL" >&2
    exit 1
  fi

  append_if_missing() {
    local key="$1"
    local val="$2"
    if ! grep -q "^${key}=" "$SECRETS_FILE"; then
      echo "${key}=${val}" >> "$SECRETS_FILE"
      echo "[mcp-install] added ${key} to $SECRETS_FILE"
    fi
  }

  append_if_missing "ALPHABOUND_MCP_BIND" "127.0.0.1"
  append_if_missing "ALPHABOUND_MCP_PORT" "8723"
  append_if_missing "ALPHABOUND_MCP_OAUTH" "1"
  append_if_missing "ALPHABOUND_MCP_PUBLIC_URL" "$PUBLIC_URL"
  append_if_missing "ALPHABOUND_MCP_OAUTH_STATE_FILE" "$STATE_DIR/oauth.json"
  append_if_missing "ALPHABOUND_MCP_TRUST_PROXY" "1"
fi

# Install systemd service
install -m 0644 -o root -g root "$SRC/systemd/alphabound-mcp.service" /etc/systemd/system/alphabound-mcp.service
systemctl daemon-reload
systemctl enable alphabound-mcp
systemctl restart alphabound-mcp

# Update nginx if needed
NGINX_CONF=/etc/nginx/sites-available/alphabound
if [[ -f "$NGINX_CONF" ]] && ! grep -q "location ~ \^/(\\(\\\\.well-known/oauth-|mcp|authorize|token|register|revoke|oauth/)" "$NGINX_CONF"; then
  echo "[mcp-install] adding MCP location block to $NGINX_CONF"
  # Insert MCP location before the first `location / {`
  python3 -c '
import sys
conf = open("'"$NGINX_CONF"'").read()
mcp_block = """    # AlphaBound analytics MCP gateway (Streamable HTTP + OAuth 2.1)
    location ~ ^/(\.well-known/oauth-|mcp|authorize|token|register|revoke|oauth/) {
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection        "";
        proxy_pass http://127.0.0.1:8723;
        proxy_buffering off;
    }

"""
# Target the SSL server block (listen 443)
if "listen 443" in conf:
    parts = conf.split("server {")
    for i in range(1, len(parts)):
        if "listen 443" in parts[i] and "location / {" in parts[i] and mcp_block not in parts[i]:
            parts[i] = parts[i].replace("    location / {", mcp_block + "    location / {", 1)
            break
    conf = "server {".join(parts)
    open("'"$NGINX_CONF"'", "w").write(conf)
    print("inserted mcp location block into ssl server block in nginx")
elif "    location / {" in conf and mcp_block not in conf:
    conf = conf.replace("    location / {", mcp_block + "    location / {", 1)
    open("'"$NGINX_CONF"'", "w").write(conf)
    print("inserted mcp location block into nginx")
'
  if nginx -t; then
    systemctl reload nginx
    echo "[mcp-install] nginx reloaded successfully"
  else
    echo "[mcp-install] nginx -t failed, check $NGINX_CONF" >&2
    exit 1
  fi
fi

# Verify health
echo "[mcp-install] checking MCP service health..."
sleep 2
curl -sS http://127.0.0.1:8723/health || {
  systemctl status alphabound-mcp --no-pager
  exit 1
}
echo
echo "[mcp-install] MCP service running and healthy!"
INSTALL_INNER

chmod +x "$STAGE/install.sh"

echo "[deploy-mcp] creating tarball"
COPYFILE_DISABLE=1 tar -C "$(dirname "$STAGE")" -czf "$TAR" "$(basename "$STAGE")"

echo "[deploy-mcp] uploading to $HOST"
sshx -h="$HOST" --upload="$TAR" --to=/tmp/alphabound-mcp-deploy.tgz

echo "[deploy-mcp] extracting on $HOST"
sshx -h="$HOST" --json --timeout=60s \
  "rm -rf /tmp/alphabound-mcp-deploy && tar xzf /tmp/alphabound-mcp-deploy.tgz -C /tmp"

echo "[deploy-mcp] executing install.sh on $HOST (sudo)"
sshx -h="$HOST" --json --timeout=180s \
  "sudo bash /tmp/alphabound-mcp-deploy/install.sh /tmp/alphabound-mcp-deploy"

sshx -h="$HOST" --json --timeout=30s \
  "rm -rf /tmp/alphabound-mcp-deploy /tmp/alphabound-mcp-deploy.tgz" || true

echo "[deploy-mcp] MCP deployment complete!"
