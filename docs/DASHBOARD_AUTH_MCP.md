# Dashboard Auth & Analytics MCP

## Auth model

| Client | Credential |
|--------|------------|
| Browser Dashboard | Token login → `ab_session` HttpOnly cookie; optional Passkey |
| MCP / scripts | `Authorization: Bearer <token>` or `X-API-Token: <token>` |
| Health probes | Always open: `/health/live`, `/health/ready` |

- **Empty `ALPHABOUND_API_TOKEN`**: auth disabled (local dev default).
- **Token set**: all `/api/v1/*` data routes return 401 without token/session; HTML shell stays public and shows login gate.
- Passkey register requires an existing session (bootstrap with token once).
- Credentials file: `<db_path>.webauthn` (gitignore via `*.db*` patterns / var layout).

## Env

```bash
ALPHABOUND_API_TOKEN=...
ALPHABOUND_WEBAUTHN_RP_ID=localhost          # hostname only
ALPHABOUND_WEBAUTHN_ORIGIN=http://127.0.0.1:8080
```

For SSH-tunnel access, origin must match the URL bar (e.g. `http://127.0.0.1:8080`).

## MCP (ideal remote path)

1. Enable token on daemon (`secrets.env` → deploy).
2. Run `tools/alphabound-mcp` with the same token + `ALPHABOUND_API_BASE`.
3. stdio for IDE agents; `npm run http` for a small remote tool gateway (bind loopback; tunnel as needed).

Hard rule: MCP is **read-only**. Control stays on `--control` / local admin.

See also: `docs/AGENT_ANALYTICS_MCP_PLAN.md`.
