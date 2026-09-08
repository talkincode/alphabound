import assert from "node:assert/strict";
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, describe, it } from "node:test";
import { dispatch } from "../src/cli.js";
import { TOOLS } from "../src/client.js";

const TOKEN = "test-env-token-not-for-production";
const FORBIDDEN = "place_order,flatten,resume,target-weight,secrets";

function startMockApi() {
  const posts = [];
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url || "/", "http://127.0.0.1");
    const auth = req.headers.authorization || "";
    const x = req.headers["x-api-token"] || "";
    const presented = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : String(x);
    if (presented !== TOKEN) {
      res.writeHead(401, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "unauthorized" }));
      return;
    }
    if (req.method === "POST" && url.pathname === "/api/v1/intel") {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      const payload = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
      posts.push(payload);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, id: payload.id || "intel_1" }));
      return;
    }
    if (req.method === "GET" && url.pathname === "/api/v1/system") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ready: true, mode: "shadow" }));
      return;
    }
    if (req.method === "GET" && url.pathname.startsWith("/api/v1/")) {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ path: url.pathname, ok: true }));
      return;
    }
    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "not_found" }));
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      resolve({
        server,
        posts,
        base: `http://127.0.0.1:${port}`,
      });
    });
  });
}

async function captureCli(argv, extraEnv = {}) {
  const { runCli } = await import("../src/cli.js");
  const out = [];
  const err = [];
  const prevBase = process.env.ALPHABOUND_API_BASE;
  const prevToken = process.env.ALPHABOUND_API_TOKEN;
  const prevDash = process.env.DASHBOARD_API_TOKEN;
  try {
    if ("ALPHABOUND_API_BASE" in extraEnv) {
      if (extraEnv.ALPHABOUND_API_BASE == null) delete process.env.ALPHABOUND_API_BASE;
      else process.env.ALPHABOUND_API_BASE = extraEnv.ALPHABOUND_API_BASE;
    }
    if ("ALPHABOUND_API_TOKEN" in extraEnv) {
      if (extraEnv.ALPHABOUND_API_TOKEN == null) delete process.env.ALPHABOUND_API_TOKEN;
      else process.env.ALPHABOUND_API_TOKEN = extraEnv.ALPHABOUND_API_TOKEN;
    }
    if ("DASHBOARD_API_TOKEN" in extraEnv) {
      if (extraEnv.DASHBOARD_API_TOKEN == null) delete process.env.DASHBOARD_API_TOKEN;
      else process.env.DASHBOARD_API_TOKEN = extraEnv.DASHBOARD_API_TOKEN;
    }
    const code = await runCli(argv, {
      log: (s) => out.push(String(s)),
      err: (s) => err.push(String(s)),
    });
    return { code, out: out.join("\n"), err: err.join("\n") };
  } finally {
    if (prevBase == null) delete process.env.ALPHABOUND_API_BASE;
    else process.env.ALPHABOUND_API_BASE = prevBase;
    if (prevToken == null) delete process.env.ALPHABOUND_API_TOKEN;
    else process.env.ALPHABOUND_API_TOKEN = prevToken;
    if (prevDash == null) delete process.env.DASHBOARD_API_TOKEN;
    else process.env.DASHBOARD_API_TOKEN = prevDash;
  }
}

describe("dispatch tool CLI", () => {
  it("lists tools", () => {
    assert.equal(dispatch(["tools"]).kind, "tools");
    assert.equal(dispatch(["list-tools"]).kind, "tools");
  });

  it("calls via shorthand and call subcommand", () => {
    const a = dispatch(["get_system"]);
    assert.equal(a.kind, "call");
    assert.equal(a.name, "get_system");
    const b = dispatch(["call", "get_state"]);
    assert.equal(b.kind, "call");
    assert.equal(b.name, "get_state");
  });

  it("accepts every MCP tool name as a subcommand", () => {
    for (const t of TOOLS) {
      const a = dispatch([t.name]);
      assert.equal(a.kind, "call", t.name);
      assert.equal(a.name, t.name);
    }
  });

  it("parses submit_intel --json and --file", () => {
    const a = dispatch(["submit_intel", "--json", "{\"schema\":\"alphabound.intel.v1\"}"]);
    assert.equal(a.kind, "call");
    assert.equal(a.name, "submit_intel");
    assert.equal(a.json, "{\"schema\":\"alphabound.intel.v1\"}");
    const b = dispatch(["call", "submit_intel", "--file", "/tmp/env.json"]);
    assert.equal(b.kind, "call");
    assert.equal(b.file, "/tmp/env.json");
  });

  it("keeps stdio default and rejects trading control names", () => {
    assert.equal(dispatch([]).kind, "stdio");
    assert.equal(dispatch(["place_order"]).kind, "error");
    assert.equal(dispatch(["flatten"]).kind, "error");
  });
});

