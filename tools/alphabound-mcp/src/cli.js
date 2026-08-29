export const HELP = `alphabound-mcp — AlphaBound analytics MCP (read-only + signed intel ingest)

Usage:
  alphabound-mcp                 Start stdio MCP (IDE / Copilot default)
  alphabound-mcp --http          Start loopback HTTP gateway
  alphabound-mcp install [opts]  Write MCP client config (npx -y auto-install)
  alphabound-mcp --help

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
  if (args.length) {
    return { kind: "error", error: `unknown args: ${args.join(" ")}\n${HELP}` };
  }
  return { kind: "stdio" };
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
  await import("./stdio.js");
  return undefined;
}
