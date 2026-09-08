import fs from "node:fs";
import { callTool, findTool, listToolsPublic } from "./client.js";

export const HELP = `alphabound-mcp — AlphaBound analytics MCP (read-only + signed intel ingest)

Usage:
  alphabound-mcp                 Start stdio MCP (IDE / Copilot default)
  alphabound-mcp --http          Start loopback HTTP gateway
  alphabound-mcp install [opts]  Write MCP client config (npx -y auto-install)
  alphabound-mcp tools           List MCP tools (JSON)
  alphabound-mcp call <tool>     Invoke a tool; JSON on stdout
  alphabound-mcp <tool>          Shorthand for call
  alphabound-mcp --help

Auth (environment variables; preferred over flags):
  ALPHABOUND_API_BASE     Dashboard origin (default http://127.0.0.1:18180)
  ALPHABOUND_API_TOKEN    Same token as the daemon (or DASHBOARD_API_TOKEN)

Call options:
  --base <url>    Override ALPHABOUND_API_BASE
  --token <str>   Override token (prefer env; do not commit / log)
  --json <body>   POST JSON body (submit_intel)
  --file <path>   POST JSON body from file
  --meta          Include name/path/method/base envelope

Install options:
  --client <id>   claude|claude-code|cursor|vscode|copilot|windsurf|all|detected (default: detected)
  --source <id>   npm | github | release | local  (default: inferred)
  --base <url>    ALPHABOUND_API_BASE (default: env or http://127.0.0.1:18180)
  --token <str>   ALPHABOUND_API_TOKEN (prefer env; do not commit)
  --project       Write project-local config in cwd (no token)
  --print         Print JSON snippet only
  --dry-run       Show target paths without writing
  --force         Overwrite an existing alphabound entry (default)

IDE snippet (npx auto-installs on first run):

  {
    "mcpServers": {
      "alphabound": {
        "command": "npx",
        "args": ["-y", "alphabound-mcp"],
        "env": {
          "ALPHABOUND_API_BASE": "http://127.0.0.1:18180",
          "ALPHABOUND_API_TOKEN": "YOUR_TOKEN"
        }
      }
    }
  }
`;

function takeFlag(args, name) {
  const i = args.indexOf(name);
  if (i === -1) return undefined;
  const v = args[i + 1];
  if (!v || v.startsWith("-")) throw new Error(`${name} requires a value`);
  args.splice(i, 2);
  return v;
}

function hasFlag(args, name) {
  const i = args.indexOf(name);
  if (i === -1) return false;
  args.splice(i, 1);
  return true;
}

export function dispatch(argv) {
  const args = [...argv];
  if (args.includes("-h") || args.includes("--help") || args[0] === "help") {
    return { kind: "help" };
  }
  const install = args[0] === "install" || args.includes("--install");
  if (args[0] === "install") args.shift();
  if (args.includes("--install")) args.splice(args.indexOf("--install"), 1);

  if (install) {
    try {
      const client = takeFlag(args, "--client");
      const source = takeFlag(args, "--source");
      const base = takeFlag(args, "--base");
      const token = takeFlag(args, "--token");
      const project = hasFlag(args, "--project");
      const print = hasFlag(args, "--print");
      const dryRun = hasFlag(args, "--dry-run");
      const noForce = hasFlag(args, "--no-force");
      hasFlag(args, "--force");
      const force = !noForce;
      if (args.length) {
        return { kind: "error", error: `unknown install args: ${args.join(" ")}` };
      }
      if (source && !["npm", "github", "release", "local"].includes(source)) {
        return { kind: "error", error: `unknown --source ${source}` };
      }
      return {
        kind: "install",
        options: { client: client || "detected", source, base, token, project, print, dryRun, force },
      };
    } catch (e) {
      return { kind: "error", error: e.message };
    }
  }

  if (args.includes("--http")) {
    return { kind: "http" };
  }

  try {
    const base = takeFlag(args, "--base");
    const token = takeFlag(args, "--token");
    const json = takeFlag(args, "--json");
    const file = takeFlag(args, "--file");
    const meta = hasFlag(args, "--meta");

    if (args[0] === "tools" || args[0] === "list-tools") {
      args.shift();
      if (args.length) {
        return { kind: "error", error: `unknown tools args: ${args.join(" ")}` };
      }
      return { kind: "tools" };
    }

    let name;
    if (args[0] === "call") {
      args.shift();
      name = args.shift();
      if (!name) {
        return { kind: "error", error: "call requires a tool name" };
      }
    } else if (args[0] && findTool(args[0])) {
      name = args.shift();
    }

    if (name) {
      if (!findTool(name)) {
        return { kind: "error", error: `unknown tool: ${name}` };
      }
      if (args.length) {
        return { kind: "error", error: `unknown args: ${args.join(" ")}` };
      }
      return { kind: "call", name, base, token, json, file, meta };
    }

    if (base || token || json || file || meta) {
      return { kind: "error", error: "tool flags require a tool name (see --help)" };
    }
    if (args.length) {
      return { kind: "error", error: `unknown args: ${args.join(" ")}\n${HELP}` };
    }
    return { kind: "stdio" };
  } catch (e) {
    return { kind: "error", error: e.message };
  }
}

function loadPayload(action) {
  const tool = findTool(action.name);
  if (!tool) throw new Error(`unknown tool: ${action.name}`);
  if (tool.method !== "POST") return {};
  if (action.json && action.file) {
    throw new Error("use either --json or --file, not both");
  }
  if (action.json) {
    try {
      return JSON.parse(action.json);
    } catch {
      throw new Error("--json is not valid JSON");
    }
  }
  if (action.file) {
    const raw = fs.readFileSync(action.file, "utf8");
    try {
      return JSON.parse(raw);
    } catch {
      throw new Error(`--file ${action.file} is not valid JSON`);
    }
  }
  throw new Error(`${action.name} requires --json <body> or --file <path>`);
}

async function runCall(action, { log, err }) {
  try {
    const payload = loadPayload(action);
    const overrides = {};
    if (action.base !== undefined) overrides.base = action.base;
    if (action.token !== undefined) overrides.token = action.token;
    const result = await callTool(action.name, payload, overrides);
    log(JSON.stringify(action.meta ? result : result.data, null, 2));
    return 0;
  } catch (e) {
    err(
      JSON.stringify({
        error: e.message,
        status: e.status || null,
        body: e.body || null,
      }),
    );
    return 1;
  }
}

export async function runCli(argv, io = {}) {
  const action = dispatch(argv);
  const err = io.err || ((s) => console.error(s));
  const log = io.log || ((s) => console.log(s));
  if (action.kind === "help") {
    err(HELP);
    return 0;
  }
  if (action.kind === "error") {
    err(action.error);
    return 1;
  }
  if (action.kind === "install") {
    const { runInstall } = await import("./install.js");
    return runInstall(action.options, { log, err });
  }
  if (action.kind === "http") {
    await import("./http.js");
    return undefined;
  }
  if (action.kind === "tools") {
    log(JSON.stringify({ tools: listToolsPublic() }, null, 2));
    return 0;
  }
  if (action.kind === "call") {
    return runCall(action, { log, err });
  }
  await import("./stdio.js");
  return undefined;
}
