import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import { dispatch } from "../src/cli.js";
import {
  GITHUB_SPEC,
  NPM_SPEC,
  detectClients,
  inferSource,
  launchSpec,
  mergeConfig,
  runInstall,
  serverBlock,
  wrapConfig,
  writeMerged,
} from "../src/install.js";

describe("dispatch", () => {
  it("defaults to stdio", () => {
    assert.equal(dispatch([]).kind, "stdio");
  });
  it("help", () => {
    assert.equal(dispatch(["--help"]).kind, "help");
    assert.equal(dispatch(["-h"]).kind, "help");
  });
  it("http", () => {
    assert.equal(dispatch(["--http"]).kind, "http");
  });
  it("install npm print", () => {
    const a = dispatch(["install", "--source", "npm", "--print", "--client", "copilot"]);
    assert.equal(a.kind, "install");
    assert.equal(a.options.source, "npm");
    assert.equal(a.options.print, true);
    assert.equal(a.options.client, "copilot");
  });
  it("install infers source when omitted", () => {
    const a = dispatch(["install", "--print"]);
    assert.equal(a.kind, "install");
    assert.equal(a.options.source, undefined);
  });
  it("rejects unknown source", () => {
    const a = dispatch(["install", "--source", "ftp"]);
    assert.equal(a.kind, "error");
  });
  it("rejects unknown args", () => {
    assert.equal(dispatch(["--wat"]).kind, "error");
  });
});

describe("launchSpec", () => {
  it("npx -y alphabound-mcp", () => {
    assert.deepEqual(launchSpec("npm"), { command: "npx", args: ["-y", NPM_SPEC] });
  });
  it("github subdirectory spec", () => {
    assert.deepEqual(launchSpec("github"), { command: "npx", args: ["-y", GITHUB_SPEC] });
  });
  it("local node entry", () => {
    const s = launchSpec("local", { localEntry: "/tmp/index.js" });
    assert.deepEqual(s, { command: "node", args: ["/tmp/index.js"] });
  });
});

describe("inferSource", () => {
  it("npx cache is npm", () => {
    assert.equal(inferSource({ argv1: "/Users/x/.npm/_npx/abc/node_modules/alphabound-mcp/src/index.js" }), "npm");
  });
  it("repo checkout is local", () => {
    assert.equal(inferSource({ argv1: "/repo/tools/alphabound-mcp/src/index.js" }), "local");
  });
});

describe("serverBlock / wrapConfig", () => {
  it("omits token when empty", () => {
    const b = serverBlock({ source: "npm", apiBase: "http://127.0.0.1:18180", token: "" });
    assert.equal(b.env.ALPHABOUND_API_BASE, "http://127.0.0.1:18180");
    assert.equal("ALPHABOUND_API_TOKEN" in b.env, false);
  });
  it("copilot flags", () => {
    const b = serverBlock({ source: "npm", copilot: true, token: "YOUR_TOKEN" });
    assert.equal(b.type, "local");
    assert.deepEqual(b.tools, ["*"]);
    assert.equal(b.env.ALPHABOUND_API_TOKEN, "YOUR_TOKEN");
  });
  it("mcpServers wrapper", () => {
    const doc = wrapConfig("mcpServers", serverBlock({ source: "npm" }));
    assert.ok(doc.mcpServers.alphabound.command);
  });
});

describe("merge / write", () => {
  it("preserves sibling servers", () => {
    const next = mergeConfig(
      { mcpServers: { other: { command: "x" } } },
      "mcpServers",
      serverBlock({ source: "npm" }),
    );
    assert.equal(next.mcpServers.other.command, "x");
    assert.equal(next.mcpServers.alphabound.command, "npx");
  });
  it("writes 0600 json", () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ab-mcp-"));
    const file = path.join(dir, "nested", "mcp.json");
    const r = writeMerged(file, "mcpServers", serverBlock({ source: "npm" }));
    assert.equal(r.wrote, true);
    const doc = JSON.parse(fs.readFileSync(file, "utf8"));
    assert.equal(doc.mcpServers.alphabound.args[1], "alphabound-mcp");
    if (process.platform !== "win32") {
      assert.equal(fs.statSync(file).mode & 0o777, 0o600);
    }
    fs.rmSync(dir, { recursive: true, force: true });
  });
});

describe("runInstall", () => {
  it("print only", async () => {
    const lines = [];
    const code = await runInstall(
      { print: true, source: "npm", client: "copilot", base: "http://127.0.0.1:18180", token: "" },
      { log: (s) => lines.push(s), err: () => {} },
    );
    assert.equal(code, 0);
    const doc = JSON.parse(lines.join("\n"));
    assert.deepEqual(doc.mcpServers.alphabound.args, ["-y", "alphabound-mcp"]);
  });
  it("dry-run copilot into fake home", async () => {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), "ab-home-"));
    const errs = [];
    const code = await runInstall(
      {
        source: "npm",
        client: ["copilot"],
        dryRun: true,
        ctx: { home, platform: "darwin", cwd: home },
      },
      { log: () => {}, err: (s) => errs.push(s) },
    );
    assert.equal(code, 0);
    assert.ok(errs.some((s) => s.startsWith("dry-run copilot:")));
    assert.equal(fs.existsSync(path.join(home, ".copilot", "mcp-config.json")), false);
    fs.rmSync(home, { recursive: true, force: true });
  });
  it("writes copilot user config", async () => {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), "ab-home-"));
    const code = await runInstall(
      {
        source: "github",
        client: ["copilot"],
        token: "",
        ctx: { home, platform: "linux", cwd: home },
      },
      { log: () => {}, err: () => {} },
    );
    assert.equal(code, 0);
    const file = path.join(home, ".copilot", "mcp-config.json");
    const doc = JSON.parse(fs.readFileSync(file, "utf8"));
    assert.equal(doc.mcpServers.alphabound.type, "local");
    assert.equal(doc.mcpServers.alphabound.args[1], GITHUB_SPEC);
    fs.rmSync(home, { recursive: true, force: true });
  });
  it("detects nothing in empty home", () => {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), "ab-empty-"));
    assert.deepEqual(detectClients({ home, platform: "linux", cwd: home }), []);
    fs.rmSync(home, { recursive: true, force: true });
  });
});
