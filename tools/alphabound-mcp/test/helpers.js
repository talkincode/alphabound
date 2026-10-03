import crypto from "node:crypto";
import http from "node:http";
import net from "node:net";
import { loadHttpConfig, startHttp } from "../src/http.js";

/** Doubles as the daemon's API token and the operator secret that approves OAuth clients. */
export const TOKEN = "test-operator-token-0123456789abcdef";

const json = (res, code, obj) => {
  res.writeHead(code, { "content-type": "application/json" });
  res.end(JSON.stringify(obj));
};

/** Stand-in for the Dashboard API; `seen` records what the gateway sent it. */
export async function startMockApi() {
  const seen = [];
  const server = http.createServer(async (req, res) => {
    const auth = req.headers.authorization || "";
    seen.push({ method: req.method, url: req.url, authorization: auth });
    if (auth !== `Bearer ${TOKEN}`) return json(res, 401, { error: "unauthorized" });
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : null;
    json(res, 200, { path: req.url, method: req.method, body, ok: true });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    base: `http://127.0.0.1:${server.address().port}`,
    seen,
    close: () => new Promise((resolve) => (server.closeAllConnections?.(), server.close(resolve))),
  };
}

export function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer().listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

/**
 * Boot the real gateway through the same loadHttpConfig() production uses.
 * OAuth is on by default; pass `oauth: false` and `env` to vary the setup, `port` to restart
 * on a known address (the public URL, hence the token audience, is derived from it).
 */
export async function startGateway({ mock, oauth = true, env = {}, port: fixedPort } = {}) {
  const port = fixedPort ?? (await freePort());
  const base = `http://127.0.0.1:${port}`;
  const config = loadHttpConfig({
    ALPHABOUND_API_BASE: mock.base,
    ALPHABOUND_API_TOKEN: TOKEN,
    ALPHABOUND_MCP_PORT: String(port),
    ...(oauth ? { ALPHABOUND_MCP_OAUTH: "1", ALPHABOUND_MCP_PUBLIC_URL: base } : {}),
    ...env,
  });
  const logs = [];
  const server = await startHttp(config, { log: (s) => logs.push(s) });
  // Tests restart gateways on the same port: never leave a pooled socket for the next one to trip over.
  server.prependListener("request", (_req, res) => res.setHeader("Connection", "close"));
  return {
    base,
    config,
    logs,
    close: () => new Promise((resolve) => (server.closeAllConnections?.(), server.close(resolve))),
  };
}

export function pkce() {
  const verifier = crypto.randomBytes(32).toString("base64url");
  const challenge = crypto.createHash("sha256").update(verifier).digest("base64url");
  return { verifier, challenge };
}

export const form = (obj) => ({
  headers: { "content-type": "application/x-www-form-urlencoded" },
  body: new URLSearchParams(obj),
});

/** Low-level request that lets a test set Host / Origin, which fetch() may not. */
export function rawRequest(base, { method = "GET", path = "/", headers = {}, body } = {}) {
  const u = new URL(base);
  return new Promise((resolve, reject) => {
    const req = http.request({ host: u.hostname, port: u.port, method, path, headers }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({ status: res.statusCode, headers: res.headers, text: Buffer.concat(chunks).toString("utf8") }));
    });
    req.on("error", reject);
    req.end(body);
  });
}
