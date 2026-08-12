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

### Passkey / WebAuthn 限制（重要）

浏览器要求 **secure context**：

| 打开方式 | Token 登录 | Passkey |
|----------|------------|---------|
| `http://127.0.0.1:8080` / `http://localhost:8080` | ✅ | ✅ |
| `https://your-host/...` | ✅ | ✅ |
| `http://10.x.x.x:8080`（内网 HTTP IP） | ✅ | ❌ API 被禁用 |

内网直连 IP 时请用 **Token**。要用 Passkey：

```bash
ssh -L 8080:127.0.0.1:8080 USER@HOST
# 浏览器打开 http://127.0.0.1:8080/
```

服务端会按请求 `Host` 解析 `rpId`/`origin`；仍无法绕过浏览器对非 localhost HTTP 的限制。

## MCP (ideal remote path)

1. Enable token on daemon (`secrets.env` → deploy).
2. Run `tools/alphabound-mcp` with the same token + `ALPHABOUND_API_BASE`.
3. stdio for IDE agents; `npm run http` for a small remote tool gateway (bind loopback; tunnel as needed).

Hard rule: MCP is **read-only**. Control stays on `--control` / local admin.

See also: `docs/AGENT_ANALYTICS_MCP_PLAN.md`.
