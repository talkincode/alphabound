import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, describe, it } from "node:test";
import { UnauthorizedError } from "@modelcontextprotocol/sdk/client/auth.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { TOOLS } from "../src/client.js";
import { TOKEN, form, freePort, pkce, startGateway, startMockApi } from "./helpers.js";

const REDIRECT = "http://127.0.0.1:9/callback"; // nobody listens there: no test follows a redirect
const MCP_HEADERS = { "content-type": "application/json", accept: "application/json, text/event-stream" };
const LIST = { jsonrpc: "2.0", id: 1, method: "tools/list" };

const jsonPost = (url, body) =>
  fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

async function register(base, meta = {}) {
  const res = await jsonPost(`${base}/register`, {
    redirect_uris: [REDIRECT],
    client_name: "Test Client",
    token_endpoint_auth_method: "none",
    ...meta,
  });
  return { status: res.status, body: await res.json() };
}

function authorizeUrl(base, clientId, { challenge, redirect_uri = REDIRECT, state = "s-1", resource = `${base}/mcp`, ...extra }) {
  const params = {
    response_type: "code",
    client_id: clientId,
    redirect_uri,
    code_challenge: challenge,
    code_challenge_method: "S256",
    state,
    ...extra,
  };
  if (resource) params.resource = resource;
  return `${base}/authorize?${new URLSearchParams(params)}`;
}

/** GET /authorize: what the operator's browser shows. */
async function openConsent(base, clientId, opts) {
  const res = await fetch(authorizeUrl(base, clientId, opts), { redirect: "manual" });
  const html = await res.text();
  return { res, html, requestId: /name="request_id" value="([^"]+)"/.exec(html)?.[1] };
}

/** The operator presses a button on the consent page. */
function decide(base, requestId, { token = TOKEN, decision = "approve", headers = {} } = {}) {
  const f = form({ request_id: requestId, token, decision });
  return fetch(`${base}/oauth/consent`, {
    method: "POST",
    redirect: "manual",
    ...f,
    headers: { ...f.headers, ...headers },
  });
}

async function approve(base, clientId, opts) {
  const { requestId } = await openConsent(base, clientId, opts);
  const res = await decide(base, requestId);
  assert.equal(res.status, 302);
  return new URL(res.headers.get("location")).searchParams.get("code");
}

const exchange = (base, params) => fetch(`${base}/token`, { method: "POST", ...form(params) });

function codeParams(base, clientId, code, verifier, extra = {}) {
  return {
    grant_type: "authorization_code",
    client_id: clientId,
    code,
    code_verifier: verifier,
    redirect_uri: REDIRECT,
    resource: `${base}/mcp`,
    ...extra,
  };
}

/** Full authorization-code + PKCE flow for a registered client; returns the token response. */
async function login(base, clientId) {
  const { verifier, challenge } = pkce();
  const code = await approve(base, clientId, { challenge });
  const res = await exchange(base, codeParams(base, clientId, code, verifier));
  assert.equal(res.status, 200);
  return res.json();
}

const refresh = (base, clientId, refresh_token) =>
  exchange(base, { grant_type: "refresh_token", client_id: clientId, refresh_token });

