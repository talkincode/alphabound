import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const NPM_SPEC = "alphabound-mcp";
export const GITHUB_SPEC = "github:talkincode/alphabound#path:tools/alphabound-mcp";
export const RELEASE_TGZ =
  "https://github.com/talkincode/alphabound/releases/latest/download/alphabound-mcp.tgz";

const LOCAL_ENTRY = fileURLToPath(new URL("./index.js", import.meta.url));

export function defaultApiBase() {
  return process.env.ALPHABOUND_API_BASE || "http://127.0.0.1:18180";
}

export function defaultToken() {
  return process.env.ALPHABOUND_API_TOKEN || process.env.DASHBOARD_API_TOKEN || "";
}

export function localEntryPath() {
  return LOCAL_ENTRY;
}

/** How the MCP client should spawn this server. */
export function launchSpec(source, { localEntry = LOCAL_ENTRY } = {}) {
  switch (source) {
    case "github":
      return { command: "npx", args: ["-y", GITHUB_SPEC] };
    case "release":
      return { command: "npx", args: ["-y", RELEASE_TGZ] };
    case "local":
      return { command: "node", args: [localEntry] };
    case "npm":
      return { command: "npx", args: ["-y", NPM_SPEC] };
    default:
      throw new Error(`unknown source: ${source}`);
  }
}

export function inferSource({ argv1 = process.argv[1] || "" } = {}) {
  const p = argv1.replace(/\\/g, "/");
  if (p.includes("node_modules/") || p.includes("/_npx/") || p.includes("/.npm/")) {
    return "npm";
  }
  if (p.includes("/tools/alphabound-mcp/")) return "local";
  return "npm";
}

export function serverBlock({
  source = "npm",
  apiBase = defaultApiBase(),
  token = "",
  copilot = false,
  vscode = false,
  localEntry = LOCAL_ENTRY,
} = {}) {
  const { command, args } = launchSpec(source, { localEntry });
  const env = { ALPHABOUND_API_BASE: apiBase };
  if (token) env.ALPHABOUND_API_TOKEN = token;
  const block = { command, args, env };
  if (copilot) {
    block.type = "local";
    block.tools = ["*"];
  } else if (vscode) {
    block.type = "stdio";
  }
  return block;
}

export function wrapConfig(format, block) {
  if (format === "servers") {
    return { servers: { alphabound: block } };
  }
  return { mcpServers: { alphabound: block } };
}

function ctxFromEnv(overrides = {}) {
  return {
    home: overrides.home || process.env.HOME || os.homedir(),
    appData: overrides.appData || process.env.APPDATA || "",
    platform: overrides.platform || process.platform,
    cwd: overrides.cwd || process.cwd(),
  };
}

export const CLIENTS = {
  claude: {
    id: "claude",
    format: "mcpServers",
    userPath(ctx) {
      if (ctx.platform === "darwin") {
        return path.join(ctx.home, "Library", "Application Support", "Claude", "claude_desktop_config.json");
      }
      if (ctx.platform === "win32") {
        return path.join(ctx.appData || path.join(ctx.home, "AppData", "Roaming"), "Claude", "claude_desktop_config.json");
      }
      return path.join(ctx.home, ".config", "Claude", "claude_desktop_config.json");
    },
  },
  "claude-code": {
    id: "claude-code",
    format: "mcpServers",
    userPath(ctx) {
      return path.join(ctx.home, ".claude.json");
    },
    projectPath: ".mcp.json",
  },
  cursor: {
    id: "cursor",
    format: "mcpServers",
    userPath(ctx) {
      return path.join(ctx.home, ".cursor", "mcp.json");
    },
    projectPath: path.join(".cursor", "mcp.json"),
  },
  vscode: {
    id: "vscode",
    format: "servers",
    userPath(ctx) {
      if (ctx.platform === "darwin") {
        return path.join(ctx.home, "Library", "Application Support", "Code", "User", "mcp.json");
      }
      if (ctx.platform === "win32") {
        return path.join(ctx.appData || path.join(ctx.home, "AppData", "Roaming"), "Code", "User", "mcp.json");
      }
      return path.join(ctx.home, ".config", "Code", "User", "mcp.json");
    },
    projectPath: path.join(".vscode", "mcp.json"),
  },
  copilot: {
    id: "copilot",
    format: "mcpServers",
    copilot: true,
    userPath(ctx) {
      return path.join(ctx.home, ".copilot", "mcp-config.json");
    },
    projectPath: path.join(".copilot", "mcp-config.json"),
  },
  windsurf: {
    id: "windsurf",
    format: "mcpServers",
    userPath(ctx) {
      return path.join(ctx.home, ".codeium", "windsurf", "mcp_config.json");
    },
  },
};

export const CLIENT_IDS = Object.keys(CLIENTS);

export function parseClientList(raw) {
  if (!raw || raw === "all" || raw === "detected") return raw || "detected";
  const ids = raw.split(",").map((s) => s.trim()).filter(Boolean);
  for (const id of ids) {
    if (!CLIENTS[id]) throw new Error(`unknown client: ${id} (want ${CLIENT_IDS.join("|")}|all)`);
  }
  return ids;
}

function looksPresent(filePath) {
  try {
    return fs.existsSync(filePath);
  } catch {
    return false;
  }
}

