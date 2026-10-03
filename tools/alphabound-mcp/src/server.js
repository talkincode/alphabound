/**
 * The MCP server both transports expose — AlphaBound analytics plus signed intel
 * ingest. Trading control (orders / flatten / secrets) is never exposed.
 */
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { TOOLS, callTool, apiBase } from "./client.js";

const EMPTY_SCHEMA = { type: "object", properties: {}, additionalProperties: false };

export const SERVER_INFO = { name: "alphabound-analytics", version: "0.1.0" };

/**
 * @param overrides  `{ base, token, fetch }` forwarded to every tool call.
 *                   Omitted = read the environment per call (stdio).
 */
export function createMcpServer(overrides = {}) {
  const server = new Server(SERVER_INFO, { capabilities: { tools: {} } });

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: TOOLS.map((t) => ({
      name: t.name,
      description: t.description,
      inputSchema: t.inputSchema || EMPTY_SCHEMA,
    })),
  }));

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const name = req.params.name;
    const tool = TOOLS.find((t) => t.name === name);
    if (!tool) {
      return {
        isError: true,
        content: [{ type: "text", text: `unknown tool: ${name}` }],
      };
    }
    try {
      const result = await callTool(name, req.params.arguments || {}, overrides);
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              { base: result.base || apiBase(overrides), path: result.path, method: result.method, data: result.data },
              null,
              2,
            ),
          },
        ],
      };
    } catch (e) {
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: JSON.stringify({
              error: e.message,
              status: e.status || null,
              body: e.body || null,
            }),
          },
        ],
      };
    }
  });

  return server;
}
