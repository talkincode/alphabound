/**
 * Remote HTTP surface of the AlphaBound analytics MCP.
 *
 *   POST /mcp                        MCP Streamable HTTP (stateless, JSON responses)
 *   GET  /health                     liveness probe, always open
 *   GET  /tools, POST /tools/:name   plain JSON gateway over the same tool catalog
 *
 * Inbound authentication, either or both (neither = loopback-only local development):
 *   ALPHABOUND_MCP_OAUTH=1          OAuth 2.1 per the MCP authorization spec, with the built-in
 *                                   single-operator authorization server (src/oauth/)
 *   ALPHABOUND_MCP_REQUIRE_TOKEN=1  the pre-shared ALPHABOUND_API_TOKEN as Bearer / X-API-Token
 *
 * Whatever the caller presents, the daemon is only ever called with the gateway's own
 * ALPHABOUND_API_TOKEN: inbound tokens are never forwarded.
 */
import http from "node:http";
import path from "node:path";
import express from "express";
import { getOAuthProtectedResourceMetadataUrl, createOAuthMetadata, mcpAuthMetadataRouter } from "@modelcontextprotocol/sdk/server/auth/router.js";
import { authorizationHandler } from "@modelcontextprotocol/sdk/server/auth/handlers/authorize.js";
import { clientRegistrationHandler } from "@modelcontextprotocol/sdk/server/auth/handlers/register.js";
import { revocationHandler } from "@modelcontextprotocol/sdk/server/auth/handlers/revoke.js";
import { tokenHandler } from "@modelcontextprotocol/sdk/server/auth/handlers/token.js";
import { requireBearerAuth } from "@modelcontextprotocol/sdk/server/auth/middleware/bearerAuth.js";
import { hostHeaderValidation } from "@modelcontextprotocol/sdk/server/middleware/hostHeaderValidation.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { TOOLS, callTool, findTool, listToolsPublic, resolveConfig } from "./client.js";
import { createMcpServer } from "./server.js";
import { safeEqual } from "./secret.js";
import { FailLimiter } from "./oauth/limiter.js";
import { CONSENT_PATH } from "./oauth/consent.js";
import { OperatorOAuthProvider, isAllowedRedirectUri } from "./oauth/provider.js";
import { OAuthStore } from "./oauth/store.js";

export const MCP_PATH = "/mcp";

const LOOPBACK_BINDS = new Set(["127.0.0.1", "localhost", "::1"]);
const LOOPBACK_HOSTS = ["localhost", "127.0.0.1", "[::1]"]; // as they appear in a Host header

function parsePublicUrl(raw) {
  if (!raw) return null;
  let u;
  try {
    u = new URL(raw);
  } catch {
    throw new Error("ALPHABOUND_MCP_PUBLIC_URL is not a valid URL");
  }
  if (!/^https?:$/.test(u.protocol) || u.pathname !== "/" || u.search || u.hash || u.username || u.password) {
    throw new Error(
      "ALPHABOUND_MCP_PUBLIC_URL must be an origin such as https://mcp.example.com (no path, query, or credentials)",
    );
  }
  return u;
}

/**
 * Validate the environment into the gateway's config. Every misconfiguration that would
 * leave the endpoint open or the OAuth issuer unusable fails here, at startup.
 */
export function loadHttpConfig(env = process.env) {
  const bind = env.ALPHABOUND_MCP_BIND || "127.0.0.1";
  const port = Number(env.ALPHABOUND_MCP_PORT || "8723");
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new Error("ALPHABOUND_MCP_PORT must be a port number");
  }
  const upstream = resolveConfig({}, env);
  const requireToken = env.ALPHABOUND_MCP_REQUIRE_TOKEN === "1";
  const oauthOn = env.ALPHABOUND_MCP_OAUTH === "1";
  const publicUrl = parsePublicUrl(env.ALPHABOUND_MCP_PUBLIC_URL);

  if ((requireToken || oauthOn) && !upstream.token) {
    throw new Error(
      "inbound auth needs ALPHABOUND_API_TOKEN: it is the shared secret for ALPHABOUND_MCP_REQUIRE_TOKEN " +
        "and what approves OAuth clients",
    );
  }
  if (!requireToken && !oauthOn && !LOOPBACK_BINDS.has(bind)) {
    throw new Error(
      `refusing to listen on ${bind} without inbound auth: ` +
        "set ALPHABOUND_MCP_OAUTH=1 or ALPHABOUND_MCP_REQUIRE_TOKEN=1, or bind 127.0.0.1",
    );
  }
  if (oauthOn) {
    if (!publicUrl) {
      throw new Error(
        "ALPHABOUND_MCP_OAUTH=1 needs ALPHABOUND_MCP_PUBLIC_URL, " +
          "the origin clients connect to (e.g. https://mcp.example.com)",
      );
    }
    if (publicUrl.protocol !== "https:" && !["localhost", "127.0.0.1"].includes(publicUrl.hostname)) {
      throw new Error("OAuth needs an https ALPHABOUND_MCP_PUBLIC_URL (plain http only for localhost / 127.0.0.1)");
    }
  }

  const hops = Number(env.ALPHABOUND_MCP_TRUST_PROXY || "0");
  if (!Number.isInteger(hops) || hops < 0 || hops > 10) {
    throw new Error("ALPHABOUND_MCP_TRUST_PROXY must be the number of trusted proxy hops, e.g. 1");
  }

  // DNS-rebinding guard: only the names this gateway is meant to be reached by. Without a
  // public URL, a non-loopback bind has no baseline to compare against and stays unchecked.
  const allowedHosts =
    LOOPBACK_BINDS.has(bind) || publicUrl ? [...LOOPBACK_HOSTS, ...(publicUrl ? [publicUrl.hostname] : [])] : null;

  return {
    bind,
    port,
    upstream,
    requireToken,
    oauth: oauthOn
      ? { stateFile: env.ALPHABOUND_MCP_OAUTH_STATE_FILE ? path.resolve(env.ALPHABOUND_MCP_OAUTH_STATE_FILE) : null }
      : null,
    publicUrl,
    trustProxy: hops,
    allowedHosts,
  };
}

