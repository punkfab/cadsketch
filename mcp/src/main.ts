import { createMcpExpressApp } from "@modelcontextprotocol/express";
import { NodeStreamableHTTPServerTransport } from "@modelcontextprotocol/node";
import cors from "cors";
import type { Request, Response } from "express";
import type { Server } from "node:http";
import { APP_URL, createServer } from "./server.js";

/** Starts the HTTP server. Stateless: a fresh MCP server per request. */
export function start(port: number): Promise<Server> {
  const app = createMcpExpressApp({ host: "0.0.0.0" });
  app.use(cors());

  app.all("/mcp", async (req: Request, res: Response) => {
    const server = createServer();
    const transport = new NodeStreamableHTTPServerTransport({ sessionIdGenerator: undefined });
    res.on("close", () => {
      transport.close().catch(() => {});
      server.close().catch(() => {});
    });
    try {
      await server.connect(transport);
      await transport.handleRequest(req, res, req.body);
    } catch (error) {
      console.error("MCP error:", error);
      if (!res.headersSent) {
        res.status(500).json({ jsonrpc: "2.0", error: { code: -32603, message: "Internal server error" }, id: null });
      }
    }
  });

  // Health check, and something human-readable at the root.
  app.get("/", (_req: Request, res: Response) => {
    res.type("text/plain").send(`CADSketch MCP server. Endpoint: /mcp\nEditor: ${APP_URL}\n`);
  });

  // OpenAI domain verification for app submission: the token is plain text.
  app.get("/.well-known/openai-apps-challenge", (_req: Request, res: Response) => {
    const token = process.env.OPENAI_APPS_CHALLENGE;
    if (!token) return void res.status(404).end();
    res.type("text/plain").send(token);
  });

  return new Promise((resolve, reject) => {
    const httpServer = app.listen(port, (err?: Error) => {
      if (err) return reject(err);
      resolve(httpServer);
    });
  });
}

// Run when executed directly (not when imported by the tests).
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split("/").pop()!)) {
  const port = parseInt(process.env.PORT ?? "3001", 10);
  start(port).then(
    (httpServer) => {
      console.log(`CADSketch MCP server on http://localhost:${port}/mcp (editor: ${APP_URL})`);
      const stop = () => httpServer.close(() => process.exit(0));
      process.on("SIGINT", stop);
      process.on("SIGTERM", stop);
    },
    (err) => {
      console.error("Failed to start:", err);
      process.exit(1);
    },
  );
}
