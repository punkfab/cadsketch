import { registerAppResource, registerAppTool, RESOURCE_MIME_TYPE } from "@modelcontextprotocol/ext-apps/server";
import { McpServer, type CallToolResult, type ReadResourceResult } from "@modelcontextprotocol/server";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";
import { describe, report, structuralError, type PartInput } from "./geometry.js";

// CADSketch as an MCP App.
//
// Two tools, one widget. The widget is the real CADSketch web app (the same
// Flutter build served at cadsketch.ai/app), embedded by a small shell page.
//   draw_parts     the model draws parts; they open in the editor, editable
//   open_sketcher  an empty canvas for the user to draw by hand
// Whatever is on the canvas is reported back to the model as context by the
// widget (ui/update-model-context), so it can review or revise the design.
//
// The server is stateless: the document lives in the widget.

const HERE = path.dirname(fileURLToPath(import.meta.url));

/** Where the CADSketch web build is served. Must be the build with the host bridge. */
export const APP_URL = process.env.CADSKETCH_APP_URL ?? "https://cadsketch.ai/app/";

// Bump the version in the URI when the widget changes in a breaking way: hosts
// cache the template by URI.
const WIDGET_URI = "ui://cadsketch/sketcher-v1.html";

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

const toolMeta = {
  ui: { resourceUri: WIDGET_URI },
  // ChatGPT's alias for the same link.
  "openai/outputTemplate": WIDGET_URI,
};

const READ_ONLY = { readOnlyHint: true, destructiveHint: false, openWorldHint: false, idempotentHint: true };

export function createServer(): McpServer {
  const server = new McpServer({ name: "CADSketch", version: "0.1.0" });

  registerAppTool(
    server,
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
      inputSchema: z.object({ parts: partsArg }),
      outputSchema: z.object({ parts: z.array(part), report: z.array(reportShape) }),
      annotations: READ_ONLY,
      _meta: toolMeta,
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

  registerAppTool(
    server,
    "open_sketcher",
    {
      title: "Open CADSketch",
      description:
        "Open an empty CADSketch canvas so the user can sketch a part by hand: freehand strokes snap to clean, constrained, dimensioned geometry that can be extruded. " +
        "Use when the user wants to draw something themselves, or asks to open CADSketch. " +
        "What they draw is sent back to you as context (parts with profile, holes and depth in mm), so you can review it or redraw an improved version with draw_parts.",
      inputSchema: z.object({}),
      outputSchema: z.object({ parts: z.array(part) }),
      annotations: READ_ONLY,
      _meta: toolMeta,
    },
    async (): Promise<CallToolResult> => ({
      content: [{ type: "text", text: "Opened an empty CADSketch canvas. The user's sketch will arrive as context once they draw." }],
      structuredContent: { parts: [] },
    }),
  );

  registerAppResource(
    server,
    "CADSketch editor",
    WIDGET_URI,
    { mimeType: RESOURCE_MIME_TYPE, description: "The CADSketch sketch editor" },
    async (): Promise<ReadResourceResult> => {
      const template = await fs.readFile(path.join(HERE, "widget.html"), "utf-8");
      const html = template.replaceAll("%%APP_URL%%", APP_URL);
      const appOrigin = new URL(APP_URL).origin;
      return {
        contents: [
          {
            uri: WIDGET_URI,
            mimeType: RESOURCE_MIME_TYPE,
            text: html,
            _meta: {
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
      };
    },
  );

  return server;
}