/** `Authorization: Bearer …` first, then `X-API-Token` (the daemon's two spellings). */
function presentedToken(req) {
  const h = req.headers.authorization;
  if (typeof h === "string" && h.toLowerCase().startsWith("bearer ")) return h.slice(7).trim();
  const x = req.headers["x-api-token"];
  return typeof x === "string" ? x.trim() : "";
}

/** MCP Streamable HTTP: a request carrying an Origin that is not one of ours is refused (DNS rebinding). */
function originGuard(allowedHosts) {
  const allowed = new Set(allowedHosts);
  return (req, res, next) => {
    const origin = req.headers.origin;
    if (origin === undefined) return next();
    let host = null;
    try {
      host = new URL(origin).hostname;
    } catch {
      // unparsable (e.g. "null"): refused below
    }
    if (host && allowed.has(host)) return next();
    res.status(403).json({ error: "forbidden_origin" });
  };
}

const rpcError = (code, message) => ({ jsonrpc: "2.0", error: { code, message }, id: null });

/**
 * The SDK accepts a loopback redirect_uri that differs from the registered one in more than the
 * port (RFC 8252 §7.3 only allows the port) and, on its error path, redirects to whatever it
 * accepted. Hold the line before it runs: a redirect_uri outside our policy is never redirected to.
 */
function redirectGuard(req, res, next) {
  const uri = (req.method === "POST" ? req.body : req.query)?.redirect_uri;
  if (typeof uri === "string" && !isAllowedRedirectUri(uri)) {
    return res.status(400).json({ error: "invalid_request", error_description: "Unsupported redirect_uri" });
  }
  next();
}

/** The plain gateway's body reader: any content type, any JSON value, 16 KB, errors as { error, status }. */
const gatewayJson = express.json({ type: () => true, limit: "16kb", strict: false });
const readGatewayBody = (req, res) =>
  new Promise((resolve, reject) => {
    gatewayJson(req, res, (err) => {
      if (!err) return resolve(req.body ?? {});
      const tooLarge = err.type === "entity.too.large";
      reject(Object.assign(new Error(tooLarge ? "body_too_large" : "bad_json"), { status: tooLarge ? 413 : 400 }));
    });
  });

