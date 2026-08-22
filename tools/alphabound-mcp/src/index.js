#!/usr/bin/env node
/**
 * stdio MCP server — AlphaBound analytics plus signed intel ingest.
 * Trading control (orders / flatten / secrets) is never exposed.
 */
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { TOOLS, apiGet, apiPost, apiBase } from "./client.js";

const EMPTY_SCHEMA = { type: "object", properties: {}, additionalProperties: false };

const server = new Server(
  { name: "alphabound-analytics", version: "0.1.0" },
  { capabilities: { tools: {} } },
);

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
    const data =
      tool.method === "POST"
        ? await apiPost(tool.path, req.params.arguments || {})
        : await apiGet(tool.path);
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify({ base: apiBase(), path: tool.path, method: tool.method || "GET", data }, null, 2),
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