const rpc = (base, token, body = LIST, headers = {}) =>
  fetch(`${base}/mcp`, {
    method: "POST",
    headers: { ...MCP_HEADERS, ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
    body: JSON.stringify(body),
  });

const errorOf = async (res) => (await res.json()).error;

describe("OAuth: discovery and challenge", () => {
  let mock;
  let gw;
  before(async () => {
    mock = await startMockApi();
    gw = await startGateway({ mock });
  });
  after(async () => {
    await gw.close();
    await mock.close();
  });

  it("challenges an anonymous MCP request with the protected-resource metadata URL", async () => {
    const r = await rpc(gw.base, null);
    assert.equal(r.status, 401);
    const challenge = r.headers.get("www-authenticate");
    assert.match(challenge, /^Bearer /);
    assert.ok(challenge.includes(`resource_metadata="${gw.base}/.well-known/oauth-protected-resource/mcp"`));
  });

  it("publishes RFC 9728 metadata naming this resource and its issuer", async () => {
    const r = await fetch(`${gw.base}/.well-known/oauth-protected-resource/mcp`);
    assert.equal(r.status, 200);
    const doc = await r.json();
    assert.equal(doc.resource, `${gw.base}/mcp`);
    assert.deepEqual(doc.authorization_servers, [`${gw.base}/`]);
  });

  it("publishes RFC 8414 metadata: PKCE S256 only, registration, revocation", async () => {
    const doc = await (await fetch(`${gw.base}/.well-known/oauth-authorization-server`)).json();
    assert.equal(doc.issuer, `${gw.base}/`);
    assert.equal(doc.authorization_endpoint, `${gw.base}/authorize`);
    assert.equal(doc.token_endpoint, `${gw.base}/token`);
    assert.equal(doc.registration_endpoint, `${gw.base}/register`);
    assert.equal(doc.revocation_endpoint, `${gw.base}/revoke`);
    assert.deepEqual(doc.code_challenge_methods_supported, ["S256"]);
    assert.deepEqual(doc.response_types_supported, ["code"]);
    assert.ok(doc.grant_types_supported.includes("authorization_code"));
    assert.ok(doc.grant_types_supported.includes("refresh_token"));
    // every client registered here is public, and the metadata says so
    assert.deepEqual(doc.token_endpoint_auth_methods_supported, ["none"]);
    assert.deepEqual(doc.revocation_endpoint_auth_methods_supported, ["none"]);
  });

  it("keeps /health open and does not reveal the daemon address", async () => {
    const body = await (await fetch(`${gw.base}/health`)).json();
    assert.deepEqual(body, { ok: true, tools: TOOLS.length });
  });
});

describe("OAuth: dynamic client registration", () => {
  let mock;
  let gw;
  before(async () => {
    mock = await startMockApi();
    gw = await startGateway({ mock });
  });
  after(async () => {
    await gw.close();
    await mock.close();
  });

  it("registers a public PKCE-only client and never issues a secret", async () => {
    const { status, body } = await register(gw.base, {
      client_name: "Claude",
      token_endpoint_auth_method: "client_secret_post",
    });
    assert.equal(status, 201);
    assert.match(body.client_id, /^[0-9a-f-]{36}$/);
    assert.equal(body.token_endpoint_auth_method, "none");
    assert.equal("client_secret" in body, false);
    assert.equal("client_secret_expires_at" in body, false);
    assert.deepEqual(body.grant_types, ["authorization_code", "refresh_token"]);
    assert.deepEqual(body.response_types, ["code"]);
    assert.equal(body.client_name, "Claude");
  });

  it("cleans the self-reported name: no control or bidi characters, bounded length, a default", async () => {
    const dirty = await register(gw.base, { client_name: `Evil\u202e\u200b\u0000Name ${"x".repeat(200)}` });
    assert.equal(dirty.status, 201);
    assert.doesNotMatch(dirty.body.client_name, /[\u202e\u200b\u0000]/);
    assert.ok(dirty.body.client_name.startsWith("Evil") && dirty.body.client_name.length <= 80);
    const anon = await register(gw.base, { client_name: undefined });
    assert.equal(anon.body.client_name, "Unnamed client");
  });

  it("accepts https, loopback, and private-use app redirect URIs", async () => {
    const uris = [
      "https://claude.ai/api/mcp/auth_callback",
      "http://localhost:6274/oauth/callback",
      "http://127.0.0.1:33418/",
      "http://[::1]:8080/cb",
      "cursor://anysphere.cursor-retrieval/oauth/alphabound/callback",
    ];
    const { status, body } = await register(gw.base, { redirect_uris: uris });
    assert.equal(status, 201);
    assert.deepEqual(body.redirect_uris, uris);
  });

  it("rejects redirect URIs that could leak an authorization code", async () => {
    const bad = [
      "http://evil.example/cb", // cleartext off-loopback
      "javascript:alert(1)",
      "file:///etc/passwd",
      "ftp://files.example/cb",
      "https://app.example/cb#frag",
      "https://user:pw@app.example/cb",
      "not a uri",
    ];
    for (const uri of bad) {
      const { status, body } = await register(gw.base, { redirect_uris: [uri] });
      assert.equal(status, 400, uri);
      assert.equal(body.error, "invalid_client_metadata", uri);
    }
    assert.equal((await register(gw.base, { redirect_uris: [] })).status, 400);
    const many = Array.from({ length: 11 }, (_, i) => `https://app.example/cb${i}`);
    assert.equal((await register(gw.base, { redirect_uris: many })).status, 400);
  });
});

describe("OAuth: authorization and consent", () => {
  let mock;
  let gw;
  let client;
  before(async () => {
    mock = await startMockApi();
    gw = await startGateway({ mock });
    client = (await register(gw.base, { client_name: "Consent Test" })).body;
  });
  after(async () => {
    await gw.close();
    await mock.close();
  });

  it("tells the operator who asks and where the browser goes; cannot be framed or cached", async () => {
    const { res, html, requestId } = await openConsent(gw.base, client.client_id, pkce());
    assert.equal(res.status, 200);
    assert.match(res.headers.get("content-type"), /text\/html/);
    assert.equal(res.headers.get("cache-control"), "no-store");
    assert.equal(res.headers.get("x-frame-options"), "DENY");
    assert.equal(res.headers.get("referrer-policy"), "no-referrer");
    assert.match(res.headers.get("content-security-policy"), /frame-ancestors 'none'/);
    assert.ok(html.includes("Consent Test"));
    assert.ok(html.includes(REDIRECT));
    assert.ok(html.includes('type="password"'));
    assert.ok(requestId.length >= 32);
    assert.equal(res.url.includes(requestId), false);
  });

  it("escapes everything the client controls: its name and its redirect URI, on the page and on retry", async () => {
    const xss = (await register(gw.base, { client_name: `<script>alert(1)</script>"'&` })).body;
    const named = await openConsent(gw.base, xss.client_id, pkce());
    assert.equal(named.html.includes("<script>"), false);
    assert.ok(named.html.includes("&lt;script&gt;alert(1)&lt;/script&gt;"));

    // URL syntax lets HTML-significant characters through in a query; the page must not trust them
    const hostile = 'https://app.example/cb?x="><img src=x onerror=alert(1)>&y=\'';
    const sly = (await register(gw.base, { redirect_uris: [hostile] })).body;
    const first = await openConsent(gw.base, sly.client_id, { ...pkce(), redirect_uri: hostile });
    const retry = await decide(gw.base, first.requestId, { token: "definitely-not-it" });
    for (const html of [first.html, await retry.text()]) {
      assert.equal(html.includes("<img"), false);
      assert.equal(html.includes('"><img'), false);
      assert.ok(html.includes("&quot;&gt;&lt;img src=x onerror=alert(1)&gt;"));
    }
  });

  it("gives a wrong token no code and leaves the request open for a retry", async () => {
    const { requestId } = await openConsent(gw.base, client.client_id, pkce());
    const wrong = await decide(gw.base, requestId, { token: "definitely-not-it" });
    assert.equal(wrong.status, 401);
    assert.equal(wrong.headers.get("location"), null);
    const page = await wrong.text();
    assert.ok(page.includes("not accepted") && page.includes(requestId));
    const ok = await decide(gw.base, requestId);
    assert.equal(ok.status, 302);
  });

  it("approves with the code and the caller's state on the registered redirect", async () => {
    const { requestId } = await openConsent(gw.base, client.client_id, { ...pkce(), state: "keep-me" });
    const res = await decide(gw.base, requestId);
    assert.equal(res.status, 302);
    const to = new URL(res.headers.get("location"));
    assert.equal(`${to.origin}${to.pathname}`, REDIRECT);
    assert.equal(to.searchParams.get("state"), "keep-me");
    assert.match(to.searchParams.get("code"), /^abmcp_ac_/);
    assert.equal(to.searchParams.get("error"), null);
  });

  it("lets a consent request be used once", async () => {
    const { requestId } = await openConsent(gw.base, client.client_id, pkce());
    assert.equal((await decide(gw.base, requestId)).status, 302);
    assert.equal((await decide(gw.base, requestId)).status, 400);
    assert.equal((await decide(gw.base, "never-issued")).status, 400);
    assert.equal((await decide(gw.base, undefined)).status, 400);
  });

  it("denies with access_denied and state, issuing nothing", async () => {
    const { requestId } = await openConsent(gw.base, client.client_id, { ...pkce(), state: "deny-state" });
    const res = await decide(gw.base, requestId, { decision: "deny", token: "" });
    assert.equal(res.status, 302);
    const to = new URL(res.headers.get("location"));
    assert.equal(to.searchParams.get("error"), "access_denied");
    assert.equal(to.searchParams.get("state"), "deny-state");
    assert.equal(to.searchParams.get("code"), null);
    assert.equal((await decide(gw.base, requestId)).status, 400);
  });

  it("refuses a resource that names another server; accepts this one however it is spelled", async () => {
    const other = await openConsent(gw.base, client.client_id, { ...pkce(), resource: "https://other.example/mcp" });
    assert.equal(other.res.status, 302);
    assert.equal(new URL(other.res.headers.get("location")).searchParams.get("error"), "invalid_target");
    for (const resource of [`${gw.base}/mcp`, `${gw.base}/mcp/`, gw.base, `${gw.base}/`, null]) {
      const r = await openConsent(gw.base, client.client_id, { ...pkce(), resource });
      assert.equal(r.res.status, 200, String(resource));
    }
  });

  it("never redirects to an unregistered URI or for an unknown client", async () => {
    const stray = await openConsent(gw.base, client.client_id, { ...pkce(), redirect_uri: "https://evil.example/cb" });
    assert.equal(stray.res.status, 400);
    assert.equal(stray.res.headers.get("location"), null);
    const unknown = await openConsent(gw.base, "no-such-client", pkce());
    assert.equal(unknown.res.status, 400);
    assert.equal(unknown.res.headers.get("location"), null);
  });

  it("lets a loopback client change only the port, never userinfo or a fragment", async () => {
    // The SDK's loopback match (RFC 8252 §7.3) compares scheme, host, path and query, so the
    // gateway has to hold the line on the parts it ignores.
    const loopback = (await register(gw.base, { redirect_uris: ["http://localhost:9000/cb"] })).body;
    const open = (redirect_uri) => openConsent(gw.base, loopback.client_id, { ...pkce(), redirect_uri });

    const otherPort = await open("http://localhost:4321/cb");
    assert.equal(otherPort.res.status, 200);
    assert.ok(otherPort.html.includes("http://localhost:4321/cb"));
    const approved = await decide(gw.base, otherPort.requestId);
    assert.equal(new URL(approved.headers.get("location")).origin, "http://localhost:4321");

    for (const bad of ["http://localhost:4321/cb#unexpected", "http://name:password@localhost:4321/cb"]) {
      const r = await open(bad);
      assert.equal(r.res.status, 400, bad);
      assert.equal(r.res.headers.get("location"), null, bad);
      assert.equal(r.requestId, undefined, bad);
      assert.match(r.html, /Unsupported redirect_uri/);
      // ...nor may the SDK send an *error* there: its other checks run before the provider does
      const failing = await openConsent(gw.base, loopback.client_id, {
        ...pkce(),
        redirect_uri: bad,
        code_challenge_method: "plain",
      });
      assert.equal(failing.res.status, 400, bad);
      assert.equal(failing.res.headers.get("location"), null, bad);
    }
    // other hosts, paths, and queries never matched in the first place
    for (const bad of ["http://127.0.0.1:9000/cb", "http://localhost:9000/other", "http://localhost:9000/cb?x=1"]) {
      assert.equal((await open(bad)).res.status, 400, bad);
    }
  });

  it("requires PKCE S256", async () => {
    const plain = await openConsent(gw.base, client.client_id, { ...pkce(), code_challenge_method: "plain" });
    assert.equal(plain.res.status, 302);
    assert.equal(new URL(plain.res.headers.get("location")).searchParams.get("error"), "invalid_request");
    const none = await fetch(
      `${gw.base}/authorize?${new URLSearchParams({ response_type: "code", client_id: client.client_id, redirect_uri: REDIRECT })}`,
      { redirect: "manual" },
    );
    assert.equal(none.status, 302);
    assert.equal(new URL(none.headers.get("location")).searchParams.get("error"), "invalid_request");
  });
});

describe("OAuth: brute-force guard on the consent form", () => {
  let mock;
  let gw;
  before(async () => {
    mock = await startMockApi();
    gw = await startGateway({ mock });
  });
  after(async () => {
    await gw.close();
    await mock.close();
  });

  it("locks the source out after 8 wrong tokens, even for the right one", async () => {
    const client = (await register(gw.base)).body;
    const { requestId } = await openConsent(gw.base, client.client_id, pkce());
    for (let i = 0; i < 8; i += 1) {
      assert.equal((await decide(gw.base, requestId, { token: `guess-${i}` })).status, 401, `attempt ${i + 1}`);
    }
    const locked = await decide(gw.base, requestId, { token: TOKEN });
    assert.equal(locked.status, 429);
    assert.ok(Number(locked.headers.get("retry-after")) > 0);
    assert.equal(locked.headers.get("location"), null);
  });
});

// docs/DASHBOARD_AUTH_MCP.md: a forged X-Forwarded-For must not be able to dodge the lockout.
describe("OAuth: lockout key and X-Forwarded-For", () => {
  let mock;
  before(async () => {
    mock = await startMockApi();
  });
  after(() => mock.close());

  async function lockOut(gw, xff) {
    const client = (await register(gw.base)).body;
    const { requestId } = await openConsent(gw.base, client.client_id, pkce());
    for (let i = 0; i < 8; i += 1) {
      await decide(gw.base, requestId, { token: `guess-${i}`, headers: { "x-forwarded-for": xff } });
    }
    return requestId;
  }

  it("ignores X-Forwarded-For unless a proxy is trusted (the default)", async () => {
    const gw = await startGateway({ mock });
    try {
      const requestId = await lockOut(gw, "198.51.100.1");
      const forged = await decide(gw.base, requestId, { headers: { "x-forwarded-for": "203.0.113.7" } });
      assert.equal(forged.status, 429);
    } finally {
      await gw.close();
    }
  });

  it("with one trusted proxy, locks out the right-most hop and ignores forged left-most entries", async () => {
    const gw = await startGateway({ mock, env: { ALPHABOUND_MCP_TRUST_PROXY: "1" } });
    try {
      const requestId = await lockOut(gw, "198.51.100.1");
      // the attacker prepends a fresh address; the proxy appended the real peer on the right
      const forged = await decide(gw.base, requestId, { headers: { "x-forwarded-for": "203.0.113.7, 198.51.100.1" } });
      assert.equal(forged.status, 429);
      // a genuinely different client is not collateral damage
      const other = await decide(gw.base, requestId, { headers: { "x-forwarded-for": "203.0.113.7" } });
      assert.equal(other.status, 302);
    } finally {
      await gw.close();
    }
  });
});

describe("OAuth: token endpoint", () => {
  let mock;
  let gw;
  let client;
  before(async () => {
    mock = await startMockApi();
    gw = await startGateway({ mock });
    client = (await register(gw.base)).body;
  });
  after(async () => {
    await gw.close();
    await mock.close();
  });

  it("issues tokens that open /mcp, and the daemon only ever sees the gateway's own credential", async () => {
    const tokens = await login(gw.base, client.client_id);
    assert.equal(tokens.token_type, "Bearer");
    assert.equal(tokens.expires_in, 3600);
    assert.match(tokens.access_token, /^abmcp_at_/);
    assert.match(tokens.refresh_token, /^abmcp_rt_/);

    const before = mock.seen.length;
    const call = { jsonrpc: "2.0", id: 7, method: "tools/call", params: { name: "get_state", arguments: {} } };
    const r = await rpc(gw.base, tokens.access_token, call);
    assert.equal(r.status, 200);
    const upstream = mock.seen.slice(before);
    assert.equal(upstream.length, 1);
    assert.equal(upstream[0].authorization, `Bearer ${TOKEN}`);
    assert.equal(
      mock.seen.some((s) => s.authorization.includes("abmcp_")),
      false,
    );
  });

  it("answers token requests with no-store", async () => {
    const { verifier, challenge } = pkce();
    const code = await approve(gw.base, client.client_id, { challenge });
    const res = await exchange(gw.base, codeParams(gw.base, client.client_id, code, verifier));
    assert.equal(res.headers.get("cache-control"), "no-store");
  });

  it("rejects a wrong PKCE verifier, and the code is burned", async () => {
    const { verifier, challenge } = pkce();
    const code = await approve(gw.base, client.client_id, { challenge });
    const bad = await exchange(gw.base, codeParams(gw.base, client.client_id, code, pkce().verifier));
    assert.equal(bad.status, 400);
    assert.equal(await errorOf(bad), "invalid_grant");
    const retry = await exchange(gw.base, codeParams(gw.base, client.client_id, code, verifier));
    assert.equal(retry.status, 400);
    assert.equal(await errorOf(retry), "invalid_grant");
  });

  it("refuses a replayed code and revokes what it already produced", async () => {
    const { verifier, challenge } = pkce();
    const code = await approve(gw.base, client.client_id, { challenge });
    const params = codeParams(gw.base, client.client_id, code, verifier);
    const first = await (await exchange(gw.base, params)).json();
    assert.equal((await rpc(gw.base, first.access_token)).status, 200);

    const replay = await exchange(gw.base, params);
    assert.equal(replay.status, 400);
    assert.equal(await errorOf(replay), "invalid_grant");
    assert.equal((await rpc(gw.base, first.access_token)).status, 401);
    assert.equal((await refresh(gw.base, client.client_id, first.refresh_token)).status, 400);
  });

  it("binds the code to its redirect_uri, its client, and this server", async () => {
    const redirect = pkce();
    const c1 = await approve(gw.base, client.client_id, redirect);
    const wrongRedirect = await exchange(
      gw.base,
      codeParams(gw.base, client.client_id, c1, redirect.verifier, { redirect_uri: "http://127.0.0.1:9/elsewhere" }),
    );
    assert.equal(await errorOf(wrongRedirect), "invalid_grant");

    const stranger = (await register(gw.base)).body;
    const mine = pkce();
    const c2 = await approve(gw.base, client.client_id, mine);
    const stolen = await exchange(gw.base, codeParams(gw.base, stranger.client_id, c2, mine.verifier));
    assert.equal(await errorOf(stolen), "invalid_grant");

    const audience = pkce();
    const c3 = await approve(gw.base, client.client_id, audience);
    const wrongAudience = await exchange(
      gw.base,
      codeParams(gw.base, client.client_id, c3, audience.verifier, { resource: "https://other.example/mcp" }),
    );
    assert.equal(await errorOf(wrongAudience), "invalid_target");
  });

  it("requires the PKCE verifier and supports only the two grants it advertises", async () => {
    const { challenge } = pkce();
    const code = await approve(gw.base, client.client_id, { challenge });
    const noVerifier = await exchange(gw.base, {
      grant_type: "authorization_code",
      client_id: client.client_id,
      code,
      redirect_uri: REDIRECT,
    });
    assert.equal(noVerifier.status, 400);
    assert.equal(await errorOf(noVerifier), "invalid_request");
    const cc = await exchange(gw.base, { grant_type: "client_credentials", client_id: client.client_id });
    assert.equal(await errorOf(cc), "unsupported_grant_type");
    const unknown = await exchange(gw.base, { grant_type: "authorization_code", client_id: "nope", code: "x", code_verifier: "y" });
    assert.equal(await errorOf(unknown), "invalid_client");
  });

  it("rotates the refresh token and treats a replay of any used one as theft", async () => {
    const t1 = await login(gw.base, client.client_id);
    const r2 = await refresh(gw.base, client.client_id, t1.refresh_token);
    assert.equal(r2.status, 200);
    const t2 = await r2.json();
    assert.notEqual(t2.refresh_token, t1.refresh_token);
    assert.equal((await rpc(gw.base, t2.access_token)).status, 200);
    assert.equal((await rpc(gw.base, t1.access_token)).status, 200); // access tokens run to their own expiry
    const t3 = await (await refresh(gw.base, client.client_id, t2.refresh_token)).json();
    const t4 = await (await refresh(gw.base, client.client_id, t3.refresh_token)).json();

    // The oldest token returns, three generations behind (a thief rotating repeatedly cannot hide).
    const replay = await refresh(gw.base, client.client_id, t1.refresh_token);
    assert.equal(replay.status, 400);
    assert.equal(await errorOf(replay), "invalid_grant");
    // the whole grant is gone, including the newest pair
    assert.equal((await rpc(gw.base, t4.access_token)).status, 401);
    assert.equal((await refresh(gw.base, client.client_id, t4.refresh_token)).status, 400);
  });

  it("refuses forged, truncated, and swapped tokens", async () => {
    const t = await login(gw.base, client.client_id);
    const flip = (s) => s.slice(0, -1) + (s.endsWith("A") ? "B" : "A");
    for (const bad of [flip(t.access_token), t.access_token.slice(0, -4), t.refresh_token, "abmcp_at_x.1.y"]) {
      assert.equal((await rpc(gw.base, bad)).status, 401, bad);
    }
    for (const bad of [flip(t.refresh_token), t.refresh_token.slice(0, -4), t.access_token, "abmcp_rt_x.1.y"]) {
      assert.equal((await refresh(gw.base, client.client_id, bad)).status, 400, bad);
    }
    // none of that ended the real grant
    assert.equal((await rpc(gw.base, t.access_token)).status, 200);
    assert.equal((await refresh(gw.base, client.client_id, t.refresh_token)).status, 200);
  });

  it("will not refresh for a different client, or for another resource", async () => {
    const t = await login(gw.base, client.client_id);
    const stranger = (await register(gw.base)).body;
    assert.equal((await refresh(gw.base, stranger.client_id, t.refresh_token)).status, 400);
    const wrongAudience = await exchange(gw.base, {
      grant_type: "refresh_token",
      client_id: client.client_id,
      refresh_token: t.refresh_token,
      resource: "https://other.example/mcp",
    });
    assert.equal(await errorOf(wrongAudience), "invalid_target");
    assert.equal((await refresh(gw.base, client.client_id, t.refresh_token)).status, 200);
  });

  it("revokes the whole grant when either token is revoked, only for the owning client", async () => {
    const revoke = (clientId, token) =>
      fetch(`${gw.base}/revoke`, { method: "POST", ...form({ client_id: clientId, token }) });
    const stranger = (await register(gw.base)).body;

    const a = await login(gw.base, client.client_id);
    assert.equal((await revoke(stranger.client_id, a.access_token)).status, 200); // silent no-op
    assert.equal((await rpc(gw.base, a.access_token)).status, 200);
    assert.equal((await revoke(client.client_id, a.access_token)).status, 200);
    assert.equal((await rpc(gw.base, a.access_token)).status, 401);
    assert.equal((await refresh(gw.base, client.client_id, a.refresh_token)).status, 400);

    const b = await login(gw.base, client.client_id);
    assert.equal((await revoke(client.client_id, b.refresh_token)).status, 200);
    assert.equal((await rpc(gw.base, b.access_token)).status, 401);
    assert.equal((await revoke(client.client_id, "abmcp_at_never-issued")).status, 200);
  });
});

describe("OAuth: access-token validation at /mcp", () => {
  let mock;
  let gw;
  let other;
  let token;
  before(async () => {
    mock = await startMockApi();
    gw = await startGateway({ mock });
    other = await startGateway({ mock });
    token = (await login(gw.base, (await register(gw.base)).body.client_id)).access_token;
  });
  after(async () => {
    await gw.close();
    await other.close();
    await mock.close();
  });

  it("accepts only a Bearer access token in the Authorization header", async () => {
    assert.equal((await rpc(gw.base, token)).status, 200);
    assert.equal((await rpc(gw.base, "abmcp_at_garbage")).status, 401);
    assert.equal((await rpc(gw.base, null)).status, 401);
    // RFC 6750: never from the query string, and X-API-Token is for the static token only
    const query = await fetch(`${gw.base}/mcp?access_token=${token}`, { method: "POST", headers: MCP_HEADERS, body: JSON.stringify(LIST) });
    assert.equal(query.status, 401);
    const header = await rpc(gw.base, null, LIST, { "x-api-token": token });
    assert.equal(header.status, 401);
    const basic = await rpc(gw.base, null, LIST, { authorization: `Basic ${token}` });
    assert.equal(basic.status, 401);
  });

  it("does not take the raw API token unless ALPHABOUND_MCP_REQUIRE_TOKEN=1", async () => {
    assert.equal((await rpc(gw.base, TOKEN)).status, 401);
    assert.equal((await rpc(gw.base, null, LIST, { "x-api-token": TOKEN })).status, 401);
    assert.equal((await fetch(`${gw.base}/tools`, { headers: { authorization: `Bearer ${TOKEN}` } })).status, 401);
  });

  it("guards the plain JSON gateway with the same access tokens", async () => {
    assert.equal((await fetch(`${gw.base}/tools`)).status, 401);
    const r = await fetch(`${gw.base}/tools`, { headers: { authorization: `Bearer ${token}` } });
    assert.equal(r.status, 200);
    assert.equal((await r.json()).tools.length, TOOLS.length);
  });

  it("a token is worthless at any other gateway, even with the same operator secret", async () => {
    assert.equal((await rpc(other.base, token)).status, 401);
  });

  it("answers an invalid token with invalid_token and the discovery pointer", async () => {
    const r = await rpc(gw.base, "abmcp_at_garbage");
    assert.equal(r.status, 401);
    assert.equal(await errorOf(r), "invalid_token");
    assert.match(r.headers.get("www-authenticate"), /error="invalid_token".*resource_metadata=/);
  });
});

describe("OAuth together with the static API token", () => {
  let mock;
  let gw;
  before(async () => {
    mock = await startMockApi();
    gw = await startGateway({ mock, env: { ALPHABOUND_MCP_REQUIRE_TOKEN: "1" } });
  });
  after(async () => {
    await gw.close();
    await mock.close();
  });

  it("accepts either credential and rejects everything else with the OAuth challenge", async () => {
    const oauth = (await login(gw.base, (await register(gw.base)).body.client_id)).access_token;
    assert.equal((await rpc(gw.base, TOKEN)).status, 200);
    assert.equal((await rpc(gw.base, null, LIST, { "x-api-token": TOKEN })).status, 200);
    assert.equal((await rpc(gw.base, oauth)).status, 200);
    const nope = await rpc(gw.base, "neither");
    assert.equal(nope.status, 401);
    assert.match(nope.headers.get("www-authenticate"), /resource_metadata=/);
  });
});

describe("OAuth: state across restarts", () => {
  let mock;
  let dir;
  let file;
  let port;
  const envFor = (extra = {}) => ({ ALPHABOUND_MCP_OAUTH_STATE_FILE: file, ...extra });
  before(async () => {
    mock = await startMockApi();
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "ab-mcp-oauth-"));
    file = path.join(dir, "state", "oauth.json");
    port = await freePort();
  });
  after(async () => {
    await mock.close();
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it("keeps clients and grants, writes the file 0600, and never stores a raw token", async () => {
    const a = await startGateway({ mock, port, env: envFor() });
    const client = (await register(a.base)).body;
    const tokens = await login(a.base, client.client_id);
    await a.close();

    const text = fs.readFileSync(file, "utf8");
    assert.ok(text.includes(client.client_id));
    for (const secret of [tokens.access_token, tokens.refresh_token, TOKEN]) assert.equal(text.includes(secret), false);
    if (process.platform !== "win32") assert.equal(fs.statSync(file).mode & 0o777, 0o600);

    const b = await startGateway({ mock, port, env: envFor() });
    try {
      assert.equal((await rpc(b.base, tokens.access_token)).status, 200);
      const known = await openConsent(b.base, client.client_id, pkce());
      assert.equal(known.res.status, 200);
      assert.equal((await refresh(b.base, client.client_id, tokens.refresh_token)).status, 200);
    } finally {
      await b.close();
    }
  });

  it("rotating ALPHABOUND_API_TOKEN orphans every issued token but keeps registrations", async () => {
    const rotated = "rotated-operator-token-0123456789abcdef";
    const a = await startGateway({ mock, port, env: envFor() });
    const client = (await register(a.base)).body;
    const tokens = await login(a.base, client.client_id);
    await a.close();

    const b = await startGateway({ mock, port, env: envFor({ ALPHABOUND_API_TOKEN: rotated }) });
    try {
      assert.equal((await rpc(b.base, tokens.access_token)).status, 401);
      assert.equal((await refresh(b.base, client.client_id, tokens.refresh_token)).status, 400);
      const { requestId, res } = await openConsent(b.base, client.client_id, pkce());
      assert.equal(res.status, 200);
      assert.equal((await decide(b.base, requestId, { token: TOKEN })).status, 401); // the old secret no longer approves
      assert.equal((await decide(b.base, requestId, { token: rotated })).status, 302);
    } finally {
      await b.close();
    }
  });

  it("a changed public URL orphans tokens too (the audience is part of the key)", async () => {
    const a = await startGateway({ mock, port, env: envFor() });
    const tokens = await login(a.base, (await register(a.base)).body.client_id);
    await a.close();
    const b = await startGateway({ mock, port, env: envFor({ ALPHABOUND_MCP_PUBLIC_URL: `http://localhost:${port}` }) });
    try {
      assert.equal((await rpc(b.base, tokens.access_token)).status, 401);
    } finally {
      await b.close();
    }
  });

  it("refuses to start on a corrupt or foreign state file", async () => {
    const bad = path.join(dir, "corrupt.json");
    fs.writeFileSync(bad, "{nope");
    await assert.rejects(startGateway({ mock, env: { ALPHABOUND_MCP_OAUTH_STATE_FILE: bad } }), /not valid JSON/);
    fs.writeFileSync(bad, JSON.stringify({ version: 99 }));
    await assert.rejects(startGateway({ mock, env: { ALPHABOUND_MCP_OAUTH_STATE_FILE: bad } }), /unsupported OAuth state file version/);
  });
});

/** A scripted operator: plays the browser, types the token, and hands the code back. */
class OperatorBrowserProvider {
  constructor(base) {
    this.base = base;
    this.approvals = 0;
  }
  get redirectUrl() {
    return REDIRECT;
  }
  get clientMetadata() {
    return {
      client_name: "SDK interop test",
      redirect_uris: [REDIRECT],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
    };
  }
  clientInformation() {
    return this.info;
  }
  saveClientInformation(info) {
    this.info = info;
  }
  tokens() {
    return this.saved;
  }
  saveTokens(tokens) {
    this.saved = tokens;
  }
  saveCodeVerifier(verifier) {
    this.verifier = verifier;
  }
  codeVerifier() {
    return this.verifier;
  }
  async redirectToAuthorization(url) {
    const page = await fetch(url);
    const requestId = /name="request_id" value="([^"]+)"/.exec(await page.text())[1];
    const res = await decide(this.base, requestId);
    this.code = new URL(res.headers.get("location")).searchParams.get("code");
    this.approvals += 1;
  }
}

