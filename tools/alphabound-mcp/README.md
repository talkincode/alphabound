# alphabound-mcp

Read-only MCP server that proxies AlphaBound Dashboard HTTP APIs for external agents.

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

## Tools (read-only)

| Tool | API |
|------|-----|
| `get_system` | `/api/v1/system` |
| `get_state` | `/api/v1/state` |
| `get_shadow` | `/api/v1/shadow` |
| `list_decisions` | `/api/v1/decisions` |
| `list_orders` | `/api/v1/orders` |
| `list_events` | `/api/v1/events` |
| `list_memories` | `/api/v1/memories` |
| `list_agent_runs` | `/api/v1/agent-runs` |
| `query_equity` | `/api/v1/equity` |
| `get_candles` | `/api/v1/candles` |
| `get_auth_status` | `/api/v1/auth/status` |

No order placement, flatten, resume, or secret readout.
