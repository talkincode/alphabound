import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { after, before, describe, it } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { TOOLS } from "../src/client.js";
import { TOKEN, startMockApi } from "./helpers.js";

const ENTRY = fileURLToPath(new URL("../src/index.js", import.meta.url));

// stdio shares its server with the HTTP transport (src/server.js); this pins the stdio side:
// the real entry point, credentials from the environment, no OAuth.
describe("stdio MCP (IDE default)", () => {
  let mock;
  before(async () => {
    mock = await startMockApi();
  });
  after(() => mock.close());

  it("serves the catalog and calls the daemon with the environment token", async () => {
    const client = new Client({ name: "stdio-test", version: "1.0.0" });
    const transport = new StdioClientTransport({
      command: process.execPath,
      args: [ENTRY],
      env: { ALPHABOUND_API_BASE: mock.base, ALPHABOUND_API_TOKEN: TOKEN },
    });
    await client.connect(transport);
    try {
      const { tools } = await client.listTools();
      assert.deepEqual(
        tools.map((t) => t.name),
        TOOLS.map((t) => t.name),
      );
      const before = mock.seen.length;
      const r = await client.callTool({ name: "get_shadow", arguments: {} });
      assert.equal(JSON.parse(r.content[0].text).path, "/api/v1/shadow");
      assert.equal(mock.seen[before].authorization, `Bearer ${TOKEN}`);
      const unknown = await client.callTool({ name: "flatten", arguments: {} });
      assert.equal(unknown.isError, true);
    } finally {
      await client.close();
    }
  });
});