describe("OAuth: interoperability with the MCP SDK client", () => {
  let mock;
  let gw;
  before(async () => {
    mock = await startMockApi();
    gw = await startGateway({ mock });
  });
  after(async () => {
    await gw.close();
    await mock.close();
  });

  it("discovers, registers, authorizes, calls tools, and refreshes without a second consent", async () => {
    const provider = new OperatorBrowserProvider(gw.base);
    const url = new URL(`${gw.base}/mcp`);

    // First attempt: 401 -> RFC 9728/8414 discovery -> RFC 7591 registration -> PKCE + resource -> consent.
    const first = new StreamableHTTPClientTransport(url, { authProvider: provider });
    await assert.rejects(new Client({ name: "sdk-interop", version: "1.0.0" }).connect(first), UnauthorizedError);
    assert.equal(provider.approvals, 1);
    assert.equal(provider.info.token_endpoint_auth_method, "none");
    await first.finishAuth(provider.code);
    assert.match(provider.saved.access_token, /^abmcp_at_/);

    const client = new Client({ name: "sdk-interop", version: "1.0.0" });
    await client.connect(new StreamableHTTPClientTransport(url, { authProvider: provider }));
    try {
      const { tools } = await client.listTools();
      assert.equal(tools.length, TOOLS.length);
      const ok = await client.callTool({ name: "get_system", arguments: {} });
      assert.equal(JSON.parse(ok.content[0].text).path, "/api/v1/system");

      // The access token dies; the SDK silently uses the refresh token (rotating it).
      const oldRefresh = provider.saved.refresh_token;
      provider.saved = { ...provider.saved, access_token: "abmcp_at_expired" };
      const again = await client.callTool({ name: "get_system", arguments: {} });
      assert.equal(again.isError, undefined);
      assert.equal(provider.approvals, 1);
      assert.notEqual(provider.saved.access_token, "abmcp_at_expired");
      assert.notEqual(provider.saved.refresh_token, oldRefresh);
    } finally {
      await client.close();
    }
  });
});
