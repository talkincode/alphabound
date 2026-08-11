# Security

- **Never commit** `secrets.env`, API keys, passphrases, private keys, real account balances, internal IPs, production hostnames, or egress addresses.
- This repository is **public**. Agent and human contributors must follow **[AGENTS.md](AGENTS.md)** (privacy non-disclosure is mandatory).
- Production secrets: `0600` file via systemd `EnvironmentFile`, or a secret manager.
- Dashboard binds to `127.0.0.1` by default; do not expose the port on the public Internet.
- Logs and events pass through redaction (`src/observability/redaction.zig`) before persistence.
- Report vulnerabilities privately to the maintainers; do not open public issues with secrets.
