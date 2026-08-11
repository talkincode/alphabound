# Security

- **Never commit** `secrets.env`, API keys, passphrases, or private keys.
- Production secrets: `0600` file via systemd `EnvironmentFile`, or a secret manager.
- Dashboard binds to `127.0.0.1` by default; do not expose the port on the public Internet.
- Logs and events pass through redaction (`src/observability/redaction.zig`) before persistence.
- Report vulnerabilities privately to the maintainers; do not open public issues with secrets.
