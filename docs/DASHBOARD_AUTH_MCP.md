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
ALPHABOUND_API_TOKEN=...                    # long random (≥24 chars; 32+ recommended for public)
ALPHABOUND_WEBAUTHN_RP_ID=localhost          # hostname only
ALPHABOUND_WEBAUTHN_ORIGIN=http://127.0.0.1:8080
ALPHABOUND_TRUST_PROXY=1                    # ONLY behind a trusted TLS/proxy edge
ALPHABOUND_TRUSTED_PROXY_HOPS=1             # XFF: use Nth IP from the right (default 1)
```

### `X-Forwarded-For` can be forged

| Setup | Client can spoof lockout key? |
|-------|-------------------------------|
| `TRUST_PROXY` **off** (default) | **No** — FailGuard keys on TCP peer only |
| `TRUST_PROXY=1` + take **left-most** XFF | **Yes** — attacker rotates forged IPs, bypasses lockout |
| `TRUST_PROXY=1` + take **right-most** (our default hops=1) | **No** for a single append-style proxy that always adds the real peer |

Rules:

1. **Default off.** Direct internet → alphabound: never enable trust proxy.
2. **Enable only** when Azure App Gateway / Front Door / nginx terminates TLS and is the **only** path to the process (NSG / private bind / no public :8080).
3. We parse XFF as append-chain and pick **`hops` from the right** (default 1 = right-most). Left-most client junk is ignored.
4. Prefer edge WAF rate limits; FailGuard is in-process last line. Peer IP of the proxy alone would collapse all users into one bucket if XFF were missing — still fail-closed for brute force.

## Brute-force / rate limits

When token auth is enabled, the single-threaded web loop keeps an in-memory **FailGuard**:

| Signal | Counts as failure? | Effect |
|--------|--------------------|--------|
| `POST /api/v1/auth/login` wrong token | yes | per-IP fail counter |
| `POST .../passkey/login` bad assertion | yes | per-IP fail counter |
| `Authorization` / `X-API-Token` wrong | yes | per-IP fail counter |
| Missing credential (browser first paint) | **no** | plain 401 |
| Successful token/passkey login | clears IP slot | |

Defaults (compile-time in `src/web/auth.zig`):

- **8** failures / IP / **15 min** window → lockout **15 min** → HTTP **429** + `Retry-After`
- Global login flood: **60** login POSTs / rolling minute (all IPs) → 429

This is process-local (resets on restart). Put Azure Front Door / WAF / nginx in front for edge rate limits; FailGuard is the in-process last line.

Public exposure checklist:

1. Long random `ALPHABOUND_API_TOKEN` (e.g. `openssl rand -hex 32`)
2. HTTPS terminator; `ALPHABOUND_TRUST_PROXY=1` **only** if the edge is trusted and clients cannot reach the app directly
3. Prefer session cookie / passkey after first login; do not put the raw token in browser JS storage
4. Keep `/health/*` open for probes; never put secrets in health bodies
5. Do not expose dashboard port publicly without the proxy; forged XFF is useless if `TRUST_PROXY` stays off

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
