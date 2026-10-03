/**
 * stdio transport for the AlphaBound analytics MCP server (see server.js).
 * Per the MCP authorization spec, stdio reads credentials from the environment
 * instead of using OAuth.
 */
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createMcpServer } from "./server.js";

await createMcpServer().connect(new StdioServerTransport());
