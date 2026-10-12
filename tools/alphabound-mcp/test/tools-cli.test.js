import assert from "node:assert/strict";
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, describe, it } from "node:test";
import { dispatch } from "../src/cli.js";
import { TOOLS } from "../src/client.js";
import { readFileSync } from "node:fs";

const TOKEN = "test-env-token-not-for-production";
const FORBIDDEN = "place_order,flatten,resume,target-weight,secrets";

function startMockApi() {
  const posts = [];
  const paramPosts = [];
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
    if (req.method === "POST" && url.pathname === "/api/v1/review/strategy") {
      res.writeHead(202, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, queued: true }));
      return;
    }
    if (req.method === "POST" && url.pathname.startsWith("/api/v1/params/")) {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      const payload = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
      paramPosts.push({ path: url.pathname, payload });
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, code: "ok", path: url.pathname }));
      return;
    }
    if (req.method === "GET" && url.pathname === "/api/v1/statistics") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(
        JSON.stringify({
          portfolio: {
            last_24h: {
              window_return: null,
              max_drawdown: null,
              bh_return: null,
              alpha_return: null,
              start_ts: null,
              end_ts: null,
            },
            last_7d: {
              window_return: "0.01",
              max_drawdown: "0.03",
              bh_return: "0.02",
              alpha_return: "-0.01",
              start_ts: "2026-10-05T00:00:00.000Z",
              end_ts: "2026-10-12T00:00:00.000Z",
            },
          },
        }),
      );
      return;
    }
    if (req.method === "GET" && url.pathname === "/api/v1/system") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ready: true, mode: "shadow" }));
      return;
    }
    if (req.method === "GET" && url.pathname.startsWith("/api/v1/")) {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ path: url.pathname, search: url.search, ok: true }));
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
        paramPosts,
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

  it("forwards whitelisted query params and keeps cursor colons literal", async () => {
    const env = { ALPHABOUND_API_BASE: mock.base, ALPHABOUND_API_TOKEN: TOKEN };
    const runs = await captureCli(
      ["list_agent_runs", "--query", "status=error&limit=20&before=2026-09-04T00:00:00.000Z"],
      env,
    );
    assert.equal(runs.code, 0, runs.err);
    const body = JSON.parse(runs.out);
    assert.equal(body.path, "/api/v1/agent-runs");
    assert.equal(body.search, "?status=error&limit=20&before=2026-09-04T00:00:00.000Z");

    const eq = await captureCli(["query_equity", "--query", "window=long&from=2026-09-01"], env);
    assert.equal(eq.code, 0, eq.err);
    assert.equal(JSON.parse(eq.out).search, "?window=long&from=2026-09-01");

    const ranged = await captureCli(
      ["query_equity", "--query", "since=2026-10-11T00:00:00.000Z&until=2026-10-12T00:00:00.000Z&step=15"],
      env,
    );
    assert.equal(ranged.code, 0, ranged.err);
    assert.equal(
      JSON.parse(ranged.out).search,
      "?since=2026-10-11T00:00:00.000Z&until=2026-10-12T00:00:00.000Z&step=15",
    );

    const none = await captureCli(["list_agent_runs"], env);
    assert.equal(JSON.parse(none.out).search, "");
  });

  it("rejects unknown query params instead of forwarding them", async () => {
    const env = { ALPHABOUND_API_BASE: mock.base, ALPHABOUND_API_TOKEN: TOKEN };
    const bad = await captureCli(["list_agent_runs", "--query", "status=error&sql=1"], env);
    assert.equal(bad.code, 1);
    assert.match(JSON.parse(bad.err).error, /unknown parameter "sql"/);
    const noParams = await captureCli(["get_system", "--query", "x=1"], env);
    assert.equal(noParams.code, 1);
    assert.match(JSON.parse(noParams.err).error, /takes no parameters/);
  });

  it("advertises query params as MCP input schemas", () => {
    for (const name of ["list_events", "list_agent_runs", "query_equity"]) {
      const t = TOOLS.find((x) => x.name === name);
      assert.ok(t.query && Object.keys(t.query).length > 0, name);
    }
    assert.ok("error_class" in TOOLS.find((x) => x.name === "list_agent_runs").query);
    const equity = TOOLS.find((x) => x.name === "query_equity").query;
    assert.ok("window" in equity);
    assert.ok("since" in equity && "until" in equity && "step" in equity);
  });

  it("keeps the MCP package version and the stdio server version in sync", () => {
    const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
    const lock = JSON.parse(readFileSync(new URL("../package-lock.json", import.meta.url), "utf8"));
    const stdio = readFileSync(new URL("../src/stdio.js", import.meta.url), "utf8");
    assert.equal(pkg.version, "0.2.0");
    assert.equal(lock.version, pkg.version);
    assert.equal(lock.packages[""].version, pkg.version);
    assert.match(stdio, new RegExp(`version: "${pkg.version}"`));
  });

  it("lists statistics plus the parameter, backtest, and review tools", () => {
    const required = [
      "get_params",
      "list_param_versions",
      "propose_params",
      "apply_params",
      "rollback_params",
      "run_backtest",
      "get_backtest",
      "run_strategy_review",
      "list_reviews",
      "get_review",
      "get_statistics",
      "query_equity",
    ];
    for (const name of required) {
      assert.ok(TOOLS.some((t) => t.name === name), name);
    }
    const stats = TOOLS.find((t) => t.name === "get_statistics");
    assert.equal(stats.method, "GET");
    assert.equal(stats.path, "/api/v1/statistics");
    assert.equal(stats.query, undefined);
    assert.match(stats.description, /last_24h/);
    assert.match(stats.description, /max_drawdown/);
    assert.match(stats.description, /buy-and-hold/i);
    assert.match(stats.description, /null/);
    assert.match(stats.description, /does not place orders/i);
    assert.match(stats.description, /No secrets/);
    assert.equal(/place_order|flatten|resume/.test(stats.path), false);
    assert.equal(FORBIDDEN.split(",").some((name) => TOOLS.some((t) => t.name === name)), false);
  });

  it("passes statistics nulls through and does not invent a zero return", async () => {
    const env = { ALPHABOUND_API_BASE: mock.base, ALPHABOUND_API_TOKEN: TOKEN };
    const r = await captureCli(["get_statistics"], env);
    assert.equal(r.code, 0, r.err);
    const body = JSON.parse(r.out);
    assert.equal(body.portfolio.last_24h.window_return, null);
    assert.equal(body.portfolio.last_24h.max_drawdown, null);
    assert.equal(body.portfolio.last_24h.bh_return, null);
    assert.equal(body.portfolio.last_24h.alpha_return, null);
    assert.equal(body.portfolio.last_7d.window_return, "0.01");
    assert.equal(body.portfolio.last_7d.bh_return, "0.02");
    assert.equal(body.portfolio.last_7d.alpha_return, "-0.01");
    assert.equal(body.portfolio.last_7d.start_ts, "2026-10-05T00:00:00.000Z");
    assert.equal(body.portfolio.last_7d.end_ts, "2026-10-12T00:00:00.000Z");
  });

  it("advertises the backtest gate without an order path", () => {
    const run = TOOLS.find((x) => x.name === "run_backtest");
    const get = TOOLS.find((x) => x.name === "get_backtest");
    assert.equal(run.method, "POST");
    assert.equal(run.path, "/api/v1/params/backtest");
    assert.equal(run.forceSource, "mcp");
    assert.match(run.description, /recorded decisions/i);
    assert.match(run.description, /does not place orders/i);
    assert.match(run.description, /max_drawdown/);
    assert.equal(/place_order|flatten|resume/.test(run.path), false);
    assert.equal(get.method, "GET");
    assert.equal(get.path, "/api/v1/params/backtest");
    assert.ok(get.query && "id" in get.query);
    const apply = TOOLS.find((x) => x.name === "apply_params");
    assert.match(apply.description, /24h old/);
    assert.match(apply.inputSchema.properties.backtest_summary.description, /run_backtest/);
  });

  it("advertises the strategy review without an order path", async () => {
    const list = TOOLS.find((x) => x.name === "list_reviews");
    const get = TOOLS.find((x) => x.name === "get_review");
    const run = TOOLS.find((x) => x.name === "run_strategy_review");
    assert.equal(list.method, "GET");
    assert.equal(list.path, "/api/v1/review/strategy");
    assert.equal(get.method, "GET");
    assert.equal(get.path, "/api/v1/review/strategy");
    assert.ok(get.query && "id" in get.query);
    assert.equal(run.method, "POST");
    assert.equal(run.path, "/api/v1/review/strategy");
    assert.equal(run.forceSource, undefined);
    for (const t of [list, get, run]) {
      assert.match(t.description, /does not place orders/i);
      assert.match(t.description, /max_drawdown/);
      assert.equal(/place_order|flatten|resume/.test(t.path), false);
    }
    const env = { ALPHABOUND_API_BASE: mock.base, ALPHABOUND_API_TOKEN: TOKEN };
    const queued = await captureCli(["run_strategy_review"], env);
    assert.equal(queued.code, 0, queued.err);
    assert.equal(JSON.parse(queued.out).queued, true);
    const one = await captureCli(["get_review", "--query", "id=sr_1_1"], env);
    assert.equal(one.code, 0, one.err);
    assert.equal(JSON.parse(one.out).search, "?id=sr_1_1");
  });

  it("advertises parameter writes with the hard bounds and no order path", () => {
    for (const name of ["propose_params", "apply_params", "rollback_params"]) {
      const t = TOOLS.find((x) => x.name === name);
      assert.ok(t, name);
      assert.equal(t.method, "POST");
      assert.equal(t.forceSource, "mcp");
      assert.match(t.description, /20%/);
      assert.match(t.description, /24h/);
      assert.match(t.description, /max_drawdown/);
      assert.match(t.description, /0\.10/);
      assert.match(t.description, /does not place orders/i);
      assert.equal(/place_order|flatten|resume/.test(t.path), false);
    }
  });

  it("forces source=mcp and forwards parameter write bodies", async () => {
    const env = { ALPHABOUND_API_BASE: mock.base, ALPHABOUND_API_TOKEN: TOKEN };
    const proposed = await captureCli(
      [
        "propose_params",
        "--json",
        JSON.stringify({
          source: "manual",
          operator: "ops",
          reason: "tighten",
          params: { daily_trade_cap: 7 },
        }),
      ],
      env,
    );
    assert.equal(proposed.code, 0, proposed.err);
    const propose = mock.paramPosts.at(-1);
    assert.equal(propose.path, "/api/v1/params/propose");
    assert.equal(propose.payload.source, "mcp");
    assert.equal(propose.payload.operator, "ops");
    assert.equal(propose.payload.params.daily_trade_cap, 7);

    const applied = await captureCli(
      [
        "apply_params",
        "--json",
        JSON.stringify({
          source: "review",
          operator: "ops",
          reason: "apply",
          version_id: 2,
          expected_active_version: 1,
          backtest_summary: "{\"schema\":\"alphabound.backtest_ref.v1\",\"id\":\"bt_ok\",\"passed\":true}",
        }),
      ],
      env,
    );
    assert.equal(applied.code, 0, applied.err);
    const apply = mock.paramPosts.at(-1);
    assert.equal(apply.path, "/api/v1/params/apply");
    assert.equal(apply.payload.source, "mcp");
    assert.equal(apply.payload.version_id, 2);

    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ab-params-"));
    const file = path.join(dir, "rollback.json");
    fs.writeFileSync(
      file,
      JSON.stringify({ source: "manual", operator: "ops", reason: "undo", version_id: 1, expected_active_version: 2 }),
    );
    const ran = await captureCli(
      [
        "run_backtest",
        "--json",
        JSON.stringify({
          source: "manual",
          operator: "ops",
          reason: "gate",
          params: { daily_trade_cap: 7 },
        }),
      ],
      env,
    );
    assert.equal(ran.code, 0, ran.err);
    const backtest = mock.paramPosts.at(-1);
    assert.equal(backtest.path, "/api/v1/params/backtest");
    assert.equal(backtest.payload.source, "mcp");
    assert.equal(backtest.payload.params.daily_trade_cap, 7);

    const fetched = await captureCli(["get_backtest", "--query", "id=bt_example"], env);
    assert.equal(fetched.code, 0, fetched.err);
    assert.equal(JSON.parse(fetched.out).search, "?id=bt_example");

    const rolled = await captureCli(["rollback_params", "--file", file], env);
    fs.rmSync(dir, { recursive: true, force: true });
    assert.equal(rolled.code, 0, rolled.err);
    const rollback = mock.paramPosts.at(-1);
    assert.equal(rollback.path, "/api/v1/params/rollback");
    assert.equal(rollback.payload.source, "mcp");
    assert.equal(rollback.payload.version_id, 1);
  });

  it("refuses parameter writes without the admin token", async () => {
    const r = await captureCli(["propose_params", "--json", "{\"operator\":\"ops\",\"reason\":\"x\",\"params\":{}}"], {
      ALPHABOUND_API_BASE: mock.base,
      ALPHABOUND_API_TOKEN: null,
      DASHBOARD_API_TOKEN: null,
    });
    assert.equal(r.code, 1);
    assert.match(r.err, /401|unauthorized/i);
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