export function createApp(config, { log = () => {} } = {}) {
  const { upstream } = config;
  const inboundAuth = config.requireToken || config.oauth !== null;
  const app = express();
  app.disable("x-powered-by");
  if (config.trustProxy) app.set("trust proxy", config.trustProxy);
  app.use((req, res, next) => {
    res.set({ "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" });
    next();
  });
  if (config.allowedHosts) app.use(hostHeaderValidation(config.allowedHosts));

  // The probe stays open; behind inbound auth it must not hand the upstream address to strangers.
  app.get("/health", (req, res) => {
    res.json({ ok: true, ...(inboundAuth ? {} : { api_base: upstream.base }), tools: TOOLS.length });
  });

  // --- OAuth: discovery, registration, authorize/consent, token, revoke (all public) ---
  let verifier = null;
  let resourceMetadataUrl;
  if (config.oauth) {
    const resourceUrl = new URL(MCP_PATH, config.publicUrl);
    const store = new OAuthStore({
      file: config.oauth.stateFile,
      secret: upstream.token,
      audience: resourceUrl.href,
      log,
    });
    const provider = new OperatorOAuthProvider({
      store,
      resourceUrl,
      operatorToken: upstream.token,
      limiter: new FailLimiter(),
      log,
    });
    app.post(CONSENT_PATH, express.urlencoded({ extended: false, limit: "4kb" }), provider.consent);

    // The SDK's mcpAuthRouter, unrolled for two reasons: its metadata claims client_secret_post
    // for revocation although every client here is public, and redirectGuard has to run first.
    const oauthMetadata = {
      ...createOAuthMetadata({ provider, issuerUrl: config.publicUrl, baseUrl: config.publicUrl }),
      token_endpoint_auth_methods_supported: ["none"],
      revocation_endpoint_auth_methods_supported: ["none"],
    };
    app.use("/authorize", express.urlencoded({ extended: false }), redirectGuard, authorizationHandler({ provider }));
    app.use("/token", tokenHandler({ provider }));
    app.use("/register", clientRegistrationHandler({ clientsStore: provider.clientsStore }));
    app.use("/revoke", revocationHandler({ provider }));
    app.use(
      mcpAuthMetadataRouter({
        oauthMetadata,
        resourceServerUrl: resourceUrl,
        resourceName: "AlphaBound Analytics MCP",
      }),
    );
    verifier = provider;
    resourceMetadataUrl = getOAuthProtectedResourceMetadataUrl(resourceUrl);
  }

  // --- everything below needs inbound auth (a no-op in loopback-only development) ---
  if (config.allowedHosts) app.use(originGuard(config.allowedHosts));
  const bearer = verifier ? requireBearerAuth({ verifier, resourceMetadataUrl }) : null;
  app.use((req, res, next) => {
    if (!inboundAuth) return next();
    if (config.requireToken) {
      const presented = presentedToken(req);
      if (presented && safeEqual(presented, upstream.token)) return next();
    }
    if (bearer) return bearer(req, res, next); // 401 + WWW-Authenticate: resource_metadata=…
    res.set("WWW-Authenticate", 'Bearer realm="alphabound-mcp"').status(401).json({ error: "unauthorized" });
  });

  // MCP Streamable HTTP. Stateless: the tools are plain request/response, so every POST
  // gets its own server + transport and nothing survives the request (no sessions to leak
  // or lose on restart); there is no server-initiated stream, hence 405 for GET/DELETE.
  app.post(MCP_PATH, express.json({ limit: "64kb" }), async (req, res) => {
    const server = createMcpServer(upstream);
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
    res.on("close", () => void server.close().catch(() => {}));
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
  });
  app.all(MCP_PATH, (req, res) => {
    res.set("Allow", "POST").status(405).json(rpcError(-32000, "Method not allowed: POST only (stateless server)"));
  });

  // Plain JSON gateway (predates /mcp; kept for scripts, contract unchanged).
  app.get("/tools", (req, res) => res.json({ tools: listToolsPublic() }));
  app.post(/^\/tools\/([a-z0-9_]+)$/i, async (req, res) => {
    const tool = findTool(req.params[0]);
    if (!tool) return res.status(404).json({ error: "unknown_tool" });
    try {
      const payload = tool.method === "POST" ? await readGatewayBody(req, res) : {};
      const result = await callTool(tool.name, payload, upstream);
      res.json({ name: result.name, path: result.path, method: result.method, data: result.data });
    } catch (e) {
      res.status(e.status || 502).json({ error: e.message, body: e.body || null });
    }
  });

  app.use((req, res) => res.status(404).json({ error: "not_found" }));
  app.use((err, req, res, next) => {
    if (res.headersSent) return next(err);
    if (err.type === "entity.too.large") return res.status(413).json({ error: "body_too_large" });
    if (err.type === "entity.parse.failed") {
      return res.status(400).json(req.path === MCP_PATH ? rpcError(-32700, "Parse error") : { error: "bad_json" });
    }
    log(`error: ${err.message}`);
    res.status(500).json(req.path === MCP_PATH ? rpcError(-32603, "Internal error") : { error: "internal_error" });
  });
  return app;
}

function describeAuth(config) {
  const modes = [config.oauth && "oauth", config.requireToken && "api-token"].filter(Boolean);
  return modes.length ? modes.join(" + ") : "none, loopback only";
}

/** Resolves with the listening http.Server. */
export async function startHttp(
  config = loadHttpConfig(),
  { log = (s) => console.error(`[alphabound-mcp-http] ${s}`) } = {},
) {
  const server = http.createServer(createApp(config, { log }));
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(config.port, config.bind, () => {
      server.off("error", reject);
      resolve();
    });
  });
  log(
    `listening ${config.bind}:${server.address().port} -> ${config.upstream.base} ` +
      `(inbound auth: ${describeAuth(config)})`,
  );
  if (config.oauth) {
    log(`oauth issuer ${config.publicUrl.origin}; MCP endpoint ${new URL(MCP_PATH, config.publicUrl).href}`);
    if (!config.oauth.stateFile) {
      log("oauth state is in memory: a restart signs every client out (set ALPHABOUND_MCP_OAUTH_STATE_FILE)");
    }
  }
  if ((config.oauth || config.requireToken) && config.upstream.token.length < 24) {
    log("WARN ALPHABOUND_API_TOKEN is short (<24 chars); use a long random token before public exposure");
  }
  return server;
}
