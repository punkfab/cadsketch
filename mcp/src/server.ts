import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult, ReadResourceResult } from "@modelcontextprotocol/sdk/types.js";
import { writeFile } from "node:fs/promises";
import path from "node:path";
import { z } from "zod";
import { describe, report, structuralError, type PartInput } from "./geometry.js";

// CADSketch as an MCP App, with OpenAI's plugin-extension entrypoints.
//
// One widget (the real CADSketch web app, framed by a small shell page) and
// three tools that open it:
//   draw_parts     the model draws parts; they open in the editor, editable
//   open_sketcher  an empty canvas; also the SIDEBAR app and the THREAD panel
//   open_file      the FILE viewer/editor for .cadsketch, .dxf and .ir.json files
// Whatever is on the canvas is reported back to the model as context by the
// widget (ui/update-model-context), so it can review or revise the design.
//
// The same registration serves the remote HTTP server (src/main.ts) and the
// local stdio server a Codex/ChatGPT plugin launches (src/stdio.ts). The
// server is stateless: the document lives in the widget, or in the file.

/** Where the CADSketch web build is served. Must be the build with the host bridge. */
export const APP_URL = process.env.CADSKETCH_APP_URL ?? "https://cadsketch.ai/app/";

export const SERVER_VERSION = "0.4.0";

// Bump the version in the URI when the widget changes in a breaking way: hosts
// cache the template by URI. Earlier URIs stay readable (same page) for hosts
// holding a cached tool list.
const WIDGET_URI = "ui://cadsketch/sketcher-v4.html";
const LEGACY_WIDGET_URIS = ["ui://cadsketch/sketcher-v3.html", "ui://cadsketch/sketcher-v2.html", "ui://cadsketch/sketcher-v1.html"];

/** File types the editor opens from a workspace (desktop hosts). */
export const FILE_EXTENSIONS = [".cadsketch", ".dxf", ".ir.json"];

const vertex = z
  .array(z.number())
  .min(2)
  .max(3)
  .describe("[x, y] or [x, y, bulge]. bulge = tan(theta/4) of the arc from this vertex to the next; positive bulges counter-clockwise, 1 is a semicircle, 0 or omitted is a straight edge.");

const circle = z.array(z.number()).length(3).describe("[center_x, center_y, radius] in mm");

const part = z.object({
  name: z.string().min(1).max(60).describe("Short part name, e.g. 'bracket'"),
  depth: z.number().positive().max(100000).describe("Extrusion thickness in mm"),
  profile: z
    .array(vertex)
    .min(3)
    .max(2000)
    .optional()
    .describe("Outer outline as vertices in order, mm, X right and Y up. Closed automatically (do not repeat the first vertex). Omit for a round part and give `circle` instead."),
  circle: circle.optional().describe("For a round part (disc, washer, spacer): the body as [cx, cy, r]. Use instead of `profile`."),
  holes: z.array(circle).max(500).optional().describe("Through holes, each [cx, cy, r] in mm. Must lie inside the outline."),
});

const partsArg = z.array(part).min(1).max(20).describe("The parts to draw. This replaces everything on the canvas.");

const reportShape = z.object({
  name: z.string(),
  width_mm: z.number(),
  height_mm: z.number(),
  depth_mm: z.number(),
  area_mm2: z.number(),
  volume_mm3: z.number(),
  holes: z.number(),
  warnings: z.array(z.string()),
});

/** What a host passes when the user opens a file with the file entrypoint. */
const fileInput = z.object({
  file: z.object({
    name: z.string().min(1).describe("File name with extension, no path"),
    resourceUri: z.string().min(1).describe("Opaque host URI for reading and writing the file"),
  }),
});

const READ_ONLY = { readOnlyHint: true, destructiveHint: false, openWorldHint: false, idempotentHint: true };

export interface ServerOptions {
  /** The built widget page (dist/widget.html), with %%APP_URL%% placeholders. */
  widgetHtml: string;
  /** Monochrome SVG (currentColor) shown in the sidebar and tabs. */
  iconSvg: string;
  /**
   * True for the server a desktop plugin runs on the user's own machine. Only
   * then does it offer tools that touch the filesystem.
   */
  local?: boolean;
}

