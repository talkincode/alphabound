# Deploy (systemd)

## Layout

```
/opt/alphabound/current/alphabound   # binary (atomic replace)
/etc/alphabound/alphabound.toml
/etc/alphabound/secrets.env          # 0600, root:alphabound — NEVER commit
/etc/alphabound/prompts/
/var/lib/alphabound/trading.db
```

## Install unit

```bash
sudo useradd -r -s /usr/sbin/nologin alphabound || true
sudo mkdir -p /opt/alphabound/current /etc/alphabound/prompts /var/lib/alphabound
sudo cp zig-out/bin/alphabound /opt/alphabound/current/   # build for target OS/arch
sudo cp deploy/production.example.toml /etc/alphabound/alphabound.toml
sudo cp prompts/*.md /etc/alphabound/prompts/
# secrets.env: OKX_* LLM_* only
sudo install -m 0600 -o root -g alphabound /path/to/secrets.env /etc/alphabound/secrets.env
sudo cp deploy/alphabound.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now alphabound
```

Or use the helper (requires `sshx` and `HOST=`):

```bash
HOST=your-sshx-host ./scripts/deploy-remote.sh
HOST=your-sshx-host ./scripts/check-remote.sh
# Rolling-soak acceptance: deploy restarts (logged to
# /var/lib/alphabound/deploys.log by install) are expected; only
# unexpected exits in the window fail the report.
HOST=your-sshx-host ./scripts/soak-report.sh 24
# Ops drills (record results in your local deploy notes):
HOST=your-sshx-host ./scripts/restore-drill.sh    # verify newest backup restores (AC-OPS4)
HOST=your-sshx-host ./scripts/rollback-remote.sh  # roll back to previous release (AC-OPS6)
HOST=your-sshx-host ./scripts/kill9-drill.sh      # SIGKILL crash-recovery drill (AC-NFR04)
HOST=your-sshx-host ./scripts/restart-drill.sh 3  # restart-reconcile drill (AC-GO1)
./scripts/llm-outage-drill.sh                     # local LLM-outage drill (AC-NFR02)
```

Deploys are versioned: each install stages
`/opt/alphabound/releases/<sha>-<ts>/` and atomically flips the
`/opt/alphabound/current` symlink. If `/health/ready` fails after restart
the installer automatically rolls back to the previous release. The newest
5 releases are kept. Before a controlled restart, the installer writes a
restricted maintenance marker. Once the daemon can write its journal, it
records a `SYSTEM_MAINTENANCE` event and removes the marker; a failed journal
append leaves the marker for the next boot. The decision context treats the
brief expected health-check gap adjacent to this event as maintenance, not
trading risk.

Unit hardens: `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`,
`ReadWritePaths=/var/lib/alphabound`.

## Admin on the box

```bash
sudo -u alphabound /opt/alphabound/current/alphabound \
  --config /etc/alphabound/alphabound.toml --control status
```

Dashboard: bind defaults to loopback; use SSH local forward, or set
`bind = "0.0.0.0:8080"` only on a trusted private network behind a firewall.

## Public edge (nginx + domain)

Prefer binding the daemon to loopback and terminating TLS at nginx (or another
trusted reverse proxy):

```bash
# on the host
sudo cp deploy/nginx-alphabound.conf.example /etc/nginx/sites-available/alphabound
# edit YOUR_DOMAIN + certificate paths, then:
sudo ln -sf /etc/nginx/sites-available/alphabound /etc/nginx/sites-enabled/alphabound
sudo nginx -t && sudo systemctl reload nginx
```

Required secrets when behind a proxy (see `secrets.env.example`):

- `ALPHABOUND_TRUST_PROXY=1`
- `ALPHABOUND_TRUSTED_PROXY_HOPS=1` (right-most `X-Forwarded-For` hop)
- `ALPHABOUND_WEBAUTHN_RP_ID` / `ALPHABOUND_WEBAUTHN_ORIGIN` matching the public hostname

Cloudflare DNS helper (needs **Zone.DNS Edit** token — read-only tokens return 403):

```bash
export CF_API_TOKEN=...   # do not commit
./scripts/cf-upsert-dns-a.sh your.domain.example x.x.x.x true
# Dashboard SSL/TLS mode: Full (not Flexible) when origin serves HTTPS
```

## OKX

Add the **server egress public IP** to the API key whitelist so private
balance reconcile succeeds.
