#!/usr/bin/env node
/**
 * stdio MCP server — read-only AlphaBound analytics.
 */
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { TOOLS, apiGet, apiBase } from "./client.js";

const server = new Server(
  { name: "alphabound-analytics", version: "0.1.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS.map((t) => ({
    name: t.name,
    description: t.description,
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
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
    const data = await apiGet(tool.path);
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({ base: apiBase(), path: tool.path, data }, null, 2),
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
