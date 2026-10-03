# alphabound-mcp

MCP server that proxies AlphaBound Dashboard HTTP APIs for external agents.
Transports: **stdio** (IDE default) and **Streamable HTTP with OAuth 2.1** for remote clients.

Observation tools are read-only. The sole write is `submit_intel`, which
forwards a **pre-signed** `alphabound.intel.v1` envelope. MCP never holds
`ALPHABOUND_INTEL_HMAC` and never places orders.

Protocol: `docs/INTEL.md`.

## npx (auto-install)

IDE / Copilot clients spawn this package with `npx -y`. The first run downloads
`alphabound-mcp`; later runs use the npx cache.

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

Write that snippet into a local client:

```bash
# detect Claude / Cursor / VS Code / Copilot CLI / Windsurf
npx -y alphabound-mcp install

# GitHub Copilot CLI (~/.copilot/mcp-config.json)
npx -y alphabound-mcp install --client copilot

# print only
npx -y alphabound-mcp install --print --source npm
```

Until the package is on npm, use GitHub (subdirectory) or a clone:

```bash
npx -y alphabound-mcp install --source github --client copilot
# args: ["-y", "github:talkincode/alphabound#path:tools/alphabound-mcp"]

cd tools/alphabound-mcp && npm install
node src/index.js install --source local --client copilot
```

VS Code Copilot Chat uses `"servers"` instead of `"mcpServers"`; `install --client vscode` writes that shape. Copilot CLI also gets `"type": "local"`.

See `mcp.json.example`.

## Auth

Set the same token as the daemon:

```bash
export ALPHABOUND_API_BASE=http://127.0.0.1:18180
export ALPHABOUND_API_TOKEN=YOUR_TOKEN
```

The MCP process sends an `Authorization` Bearer header (or `X-API-Token`) to the daemon.

Token is read from the environment at request time; do not put real tokens in git.

