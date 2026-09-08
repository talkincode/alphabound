# alphabound-mcp

MCP server that proxies AlphaBound Dashboard HTTP APIs for external agents.

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

The MCP process sends an `Authorization` Bearer header (or `X-API-Token`).

Token is read from the environment at request time; do not put real tokens in git.

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

## Run (remote HTTP / SSE)

```bash
npx -y alphabound-mcp --http
# or:
ALPHABOUND_MCP_BIND=127.0.0.1 ALPHABOUND_MCP_PORT=8723 npm run http
```

Clients must still present `ALPHABOUND_API_TOKEN` to the **daemon**; the MCP process uses the env token when calling the API. Optionally require a separate inbound header on the MCP HTTP port via `ALPHABOUND_MCP_REQUIRE_TOKEN=1` (reuses the same token).

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