export function detectClients(ctx = ctxFromEnv()) {
  const found = [];
  const hints = [
    ["claude", CLIENTS.claude.userPath(ctx)],
    ["claude-code", path.join(ctx.home, ".claude.json")],
    ["cursor", path.join(ctx.home, ".cursor")],
    ["vscode", CLIENTS.vscode.userPath(ctx)],
    ["copilot", path.join(ctx.home, ".copilot")],
    ["windsurf", path.join(ctx.home, ".codeium", "windsurf")],
  ];
  if (ctx.platform === "darwin") {
    hints.push(["claude", "/Applications/Claude.app"]);
    hints.push(["vscode", "/Applications/Visual Studio Code.app"]);
  }
  for (const [id, p] of hints) {
    if (looksPresent(p) && !found.includes(id)) found.push(id);
  }
  return found;
}

export function resolveTargets(clientOpt, { project = false, ctx = ctxFromEnv() } = {}) {
  let ids;
  if (clientOpt === "detected") {
    ids = detectClients(ctx);
  } else if (clientOpt === "all") {
    ids = CLIENT_IDS.slice();
  } else if (Array.isArray(clientOpt)) {
    ids = clientOpt;
  } else {
    ids = parseClientList(clientOpt);
    if (!Array.isArray(ids)) {
      ids = detectClients(ctx);
    }
  }
  return ids.map((id) => {
    const spec = CLIENTS[id];
    const rel = project ? spec.projectPath : null;
    const abs = rel ? path.resolve(ctx.cwd, rel) : spec.userPath(ctx);
    if (!abs) {
      throw new Error(`${id} has no ${project ? "project" : "user"} config path`);
    }
    return { id, format: spec.format, copilot: !!spec.copilot, path: abs };
  });
}

export function mergeConfig(existing, format, block) {
  const doc = existing && typeof existing === "object" ? { ...existing } : {};
  const root = format === "servers" ? "servers" : "mcpServers";
  const prev = doc[root] && typeof doc[root] === "object" ? { ...doc[root] } : {};
  prev.alphabound = block;
  doc[root] = prev;
  return doc;
}

function readJsonIfExists(filePath) {
  if (!fs.existsSync(filePath)) return {};
  const text = fs.readFileSync(filePath, "utf8").trim();
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`invalid JSON: ${filePath}`);
  }
}

export function writeMerged(filePath, format, block, { dryRun = false, force = true } = {}) {
  const existing = readJsonIfExists(filePath);
  const root = format === "servers" ? "servers" : "mcpServers";
  const had = existing[root] && existing[root].alphabound;
  if (had && !force) {
    return { path: filePath, skipped: true, reason: "exists" };
  }
  const next = mergeConfig(existing, format, block);
  const text = `${JSON.stringify(next, null, 2)}\n`;
  if (!dryRun) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, text, { encoding: "utf8", mode: 0o600 });
  }
  return { path: filePath, skipped: false, dryRun, wrote: !dryRun };
}

export async function runInstall(opts, io = {}) {
  const log = io.log || ((s) => console.log(s));
  const err = io.err || ((s) => console.error(s));
  const ctx = ctxFromEnv(opts.ctx || {});
  const source = opts.source || inferSource();
  const apiBase = opts.base || defaultApiBase();
  const token = opts.token !== undefined ? opts.token : defaultToken();
  const project = !!opts.project;
  const clientOpt = opts.client || "detected";

  let targets;
  try {
    targets = resolveTargets(clientOpt, { project, ctx });
  } catch (e) {
    err(e.message);
    return 1;
  }

  if (project) {
    targets = targets.filter((t) => CLIENTS[t.id].projectPath);
  }

  const printBlock = ({ copilot = false, vscode = false } = {}) =>
    serverBlock({
      source,
      apiBase,
      token: project ? "" : token,
      copilot,
      vscode,
      localEntry: opts.localEntry,
    });

  if (opts.print || targets.length === 0) {
    const generic = wrapConfig("mcpServers", printBlock());
    log(JSON.stringify(generic, null, 2));
    if (targets.length === 0 && !opts.print) {
      err("No MCP client config found. Paste the snippet above, or pass --client copilot|cursor|claude|vscode|all.");
    }
    if (opts.print || targets.length === 0) return 0;
  }

  const results = [];
  for (const t of targets) {
    try {
      const block = printBlock({ copilot: t.copilot, vscode: t.format === "servers" });
      const result = writeMerged(t.path, t.format, block, {
        dryRun: !!opts.dryRun,
        force: opts.force !== false,
      });
      results.push({ ...result, id: t.id });
      const mark = result.skipped ? "skip" : opts.dryRun ? "dry-run" : "wrote";
      err(`${mark} ${t.id}: ${t.path}`);
    } catch (e) {
      err(`fail ${t.id}: ${e.message}`);
      return 1;
    }
  }

  if (token && !project && !opts.dryRun) {
    err("Token written into the client config. Do not commit that file.");
  } else if (!token) {
    err("No ALPHABOUND_API_TOKEN in env; set it on the daemon and in the MCP client env if auth is enabled.");
  }
  const launch = launchSpec(source, { localEntry: opts.localEntry });
  err(`MCP launch: ${launch.command} ${launch.args.join(" ")}`);
  return 0;
}
