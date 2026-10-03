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
2. Point an IDE at the MCP via **npx auto-install** (same token + `ALPHABOUND_API_BASE`):

```json
{
  "mcpServers": {
    "alphabound": {
      "command": "npx",
      "args": ["-y", "alphabound-mcp"],
      "env": {
        "ALPHABOUND_API_BASE": "http://127.0.0.1:18180",
        "ALPHABOUND_API_TOKEN": "YOUR_TOKEN"
      }
    }
  }
}
```

```bash
npx -y alphabound-mcp install --client copilot
# before npm publish:  --source github
# from a clone:        node tools/alphabound-mcp/src/index.js install --source local --client copilot
```

3. stdio is the IDE default (`npx -y alphabound-mcp`). `npx -y alphabound-mcp --http` serves **MCP Streamable HTTP** at `/mcp` (plus a plain `/tools` JSON gateway) for remote clients; see [Remote MCP over HTTP](#remote-mcp-over-http-oauth-21) below.
4. The same binary is a CLI for every MCP tool. Token comes from `ALPHABOUND_API_TOKEN` (or `DASHBOARD_API_TOKEN`) at call time:

```bash
export ALPHABOUND_API_BASE=http://127.0.0.1:18180
export ALPHABOUND_API_TOKEN=YOUR_TOKEN
npx -y alphabound-mcp tools
npx -y alphabound-mcp get_system
npx -y alphabound-mcp submit_intel --file envelope.json
```

Hard rule: MCP does **not** place orders, flatten, resume, or read secrets.
Control stays on `--control` / local admin.

The sole write is `submit_intel`: a **pre-signed** `alphabound.intel.v1`
envelope forwarded to `POST /api/v1/intel`. MCP never holds
`ALPHABOUND_INTEL_HMAC`. See `docs/INTEL.md`.

### Remote MCP over HTTP (OAuth 2.1)

`alphabound-mcp --http` listens on loopback by default and **refuses a non-loopback bind**
unless inbound auth is on:

| Mode | Env | How a client authenticates |
|------|-----|----------------------------|
| OAuth 2.1 | `ALPHABOUND_MCP_OAUTH=1` + `ALPHABOUND_MCP_PUBLIC_URL=https://mcp.example.com` | Remote MCP clients (Claude, ChatGPT, Cursor, VS Code, …) discover the gateway's authorization server, register, and send the operator to a consent page; the operator approves by entering `ALPHABOUND_API_TOKEN` |
| Pre-shared token | `ALPHABOUND_MCP_REQUIRE_TOKEN=1` | Scripts: `Authorization: Bearer <ALPHABOUND_API_TOKEN>` or `X-API-Token` |

Rules:

1. TLS terminates at a trusted reverse proxy on the gateway's own hostname
   (`deploy/nginx-alphabound-mcp.conf.example`); the gateway stays on loopback and gets
   `ALPHABOUND_MCP_TRUST_PROXY=<hops>` so lockouts see real client IPs (same XFF caveats as above).
2. **No token passthrough.** Inbound OAuth / API tokens are checked at the gateway and never
   forwarded; the daemon is always called with the gateway's own `ALPHABOUND_API_TOKEN`.
3. The consent form uses the Dashboard's FailGuard numbers: 8 failures / IP / 15 min lock that IP
   for 15 min; 60 submissions / min overall.
4. Access tokens live 1 h; refresh tokens rotate (30 d sliding) and presenting any already-used one
   revokes the sign-in. Tokens are HMAC-signed with a key derived from the API token and the
   endpoint URL and nothing token-like is stored, so
   **rotating `ALPHABOUND_API_TOKEN` or changing the public URL signs every OAuth client out.**
   Set `ALPHABOUND_MCP_OAUTH_STATE_FILE` to keep clients signed in across restarts; restoring an
   old copy of it revives sign-ins revoked since, so rotate the API token after a restore.
5. Registered clients are public, PKCE-only clients (no client secret); redirect URIs must be
   `https`, loopback `http` (port may vary), or a private-use app scheme. Registration is open but
   capped, and junk registrations never evict an approved client.
6. The hard rule above is unchanged: remote clients get the same tools as stdio.

Endpoints, client configs and limits:
[`tools/alphabound-mcp/README.md`](https://github.com/talkincode/alphabound/blob/main/tools/alphabound-mcp/README.md).

See also: `docs/AGENT_ANALYTICS_MCP_PLAN.md`.
