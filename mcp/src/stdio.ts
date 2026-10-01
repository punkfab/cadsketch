// Local entry point: the server a Codex / ChatGPT desktop plugin launches over
// stdio (see plugin/cadsketch/.mcp.json). No network listener, no state.
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { loadAssets } from "./assets.js";
import { createServer } from "./server.js";

const server = createServer(await loadAssets());
await server.connect(new StdioServerTransport());