export function createServer({ widgetHtml, iconSvg, local = false }: ServerOptions): McpServer {
  const icon = {
    src: "data:image/svg+xml," + encodeURIComponent(iconSvg),
    mimeType: "image/svg+xml",
    sizes: ["any"],
  };

  // The server icon is what OpenAI hosts show for the sidebar entry and tabs
  // (the SDK has no per-tool icon field; the server icon is the documented
  // fallback).
  const server = new McpServer({
    name: "cadsketch",
    title: "CADSketch",
    version: SERVER_VERSION,
    icons: [icon],
  });

  // Links a tool to the widget, and (for OpenAI hosts) registers it into the
  // sidebar / thread panel / file viewer.
  const ui = (entrypoints: unknown[] = []) => ({
    ui: { resourceUri: WIDGET_URI },
    "openai/outputTemplate": WIDGET_URI, // ChatGPT's alias for the same link
    ...(entrypoints.length ? { "openai/ui": { entrypoints }, "openai/iconStyle": "monochrome" } : {}),
  });

  server.registerTool(
    "draw_parts",
    {
      title: "Draw parts in CADSketch",
      description:
        "Draw one or more flat, extruded mechanical parts (plates, brackets, gaskets, spacers, enclosure panels) and open them in the CADSketch editor, where the user can drag points, dimension, extrude and export STL. " +
        "Use whenever the user asks to design, draw, sketch or model a part that is a 2D outline with holes, extruded to a thickness. " +
        "Units are millimetres, X right, Y up. Give real dimensions: an M3 clearance hole is r=1.7, M4 r=2.25, M5 r=2.75. " +
        "To change a design, call this again with the full, updated parts list; the canvas is replaced. " +
        "The user's own edits and freehand sketches are sent back to you as context, in this same format. " +
        "The result reports each part's size, volume and any geometry problems; fix problems before describing the part as done.",
      inputSchema: { parts: partsArg },
      outputSchema: { parts: z.array(part), report: z.array(reportShape) },
      annotations: READ_ONLY,
      _meta: ui(),
    },
    async ({ parts }): Promise<CallToolResult> => {
      const inputs = parts as PartInput[];
      const errors = inputs.map(structuralError).filter((e): e is string => e !== null);
      if (errors.length) {
        return { isError: true, content: [{ type: "text", text: `Nothing was drawn. ${errors.join(" ")}` }] };
      }
      const normalized = inputs.map((p) => ({
        name: p.name,
        depth: p.depth,
        ...(p.profile ? { profile: p.profile } : {}),
        ...(p.circle && !p.profile ? { circle: p.circle } : {}),
        holes: p.holes ?? [],
      }));
      const reports = inputs.map(report);
      return {
        content: [
          {
            type: "text",
            text:
              `Drew ${reports.length} part${reports.length === 1 ? "" : "s"} in CADSketch (the user can now edit them):\n` +
              reports.map(describe).join("\n"),
          },
        ],
        structuredContent: { parts: normalized, report: reports },
      };
    },
  );

  server.registerTool(
    "open_sketcher",
    {
      // The title is what the sidebar entry and the thread tab are called.
      title: "CADSketch",
      description:
        "Open an empty CADSketch canvas so the user can sketch a part by hand: freehand strokes snap to clean, constrained, dimensioned geometry that can be extruded. " +
        "Use when the user wants to draw something themselves, or asks to open CADSketch. " +
        "What they draw is sent back to you as context (parts with profile, holes and depth in mm), so you can review it or redraw an improved version with draw_parts.",
      inputSchema: {},
      outputSchema: { parts: z.array(part) },
      annotations: READ_ONLY,
      _meta: ui([{ type: "global" }, { type: "thread" }]),
    },
    async (): Promise<CallToolResult> => ({
      content: [{ type: "text", text: "Opened an empty CADSketch canvas. The user's sketch will arrive as context once they draw." }],
      structuredContent: { parts: [] },
    }),
  );

  server.registerTool(
    "open_file",
    {
      title: "CADSketch",
      description:
        "Open a .cadsketch, .dxf or .ir.json file from the workspace in the CADSketch editor. " +
        "A .cadsketch file is JSON: {\"cadsketch\": 1, \"units\": \"mm\", \"parts\": [...]} with parts in the draw_parts format; edits made in the editor are saved back to the file, and the editor reloads when the file changes on disk. " +
        ".dxf files open read-only. So do .ir.json feature trees (the punkfab/featuretree IR): the body and the features CADSketch can show appear on the canvas, and the ones it can't are named.",
      inputSchema: fileInput.shape,
      annotations: READ_ONLY,
      _meta: ui([{ type: "file", extensions: FILE_EXTENSIONS }]),
    },
    async ({ file }): Promise<CallToolResult> => ({
      content: [{ type: "text", text: `Opened ${file.name} in CADSketch.` }],
      structuredContent: { file },
    }),
  );

  server.registerTool(
    "check_parts",
    {
      title: "Check parts",
      description:
        "Check parts without opening the editor: returns each part's size, volume and geometry warnings (a hole outside the outline, a wall under 1 mm, overlapping holes, a profile that crosses itself). " +
        "Use it to validate a .cadsketch file you just wrote, or a design before drawing it. Same part format as draw_parts.",
      inputSchema: { parts: partsArg },
      outputSchema: { report: z.array(reportShape) },
      annotations: READ_ONLY,
    },
    async ({ parts }): Promise<CallToolResult> => {
      const inputs = parts as PartInput[];
      const errors = inputs.map(structuralError).filter((e): e is string => e !== null);
      if (errors.length) return { isError: true, content: [{ type: "text", text: errors.join(" ") }] };
      const reports = inputs.map(report);
      return { content: [{ type: "text", text: reports.map(describe).join("\n") }], structuredContent: { report: reports } };
    },
  );

  if (local) {
    // Called by the editor, never by the model. When the editor was opened on a
    // workspace file, the host adds that file's real path to the call
    // (`_meta["openai/resource"].path`); the export is written next to it. With
    // no host-provided path there is nowhere trusted to write, so it refuses.
    server.registerTool(
      "save_export",
      {
        title: "Save export",
        description: "Save an exported STL next to the open .cadsketch file.",
        inputSchema: {
          fileName: z.string().regex(/^[A-Za-z0-9_-]{1,80}\.stl$/, "must be a plain .stl file name"),
          blob: z.string().max(64 * 1024 * 1024).describe("Base64 file contents"),
        },
        outputSchema: { path: z.string() },
        annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
        _meta: { ui: { visibility: ["app"] } },
      },
      async ({ fileName, blob }, extra): Promise<CallToolResult> => {
        const meta = (extra as { _meta?: Record<string, unknown> })._meta;
        const openedPath = (meta?.["openai/resource"] as { path?: unknown } | undefined)?.path;
        if (typeof openedPath !== "string" || !path.isAbsolute(openedPath)) {
          return { isError: true, content: [{ type: "text", text: "No open workspace file to save next to." }] };
        }
        const target = path.join(path.dirname(openedPath), fileName);
        await writeFile(target, Buffer.from(blob, "base64"));
        return { content: [{ type: "text", text: `Saved ${target}` }], structuredContent: { path: target } };
      },
    );
  }

  const appOrigin = new URL(APP_URL).origin;
  const html = widgetHtml.replaceAll("%%APP_URL%%", APP_URL);
  for (const uri of [WIDGET_URI, ...LEGACY_WIDGET_URIS]) {
    server.registerResource(
      uri === WIDGET_URI ? "cadsketch-editor" : `cadsketch-editor-${uri.split("/").pop()}`,
      uri,
      { title: "CADSketch", description: "The CADSketch sketch editor", mimeType: "text/html;profile=mcp-app" },
      async (): Promise<ReadResourceResult> => ({
        contents: [
          {
            uri,
            mimeType: "text/html;profile=mcp-app",
            text: html,
            _meta: {
              "openai/ui": {
                preferredDisplayMode: "inline",
                availableDisplayModes: ["inline", "fullscreen"],
              },
              ui: {
                // The editor is the CADSketch web app itself, in a nested frame
                // on its own origin. Nothing else is loaded or contacted.
                csp: { frameDomains: [appOrigin], resourceDomains: [], connectDomains: [] },
                prefersBorder: true,
              },
              "openai/widgetDescription":
                "The CADSketch editor showing the current parts. The user can edit them by hand; edits are reported back as context.",
            },
          },
        ],
      }),
    );
  }

  return server;
}
