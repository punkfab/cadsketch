// Local entry point: the server a Codex / ChatGPT desktop plugin launches over
// stdio (see plugin/cadsketch/.mcp.json). No network listener, no state.
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { loadAssets } from "./assets.js";
import { createServer } from "./server.js";

// `local`: this server runs on the user's machine, so it may save exports to disk.
const server = createServer({ ...(await loadAssets()), local: true });
await server.connect(new StdioServerTransport());
