import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { runCli } from "../src/cli.js";
import { TOOLS } from "../src/client.js";
import { loadHttpConfig, startHttp } from "../src/http.js";
import { TOKEN, rawRequest, startGateway, startMockApi } from "./helpers.js";

const MCP_HEADERS = { "content-type": "application/json", accept: "application/json, text/event-stream" };
const initialize = {
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "0" } },
};

async function connect(base, requestInit) {
  const client = new Client({ name: "http-test", version: "1.0.0" });
  await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp`), { requestInit }));
  return client;
}

describe("loadHttpConfig", () => {
  it("defaults to loopback with no inbound auth", () => {
    const c = loadHttpConfig({});
    assert.equal(c.bind, "127.0.0.1");
    assert.equal(c.port, 8723);
    assert.equal(c.oauth, null);
    assert.equal(c.requireToken, false);
    assert.deepEqual(c.allowedHosts, ["localhost", "127.0.0.1", "[::1]"]);
  });

  it("refuses a non-loopback bind without inbound auth", () => {
    assert.throws(() => loadHttpConfig({ ALPHABOUND_MCP_BIND: "0.0.0.0" }), /without inbound auth/);
    assert.throws(() => loadHttpConfig({ ALPHABOUND_MCP_BIND: "192.0.2.10" }), /without inbound auth/);
  });

  it("allows a non-loopback bind once a gate is on", () => {
    const env = { ALPHABOUND_MCP_BIND: "0.0.0.0", ALPHABOUND_API_TOKEN: TOKEN };
    assert.equal(loadHttpConfig({ ...env, ALPHABOUND_MCP_REQUIRE_TOKEN: "1" }).requireToken, true);
    const c = loadHttpConfig({
      ...env,
      ALPHABOUND_MCP_OAUTH: "1",
      ALPHABOUND_MCP_PUBLIC_URL: "https://mcp.example.com",
    });
    assert.ok(c.oauth);
    assert.equal(c.publicUrl.origin, "https://mcp.example.com");
  });

  it("a gate without ALPHABOUND_API_TOKEN would fail closed for everyone, so it is an error", () => {
    assert.throws(() => loadHttpConfig({ ALPHABOUND_MCP_REQUIRE_TOKEN: "1" }), /ALPHABOUND_API_TOKEN/);
    assert.throws(
      () => loadHttpConfig({ ALPHABOUND_MCP_OAUTH: "1", ALPHABOUND_MCP_PUBLIC_URL: "https://mcp.example.com" }),
      /ALPHABOUND_API_TOKEN/,
    );
  });

  it("OAuth needs a public origin: present, https (or localhost), and without a path", () => {
    const env = { ALPHABOUND_MCP_OAUTH: "1", ALPHABOUND_API_TOKEN: TOKEN };
    assert.throws(() => loadHttpConfig(env), /ALPHABOUND_MCP_PUBLIC_URL/);
    assert.throws(() => loadHttpConfig({ ...env, ALPHABOUND_MCP_PUBLIC_URL: "http://mcp.example.com" }), /https/);
    assert.throws(() => loadHttpConfig({ ...env, ALPHABOUND_MCP_PUBLIC_URL: "https://mcp.example.com/mcp" }), /origin/);
    assert.throws(() => loadHttpConfig({ ...env, ALPHABOUND_MCP_PUBLIC_URL: "nonsense" }), /not a valid URL/);
    assert.ok(loadHttpConfig({ ...env, ALPHABOUND_MCP_PUBLIC_URL: "http://127.0.0.1:8723" }).oauth);
    assert.ok(loadHttpConfig({ ...env, ALPHABOUND_MCP_PUBLIC_URL: "https://mcp.example.com/" }).oauth);
  });

  it("allows the public hostname in the Host/Origin guard, and leaves a bare public bind unchecked", () => {
    const gated = { ALPHABOUND_MCP_REQUIRE_TOKEN: "1", ALPHABOUND_API_TOKEN: TOKEN };
    assert.deepEqual(
      loadHttpConfig({ ...gated, ALPHABOUND_MCP_PUBLIC_URL: "https://mcp.example.com" }).allowedHosts,
      ["localhost", "127.0.0.1", "[::1]", "mcp.example.com"],
    );
    assert.equal(loadHttpConfig({ ...gated, ALPHABOUND_MCP_BIND: "0.0.0.0" }).allowedHosts, null);
  });

  it("validates port, proxy hops, and resolves the state file", () => {
    assert.throws(() => loadHttpConfig({ ALPHABOUND_MCP_PORT: "http" }), /ALPHABOUND_MCP_PORT/);
    assert.throws(() => loadHttpConfig({ ALPHABOUND_MCP_TRUST_PROXY: "yes" }), /TRUST_PROXY/);
    assert.equal(loadHttpConfig({ ALPHABOUND_MCP_TRUST_PROXY: "1" }).trustProxy, 1);
    const c = loadHttpConfig({
      ALPHABOUND_MCP_OAUTH: "1",
      ALPHABOUND_API_TOKEN: TOKEN,
      ALPHABOUND_MCP_PUBLIC_URL: "http://localhost:8723",
      ALPHABOUND_MCP_OAUTH_STATE_FILE: "state/oauth.json",
    });
    assert.ok(c.oauth.stateFile.endsWith("/state/oauth.json") && c.oauth.stateFile.startsWith("/"));
  });
});

describe("alphabound-mcp --http startup", () => {
  it("reports a configuration error and exits 1 instead of crashing", async () => {
    const saved = { ...process.env };
    process.env.ALPHABOUND_MCP_BIND = "0.0.0.0";
    delete process.env.ALPHABOUND_MCP_OAUTH;
    delete process.env.ALPHABOUND_MCP_REQUIRE_TOKEN;
    const errs = [];
    try {
      const code = await runCli(["--http"], { err: (s) => errs.push(s), log: () => {} });
      assert.equal(code, 1);
      assert.match(errs.join("\n"), /refusing to listen on 0\.0\.0\.0 without inbound auth/);
    } finally {
      for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k];
      Object.assign(process.env, saved);
    }
  });

  it("rejects when the port is taken", async () => {
    const mock = await startMockApi();
    const first = await startGateway({ mock, oauth: false });
    try {
      const config = loadHttpConfig({ ALPHABOUND_MCP_PORT: String(new URL(first.base).port) });
      await assert.rejects(startHttp(config, { log: () => {} }), { code: "EADDRINUSE" });
    } finally {
      await first.close();
      await mock.close();
    }
  });
});

describe("MCP Streamable HTTP, loopback with no inbound auth", () => {
  let mock;
  let gw;

  before(async () => {
    mock = await startMockApi();
    gw = await startGateway({ mock, oauth: false });
  });
  after(async () => {
    await gw.close();
    await mock.close();
  });

  it("serves the same catalog as stdio and calls the daemon", async () => {
    const client = await connect(gw.base);
    try {
      const { tools } = await client.listTools();
      assert.deepEqual(
        tools.map((t) => t.name),
        TOOLS.map((t) => t.name),
      );
      assert.ok(tools.find((t) => t.name === "submit_intel").inputSchema.required.includes("signature"));

      const r = await client.callTool({ name: "get_state", arguments: {} });
      assert.equal(r.isError, undefined);
      const out = JSON.parse(r.content[0].text);
      assert.equal(out.path, "/api/v1/state");
      assert.equal(out.data.ok, true);
    } finally {
      await client.close();
    }
  });

  it("forwards submit_intel as a POST and nothing else", async () => {
    const client = await connect(gw.base);
    try {
      const before = mock.seen.length;
      const envelope = { schema: "alphabound.intel.v1", id: "intel_http_test", signature: "ab" };
      const r = await client.callTool({ name: "submit_intel", arguments: envelope });
      assert.equal(JSON.parse(r.content[0].text).method, "POST");
      const calls = mock.seen.slice(before);
      assert.equal(calls.length, 1);
      assert.equal(calls[0].method, "POST");
      assert.equal(calls[0].url, "/api/v1/intel");
    } finally {
      await client.close();
    }
  });

  it("has no trading control tool", async () => {
    const client = await connect(gw.base);
    try {
      const names = (await client.listTools()).tools.map((t) => t.name);
      for (const forbidden of ["place_order", "flatten", "resume", "target_weight"]) {
        assert.equal(names.includes(forbidden), false);
      }
      const r = await client.callTool({ name: "place_order", arguments: {} });
      assert.equal(r.isError, true);
    } finally {
      await client.close();
    }
  });

  it("turns a daemon failure into a tool error, not a transport error", async () => {
    const failing = await startGateway({ mock, oauth: false, env: { ALPHABOUND_API_TOKEN: "not-the-daemon-token" } });
    const client = await connect(failing.base);
    try {
      const r = await client.callTool({ name: "get_system", arguments: {} });
      assert.equal(r.isError, true);
      assert.equal(JSON.parse(r.content[0].text).status, 401);
    } finally {
      await client.close();
      await failing.close();
    }
  });

  it("mounts no OAuth endpoints unless ALPHABOUND_MCP_OAUTH=1", async () => {
    for (const path of ["/.well-known/oauth-authorization-server", "/.well-known/oauth-protected-resource/mcp"]) {
      assert.equal((await fetch(`${gw.base}${path}`)).status, 404, path);
    }
    assert.equal((await fetch(`${gw.base}/register`, { method: "POST" })).status, 404);
    assert.equal((await fetch(`${gw.base}/oauth/consent`, { method: "POST" })).status, 404);
  });

  it("is stateless: no session id, and GET / DELETE are 405", async () => {
    const init = await fetch(`${gw.base}/mcp`, { method: "POST", headers: MCP_HEADERS, body: JSON.stringify(initialize) });
    assert.equal(init.status, 200);
    assert.equal(init.headers.get("mcp-session-id"), null);
    assert.match(init.headers.get("content-type"), /application\/json/);
    for (const method of ["GET", "DELETE"]) {
      const r = await fetch(`${gw.base}/mcp`, { method, headers: MCP_HEADERS });
      assert.equal(r.status, 405, method);
      assert.equal(r.headers.get("allow"), "POST");
    }
  });

  it("answers malformed and oversized bodies with JSON, not a stack trace", async () => {
    const bad = await fetch(`${gw.base}/mcp`, { method: "POST", headers: MCP_HEADERS, body: "{nope" });
    assert.equal(bad.status, 400);
    assert.equal((await bad.json()).error.code, -32700);
    const big = await fetch(`${gw.base}/mcp`, {
      method: "POST",
      headers: MCP_HEADERS,
      body: JSON.stringify({ ...initialize, pad: "x".repeat(70_000) }),
    });
    assert.equal(big.status, 413);
  });

  describe("DNS-rebinding guard", () => {
    it("rejects a Host that is not one of ours", async () => {
      for (const path of ["/health", "/mcp", "/tools"]) {
        const r = await rawRequest(gw.base, { path, headers: { host: "evil.example" } });
        assert.equal(r.status, 403, path);
      }
    });

    it("rejects a foreign Origin on /mcp and /tools but accepts our own", async () => {
      const evil = await rawRequest(gw.base, {
        method: "POST",
        path: "/mcp",
        headers: { ...MCP_HEADERS, origin: "https://evil.example" },
        body: JSON.stringify(initialize),
      });
      assert.equal(evil.status, 403);
      const opaque = await rawRequest(gw.base, { path: "/tools", headers: { origin: "null" } });
      assert.equal(opaque.status, 403);
      const own = await rawRequest(gw.base, {
        method: "POST",
        path: "/mcp",
        headers: { ...MCP_HEADERS, origin: gw.base },
        body: JSON.stringify(initialize),
      });
      assert.equal(own.status, 200);
    });
  });

  describe("plain JSON gateway (unchanged contract)", () => {
    it("GET /health exposes the daemon address only when nothing gates it", async () => {
      const body = await (await fetch(`${gw.base}/health`)).json();
      assert.deepEqual(body, { ok: true, api_base: mock.base, tools: TOOLS.length });
    });

    it("lists tools and invokes one", async () => {
      const list = await (await fetch(`${gw.base}/tools`)).json();
      assert.deepEqual(
        list.tools.map((t) => t.name),
        TOOLS.map((t) => t.name),
      );
      assert.deepEqual(Object.keys(list.tools[0]).sort(), ["description", "method", "name", "path"]);
      const call = await fetch(`${gw.base}/tools/get_system`, { method: "POST" });
      assert.equal(call.status, 200);
      const out = await call.json();
      assert.deepEqual(Object.keys(out).sort(), ["data", "method", "name", "path"]);
      assert.equal(out.data.path, "/api/v1/system");
    });

    it("parses a JSON body whatever its content type (curl -d default)", async () => {
      const r = await fetch(`${gw.base}/tools/submit_intel`, { method: "POST", body: JSON.stringify({ id: "intel_plain" }) });
      assert.equal(r.status, 200);
      assert.equal((await r.json()).data.body.id, "intel_plain");
    });

    it("answers errors with the documented JSON codes", async () => {
      assert.equal((await fetch(`${gw.base}/tools/place_order`, { method: "POST" })).status, 404);
      assert.equal((await (await fetch(`${gw.base}/tools/place_order`, { method: "POST" })).json()).error, "unknown_tool");
      assert.equal((await (await fetch(`${gw.base}/nope`)).json()).error, "not_found");
      const bad = await fetch(`${gw.base}/tools/submit_intel`, { method: "POST", body: "{nope" });
      assert.equal(bad.status, 400);
      assert.deepEqual(await bad.json(), { error: "bad_json", body: null });
      const big = await fetch(`${gw.base}/tools/submit_intel`, { method: "POST", body: JSON.stringify({ pad: "x".repeat(20_000) }) });
      assert.equal(big.status, 413);
      assert.deepEqual(await big.json(), { error: "body_too_large", body: null });
    });

    // The pre-/mcp gateway looked the tool up first and read a body only for POST-backed tools.
    it("looks the tool up before touching the body, and ignores the body of GET-backed tools", async () => {
      const unknown = await fetch(`${gw.base}/tools/place_order`, { method: "POST", body: "{nope" });
      assert.equal(unknown.status, 404);
      assert.deepEqual(await unknown.json(), { error: "unknown_tool" });
      const get = await fetch(`${gw.base}/tools/get_system`, { method: "POST", body: "{nope" });
      assert.equal(get.status, 200);
      assert.equal((await get.json()).data.path, "/api/v1/system");
      const huge = await fetch(`${gw.base}/tools/get_system`, { method: "POST", body: "x".repeat(20_000) });
      assert.equal(huge.status, 200);
    });

    it("accepts any JSON value as the body, and an empty one as {}", async () => {
      // null is forwarded as {} (callTool's `args || {}`); every other value is forwarded as sent
      for (const [body, forwarded] of [
        ["null", {}],
        ["42", 42],
        ['"text"', "text"],
        ["[1,2]", [1, 2]],
      ]) {
        const r = await fetch(`${gw.base}/tools/submit_intel`, { method: "POST", body });
        assert.equal(r.status, 200, body);
        assert.deepEqual((await r.json()).data.body, forwarded, body);
      }
      const empty = await fetch(`${gw.base}/tools/submit_intel`, { method: "POST" });
      assert.deepEqual((await empty.json()).data.body, {});
    });

    it("only routes plain tool names; anything else is not_found", async () => {
      for (const path of ["/tools/bad-name", "/tools/get_system/extra", "/tools/", "/tools/a.b"]) {
        const r = await fetch(`${gw.base}${path}`, { method: "POST" });
        assert.equal(r.status, 404, path);
        assert.deepEqual(await r.json(), { error: "not_found" }, path);
      }
    });

    it("forwards a daemon error status and body", async () => {
      const failing = await startGateway({ mock, oauth: false, env: { ALPHABOUND_API_TOKEN: "not-the-daemon-token" } });
      try {
        const r = await fetch(`${failing.base}/tools/get_system`, { method: "POST" });
        assert.equal(r.status, 401);
        assert.deepEqual(await r.json(), { error: "API /api/v1/system -> HTTP 401", body: { error: "unauthorized" } });
      } finally {
        await failing.close();
      }
    });
  });
});

describe("static API token gate (ALPHABOUND_MCP_REQUIRE_TOKEN=1)", () => {
  let mock;
  let gw;

  before(async () => {
    mock = await startMockApi();
    gw = await startGateway({ mock, oauth: false, env: { ALPHABOUND_MCP_REQUIRE_TOKEN: "1" } });
  });
  after(async () => {
    await gw.close();
    await mock.close();
  });

  it("keeps /health open, without the daemon address", async () => {
    const r = await fetch(`${gw.base}/health`);
    assert.equal(r.status, 200);
    assert.deepEqual(await r.json(), { ok: true, tools: TOOLS.length });
  });

  it("rejects every other path without the token, including unknown ones", async () => {
    for (const path of ["/tools", "/mcp", "/nope"]) {
      const r = await fetch(`${gw.base}${path}`);
      assert.equal(r.status, 401, path);
      assert.match(r.headers.get("www-authenticate"), /^Bearer/);
    }
    const wrong = await fetch(`${gw.base}/tools`, { headers: { authorization: "Bearer nope" } });
    assert.equal(wrong.status, 401);
  });

  it("accepts the token as Bearer or X-API-Token, on /tools and /mcp", async () => {
    assert.equal((await fetch(`${gw.base}/tools`, { headers: { authorization: `Bearer ${TOKEN}` } })).status, 200);
    assert.equal((await fetch(`${gw.base}/tools`, { headers: { "x-api-token": TOKEN } })).status, 200);
    const client = await connect(gw.base, { headers: { authorization: `Bearer ${TOKEN}` } });
    try {
      assert.equal((await client.listTools()).tools.length, TOOLS.length);
    } finally {
      await client.close();
    }
  });
});
