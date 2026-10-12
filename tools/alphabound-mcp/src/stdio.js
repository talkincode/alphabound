/**
 * stdio MCP server — AlphaBound analytics, signed intel ingest, and
 * filter-parameter writes. Trading control (orders / flatten / secrets)
 * is never exposed. Parameter writes still cannot place an order.
 */
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { TOOLS, callTool, apiBase, inputSchemaFor } from "./client.js";

const EMPTY_SCHEMA = { type: "object", properties: {}, additionalProperties: false };

const server = new Server(
  { name: "alphabound-analytics", version: "0.2.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS.map((t) => ({
    name: t.name,
    description: t.description,
    inputSchema: inputSchemaFor(t) || EMPTY_SCHEMA,
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
    const result = await callTool(name, req.params.arguments || {});
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(
            { base: result.base || apiBase(), path: result.path, method: result.method, data: result.data },
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

const transport = new StdioServerTransport();
await server.connect(transport);
