# alphabound-mcp

MCP server that proxies AlphaBound Dashboard HTTP APIs for external agents.

Observation tools are read-only. The sole write is `submit_intel`, which
forwards a **pre-signed** `alphabound.intel.v1` envelope. MCP never holds
`ALPHABOUND_INTEL_HMAC` and never places orders.

Protocol: `docs/INTEL.md`.

## Auth

Set the same token as the daemon:

```bash
export ALPHABOUND_API_BASE=http://127.0.0.1:8080
export ALPHABOUND_API_TOKEN=YOUR_TOKEN
```

The MCP client sends `Authorization: Bearer <token>` (or `X-API-Token`).

## Run (stdio — default for IDE agents)

```bash
cd tools/alphabound-mcp
npm install
npm start
```

## Run (remote HTTP / SSE)

```bash
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
