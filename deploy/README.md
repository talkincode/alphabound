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
```

Deploys are versioned: each install stages
`/opt/alphabound/releases/<sha>-<ts>/` and atomically flips the
`/opt/alphabound/current` symlink. If `/health/ready` fails after restart
the installer automatically rolls back to the previous release. The newest
5 releases are kept.

Unit hardens: `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`,
`ReadWritePaths=/var/lib/alphabound`.

## Admin on the box

```bash
sudo -u alphabound /opt/alphabound/current/alphabound \
  --config /etc/alphabound/alphabound.toml --control status
```

Dashboard: bind defaults to loopback; use SSH local forward, or set
`bind = "0.0.0.0:8080"` only on a trusted private network behind a firewall.

## OKX

Add the **server egress public IP** to the API key whitelist so private
balance reconcile succeeds.
