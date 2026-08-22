# Security

- **Never commit** `secrets.env`, API keys, passphrases, private keys, real account balances, internal IPs, production hostnames, or egress addresses.
- This repository is **public**. Agent and human contributors must follow **[AGENTS.md](AGENTS.md)** (privacy non-disclosure is mandatory).
- Production secrets: `0600` file via systemd `EnvironmentFile`, or a secret manager.
- Dashboard binds to `127.0.0.1` by default; do not expose the port on the public Internet without controls below.
- **API auth (optional):** set `ALPHABOUND_API_TOKEN` (long random, e.g. `openssl rand -hex 32`) so `/api/v1/*` requires Bearer token header, `X-API-Token`, or a session cookie after `/api/v1/auth/login`. Health probes stay open. See [docs/DASHBOARD_AUTH_MCP.md](docs/DASHBOARD_AUTH_MCP.md).
- **Trust proxy:** leave `ALPHABOUND_TRUST_PROXY` off unless a trusted TLS edge is the *only* path to the process; XFF is taken from the **right** (`TRUSTED_PROXY_HOPS`, default 1). Never trust left-most client-supplied XFF.
- **Brute-force:** in-process FailGuard rate-limits bad logins / bad tokens per IP (and global login flood). Prefer edge WAF limits as well.
- **Passkeys** need a browser secure context (HTTPS or localhost). Plain HTTP to a LAN IP supports token login only.
- **Control plane** is local CLI control files only (`--control …`). HTTP Dashboard and Analytics MCP do not place orders, flatten, or read secrets. The sole HTTP/MCP write besides auth is signed intel ingest (`POST /api/v1/intel` / MCP `submit_intel`); see [docs/INTEL.md](docs/INTEL.md).
- Logs and events pass through redaction (`src/observability/redaction.zig`) before persistence.
- Live trading requires explicit `OKX_REAL_MONEY_OK=1` on a small sub-account key with **no withdraw** permission.
- Report vulnerabilities privately to the maintainers; do not open public issues with secrets.
