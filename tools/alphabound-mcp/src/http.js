#!/usr/bin/env node
/**
 * Minimal remote MCP-ish HTTP gateway:
 *   GET  /health
 *   GET  /tools
 *   POST /tools/:name   (JSON body ignored; returns tool result)
 *
 * Optional inbound gate: ALPHABOUND_MCP_REQUIRE_TOKEN=1 checks Bearer/X-API-Token
 * against ALPHABOUND_API_TOKEN before proxying.
 *
 * Full MCP Streamable HTTP can be layered later; this is the operational remote surface.
 */
import http from "node:http";
import { TOOLS, apiGet, apiBase } from "./client.js";

const BIND = process.env.ALPHABOUND_MCP_BIND || "127.0.0.1";
const PORT = Number(process.env.ALPHABOUND_MCP_PORT || "8723");
const REQUIRE = process.env.ALPHABOUND_MCP_REQUIRE_TOKEN === "1";
const TOKEN = process.env.ALPHABOUND_API_TOKEN || process.env.DASHBOARD_API_TOKEN || "";

function readAuth(req) {
  const h = req.headers["authorization"] || "";
  if (typeof h === "string" && h.toLowerCase().startsWith("bearer ")) return h.slice(7).trim();
  const x = req.headers["x-api-token"];
  if (typeof x === "string" && x.trim()) return x.trim();
  return "";
}

function send(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    "content-type": "application/json",
    "cache-control": "no-store",
  });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
    if (req.method === "GET" && url.pathname === "/health") {
      return send(res, 200, { ok: true, api_base: apiBase(), tools: TOOLS.length });
    }
    if (REQUIRE) {
      const presented = readAuth(req);
      if (!TOKEN || presented !== TOKEN) return send(res, 401, { error: "unauthorized" });
    }
    if (req.method === "GET" && url.pathname === "/tools") {
      return send(res, 200, {
        tools: TOOLS.map((t) => ({ name: t.name, description: t.description, path: t.path })),
      });
    }
    const m = url.pathname.match(/^\/tools\/([a-z0-9_]+)$/i);
    if (req.method === "POST" && m) {
      const tool = TOOLS.find((t) => t.name === m[1]);
      if (!tool) return send(res, 404, { error: "unknown_tool" });
      const data = await apiGet(tool.path);
      return send(res, 200, { name: tool.name, path: tool.path, data });
    }
    return send(res, 404, { error: "not_found" });
  } catch (e) {
    return send(res, e.status || 502, {
      error: e.message,
      body: e.body || null,
    });
  }
});

server.listen(PORT, BIND, () => {
  console.error(`[alphabound-mcp-http] listening ${BIND}:${PORT} -> ${apiBase()}`);
});
