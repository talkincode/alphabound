const BASE = (process.env.ALPHABOUND_API_BASE || "http://127.0.0.1:8080").replace(/\/$/, "");
const TOKEN = process.env.ALPHABOUND_API_TOKEN || process.env.DASHBOARD_API_TOKEN || "";

export function apiBase() {
  return BASE;
}

export async function apiGet(path) {
  const headers = { accept: "application/json" };
  if (TOKEN) {
    headers.authorization = `Bearer ${TOKEN}`;
    headers["x-api-token"] = TOKEN;
  }
  const url = `${BASE}${path.startsWith("/") ? path : `/${path}`}`;
  const res = await fetch(url, { headers, cache: "no-store" });
  const text = await res.text();
  let body;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = { raw: text };
  }
  if (!res.ok) {
    const err = new Error(`API ${path} -> HTTP ${res.status}`);
    err.status = res.status;
    err.body = body;
    throw err;
  }
  return body;
}

export const TOOLS = [
  { name: "get_system", description: "Runtime system snapshot (mode, ready, agent stats)", path: "/api/v1/system" },
  { name: "get_state", description: "Portfolio state: equity, cash, btc, risk_mode, drawdown", path: "/api/v1/state" },
  { name: "get_shadow", description: "Buy-and-hold benchmark / alpha comparison", path: "/api/v1/shadow" },
  { name: "list_decisions", description: "Recent agent decisions with thesis/reasoning", path: "/api/v1/decisions" },
  { name: "list_orders", description: "Orders projection and recent fills", path: "/api/v1/orders" },
  { name: "list_events", description: "Recent structured events", path: "/api/v1/events" },
  { name: "list_memories", description: "Agent memory entries", path: "/api/v1/memories" },
  { name: "list_agent_runs", description: "Agent run summaries", path: "/api/v1/agent-runs" },
  { name: "query_equity", description: "Equity / HWM time series samples", path: "/api/v1/equity" },
  { name: "get_candles", description: "Cached multi-timeframe BTC candles", path: "/api/v1/candles" },
  { name: "get_auth_status", description: "Whether API auth is required and passkey count", path: "/api/v1/auth/status" },
];