describe("CLI HTTP + env token", () => {
  let mock;

  before(async () => {
    mock = await startMockApi();
  });

  after(() => {
    mock.server.close();
  });

  it("reads ALPHABOUND_API_TOKEN at call time (happy path)", async () => {
    const r = await captureCli(["get_system"], {
      ALPHABOUND_API_BASE: mock.base,
      ALPHABOUND_API_TOKEN: TOKEN,
    });
    assert.equal(r.code, 0);
    const body = JSON.parse(r.out);
    assert.equal(body.ready, true);
    assert.equal(body.mode, "shadow");
    assert.equal(r.out.includes(TOKEN), false);
    assert.equal(r.err.includes(TOKEN), false);
  });

  it("fails closed without token when API requires auth", async () => {
    const r = await captureCli(["get_system"], {
      ALPHABOUND_API_BASE: mock.base,
      ALPHABOUND_API_TOKEN: null,
      DASHBOARD_API_TOKEN: null,
    });
    assert.equal(r.code, 1);
    assert.match(r.err, /401|unauthorized/i);
    assert.equal(r.err.includes(TOKEN), false);
  });

  it("accepts DASHBOARD_API_TOKEN fallback", async () => {
    const r = await captureCli(["call", "get_system"], {
      ALPHABOUND_API_BASE: mock.base,
      ALPHABOUND_API_TOKEN: null,
      DASHBOARD_API_TOKEN: TOKEN,
    });
    assert.equal(r.code, 0);
    assert.equal(JSON.parse(r.out).ready, true);
  });

  it("lists the full MCP catalog without calling the API", async () => {
    const r = await captureCli(["tools"]);
    assert.equal(r.code, 0);
    const doc = JSON.parse(r.out);
    const names = doc.tools.map((t) => t.name);
    assert.deepEqual(names, TOOLS.map((t) => t.name));
    assert.equal(names.some((n) => FORBIDDEN.split(",").includes(n)), false);
  });

  it("POSTs submit_intel JSON from --file", async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ab-cli-"));
    const file = path.join(dir, "intel.json");
    const envelope = {
      schema: "alphabound.intel.v1",
      id: "intel_cli_test",
      source_id: "collector.macro",
      kind: "macro",
      instrument: "*",
      headline: "synthetic headline ok",
      body: "untrusted body",
      claims: [{ text: "neutral", polarity: "neutral" }],
      confidence: 0.5,
      as_of_ms: 1,
      nonce: "0123456789abcdef",
      signature: "ab",
    };
    fs.writeFileSync(file, JSON.stringify(envelope));
    const r = await captureCli(["submit_intel", "--file", file], {
      ALPHABOUND_API_BASE: mock.base,
      ALPHABOUND_API_TOKEN: TOKEN,
    });
    fs.rmSync(dir, { recursive: true, force: true });
    assert.equal(r.code, 0, r.err);
    assert.equal(JSON.parse(r.out).ok, true);
    assert.equal(mock.posts.at(-1).id, "intel_cli_test");
  });

  it("invokes every GET MCP tool against the mock API", async () => {
    const gets = TOOLS.filter((t) => t.method !== "POST");
    for (const t of gets) {
      const r = await captureCli([t.name], {
        ALPHABOUND_API_BASE: mock.base,
        ALPHABOUND_API_TOKEN: TOKEN,
      });
      assert.equal(r.code, 0, t.name + " " + r.err);
      JSON.parse(r.out);
    }
  });
});