This is how stdio and the CLI authenticate (per the MCP spec, stdio takes credentials from
the environment rather than OAuth). Remote HTTP clients authenticate *to the gateway* with
OAuth instead: see [Run (remote HTTP)](#run-remote-http).

## CLI (all MCP tools)

Same catalog as the MCP server. Empty argv still starts stdio for IDE clients.

```bash
export ALPHABOUND_API_BASE=http://127.0.0.1:18180
export ALPHABOUND_API_TOKEN=YOUR_TOKEN

npx -y alphabound-mcp tools              # list tools (JSON)
npx -y alphabound-mcp get_system         # any GET tool name
npx -y alphabound-mcp call get_state
npx -y alphabound-mcp submit_intel --file envelope.json
```

`--token` / `--base` override env. Prefer env: flags show up in `ps`. JSON goes to stdout; errors (including HTTP 401) go to stderr and exit 1. No order placement, flatten, resume, or secret readout.

## Run (stdio — default for IDE agents)

```bash
npx -y alphabound-mcp
# or from a clone:
cd tools/alphabound-mcp
npm install
npm start
```

## Run (remote HTTP)

```bash
npx -y alphabound-mcp --http
# or from a clone:  npm run http
```

One port (default `127.0.0.1:8723`), three surfaces:

| Path | What |
|------|------|
| `POST /mcp` | MCP **Streamable HTTP**, stateless, JSON responses: the same tools as stdio |
| `GET /health` | Liveness probe; always open |
| `GET /tools`, `POST /tools/:name` | Plain JSON gateway for scripts (same tool catalog) |

The gateway always calls the daemon with its **own** `ALPHABOUND_API_TOKEN`. Whatever a
caller presents (OAuth access token, API token) is checked here and **never forwarded**.

With no inbound auth configured it only runs on loopback (and checks `Host` / `Origin`
against DNS rebinding). **A non-loopback bind refuses to start** unless OAuth and/or the
pre-shared token is on:

| Variable | Meaning |
|----------|---------|
| `ALPHABOUND_MCP_BIND` / `ALPHABOUND_MCP_PORT` | Listen address, default `127.0.0.1:8723` |
| `ALPHABOUND_MCP_OAUTH=1` | OAuth 2.1 for remote MCP clients (below); needs `ALPHABOUND_API_TOKEN` and `ALPHABOUND_MCP_PUBLIC_URL` |
| `ALPHABOUND_MCP_PUBLIC_URL` | The origin clients connect to, e.g. `https://mcp.example.com` (no path). `https` unless `localhost` / `127.0.0.1` |
| `ALPHABOUND_MCP_OAUTH_STATE_FILE` | Keep registered clients and sign-ins across restarts (file is created `0600`). Unset = memory only |
| `ALPHABOUND_MCP_REQUIRE_TOKEN=1` | Also (or instead) accept `ALPHABOUND_API_TOKEN` itself as `Authorization: Bearer` / `X-API-Token` |
| `ALPHABOUND_MCP_TRUST_PROXY=<hops>` | Behind a TLS proxy: number of trusted proxy hops (usually `1`) so lockouts and rate limits see the real client IP |

### Remote clients with OAuth

Claude, ChatGPT, Cursor, VS Code, Copilot CLI and other remote-capable MCP clients sign in
through the MCP authorization flow instead of holding a token. The gateway is both the
resource server and a small **single-operator authorization server**: you approve a client
by entering the AlphaBound API token on a consent page, the same secret the Dashboard login takes.

```bash
export ALPHABOUND_API_BASE=http://127.0.0.1:18180
export ALPHABOUND_API_TOKEN=YOUR_TOKEN              # long random; also what approves clients
export ALPHABOUND_MCP_OAUTH=1
export ALPHABOUND_MCP_PUBLIC_URL=https://mcp.example.com
export ALPHABOUND_MCP_OAUTH_STATE_FILE=/var/lib/alphabound-mcp/oauth.json
export ALPHABOUND_MCP_TRUST_PROXY=1                 # one nginx in front
npx -y alphabound-mcp --http
```

Put it behind a TLS reverse proxy on **its own hostname** (OAuth metadata lives at the root
of that origin; see `deploy/nginx-alphabound-mcp.conf.example`). Then add the server by URL:

```bash
claude mcp add --transport http alphabound https://mcp.example.com/mcp
```

```json
{ "mcpServers": { "alphabound": { "url": "https://mcp.example.com/mcp" } } }
```

```json
{ "servers": { "alphabound": { "type": "http", "url": "https://mcp.example.com/mcp" } } }
```

The command is for Claude Code, the first JSON for Cursor, the second for VS Code (`servers`,
`type: http`); Claude and ChatGPT take the same URL under *Add custom connector*. On first use
the client opens your browser at the gateway's consent page, which shows the client's
self-reported name and **where the browser is sent next**. Approve only a client you just
connected yourself, enter the API token, press *Approve*.

| Endpoint | Role |
|----------|------|
| `/.well-known/oauth-protected-resource/mcp` | RFC 9728 metadata; also the `resource_metadata` in the `401` challenge |
| `/.well-known/oauth-authorization-server` | RFC 8414 metadata |
| `/register` | RFC 7591 dynamic client registration |
| `/authorize` | Consent page (PKCE `S256` required, RFC 8707 `resource` honoured) |
| `/token` | `authorization_code` and `refresh_token` grants |
| `/revoke` | RFC 7009 |

Security model:

- **Approval = the API token**, checked in constant time. The consent form has the Dashboard's
  brute-force policy: 8 bad tokens per IP per 15 min lock that IP for 15 min; 60 submissions per
  minute overall.
- **Tokens are signed, not stored** (`abmcp_at_…` access, 1 h; `abmcp_rt_…` refresh, 30 d sliding).
  Every refresh rotates the refresh token, and presenting *any* already-used one, however old,
  revokes the whole sign-in. A reused authorization code is refused and revokes what it produced.
- **Nothing token-like is stored.** Each token carries an HMAC keyed by the API token *and* the MCP
  endpoint URL; the state file only lists registered clients and sign-ins (id, client, refresh
  generation, expiry), so a leaked file is harmless. **Rotating `ALPHABOUND_API_TOKEN`, or changing
  the public URL, signs every client out** (restart the gateway after changing either). To sign
  everyone out without rotating: stop the gateway, delete the state file, start it again.
- **State file.** Keep it in a directory only the service user can write (the gateway creates the
  directory `0700` and the file `0600`). Anything that grants access (a registration, a sign-in, a
  refresh) is written first and refused with a `5xx` when the write fails. A revocation applies at
  once; if its write fails it lives in memory only until the file is writable again, which the
  gateway logs and retries on every authenticated request. Restoring an old copy of the file brings
  back sign-ins revoked since it was taken, so rotate `ALPHABOUND_API_TOKEN` after restoring a backup.
- **Open registration, bounded.** Registered clients are always public (PKCE-only; no client
  secret is issued or stored). Redirect URIs must be `https`, `http` on loopback (the port may vary,
  nothing else), or a private-use app scheme such as `cursor://`; no fragments or userinfo. At most
  100 clients: junk registrations only ever push out older *unapproved* ones, never an approved
  client, and if all 100 slots hold approved clients new registrations are refused.
- **Same boundary as stdio:** no trading control, no secrets. Every approved client gets the same
  tool set, including `submit_intel` (which only forwards a pre-signed envelope).

Limits: clients must support dynamic client registration (client ID metadata documents are not
implemented); one operator and one public origin per gateway (no path prefix).

Troubleshooting:

- `403 Invalid Host`: the proxy must forward the public hostname (`proxy_set_header Host $host`) and
  it must be the one in `ALPHABOUND_MCP_PUBLIC_URL`.
- The consent page answers `429 Too many attempts` after 8 wrong tokens: without
  `ALPHABOUND_MCP_TRUST_PROXY` every visitor looks like the proxy, so they share one lockout.
- `invalid_target` from `/authorize` or `/token`: the client's `resource` is not this gateway's
  `ALPHABOUND_MCP_PUBLIC_URL` (+ `/mcp`).
- Clients ask for sign-in again after every restart: set `ALPHABOUND_MCP_OAUTH_STATE_FILE`.

### Pre-shared token instead of OAuth

For scripts, or clients that can send a header but cannot do OAuth:

```bash
ALPHABOUND_MCP_REQUIRE_TOKEN=1 ALPHABOUND_API_TOKEN=YOUR_TOKEN npx -y alphabound-mcp --http
curl -sS http://127.0.0.1:8723/tools -H "Authorization: Bearer $ALPHABOUND_API_TOKEN"
```

Both methods can be on together. With OAuth only, the raw API token is **not** accepted on `/mcp`.

## Tools

| Tool | API | Notes |
|------|-----|-------|
| `get_system` | `GET /api/v1/system` | |
| `get_state` | `GET /api/v1/state` | |
| `get_shadow` | `GET /api/v1/shadow` | |
| `list_decisions` | `GET /api/v1/decisions` | |
| `list_orders` | `GET /api/v1/orders` | |
| `list_events` | `GET /api/v1/events` | |
| `list_memories` | `GET /api/v1/memories` | |
| `list_agent_runs` | `GET /api/v1/agent-runs` | |
| `query_equity` | `GET /api/v1/equity` | |
| `get_candles` | `GET /api/v1/candles` | |
| `get_sentiment` | `GET /api/v1/sentiment` | Fear & Greed daily curve |
| `get_auth_status` | `GET /api/v1/auth/status` | |
| `list_intel` | `GET /api/v1/intel` | history; no signature/nonce |
| `submit_intel` | `POST /api/v1/intel` | pre-signed envelope only |

No order placement, flatten, resume, or secret readout.
