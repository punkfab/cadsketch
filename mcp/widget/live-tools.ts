// Tools the MOUNTED editor publishes to the model. Unlike the server's tools,
// these act on the editor the user is looking at: the sidebar tab, the thread
// panel, or the open file. Each one is a command sent into the editor
// (lib/mcp/host_commands.dart), where it runs through the same controller calls
// a tap or drag makes and lands on the undo stack as one step.
//
// Addressing is in the terms get_sketch reports: millimetres with Y up, a part
// by name, a vertex or edge by its index around the profile, a hole by its
// index in `holes`.
import type { App } from "@modelcontextprotocol/ext-apps";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";

/** Runs one command in the editor. Rejects with a message meant for the model. */
export type EditorCall = (op: string, args: Record<string, unknown>) => Promise<Record<string, unknown>>;

export interface LiveToolDeps {
  call: EditorCall;
  /** Saves an export. Resolves to where it went, or rejects with why not. */
  saveExport: (fileName: string, base64: string) => Promise<string>;
}

const part = z.string().optional().describe("Part name. Defaults to the active part.");
const point = z.array(z.number()).length(2).describe("[x, y] in mm, X right, Y up");
const vertexSchema = z.array(z.number()).min(2).max(3);
const circleSchema = z.array(z.number()).length(3);
const partSpec = z.object({
  name: z.string().min(1).max(60),
  depth: z.number().positive(),
  profile: z.array(vertexSchema).min(3).optional().describe("Outline vertices [x, y] or [x, y, bulge], closed automatically"),
  circle: circleSchema.optional().describe("[cx, cy, r] for a round body, instead of profile"),
  holes: z.array(circleSchema).optional().describe("Through holes [cx, cy, r]"),
});

const READ = { readOnlyHint: true, destructiveHint: false, openWorldHint: false };
const EDIT = { readOnlyHint: false, destructiveHint: false, openWorldHint: false };

type ToolDef = {
  name: string;
  title: string;
  description: string;
  schema: z.ZodObject;
  annotations: typeof READ | typeof EDIT;
};

/** Everything except screenshot and export, which need special result handling. */
export const COMMAND_TOOLS: ToolDef[] = [
  {
    name: "get_sketch",
    title: "Read the sketch",
    description:
      "Read what is on the CADSketch canvas right now: every part with its profile vertices, holes, depth, each edge's length and driving dimension, and its constraints, all with the indices the editing tools take. Call this before editing, and again whenever the user may have changed the sketch by hand.",
    schema: z.object({}),
    annotations: READ,
  },
  {
    name: "replace_parts",
    title: "Replace the canvas",
    description:
      "Replace everything on the open canvas with these parts. Use for a new design or a wholesale redraw. For a small change prefer the targeted tools (move_vertex, add_hole, set_dimension), which keep the user's constraints and dimensions.",
    schema: z.object({ parts: z.array(partSpec).max(20) }),
    annotations: EDIT,
  },
  {
    name: "add_part",
    title: "Add a part",
    description: "Add one more part to the canvas, next to the existing ones, and make it the active part.",
    schema: z.object({ part: partSpec }),
    annotations: EDIT,
  },
  {
    name: "delete_part",
    title: "Delete a part",
    description: "Delete a part and any features sketched on its faces.",
    schema: z.object({ part }),
    annotations: { ...EDIT, destructiveHint: true },
  },
  {
    name: "select_part",
    title: "Select a part",
    description: "Make a part the active one, so the user sees it and later commands default to it.",
    schema: z.object({ part: z.string().describe("Part name") }),
    annotations: EDIT,
  },
  {
    name: "set_depth",
    title: "Set thickness",
    description: "Set a part's extrusion thickness in mm.",
    schema: z.object({ part, depth: z.number().positive() }),
    annotations: EDIT,
  },
  {
    name: "add_hole",
    title: "Add a hole",
    description: "Add a through hole. Clearance radii: M3 1.7, M4 2.25, M5 2.75, M6 3.3. The result warns if the hole landed outside the profile.",
    schema: z.object({ part, center: point, radius: z.number().positive().describe("Radius in mm") }),
    annotations: EDIT,
  },
  {
    name: "move_hole",
    title: "Move or resize a hole",
    description: "Move a hole to a new center, change its radius, or both. `hole` is its index in the part's `holes` list.",
    schema: z.object({ part, hole: z.number().int().min(0), center: point.optional(), radius: z.number().positive().optional() }),
    annotations: EDIT,
  },
  {
    name: "remove_hole",
    title: "Remove a hole",
    description: "Remove a hole by its index in the part's `holes` list. Later holes shift down by one.",
    schema: z.object({ part, hole: z.number().int().min(0) }),
    annotations: EDIT,
  },
  {
    name: "move_vertex",
    title: "Move a vertex",
    description:
      "Move one profile vertex to a new position. `vertex` is its index in the part's `profile`. Constraints stay in force, so neighbouring vertices may follow (a horizontal edge stays horizontal). Set release_constraints to move only this vertex.",
    schema: z.object({
      part,
      vertex: z.number().int().min(0),
      to: point,
      release_constraints: z.boolean().optional().describe("Drop the horizontal/vertical/parallel/perpendicular constraints on this vertex's edges first"),
    }),
    annotations: EDIT,
  },
  {
    name: "set_dimension",
    title: "Set an edge length",
    description:
      "Drive an edge to an exact length in mm: the sketch re-solves so the edge is that long, and it stays that long through later edits. `edge` i runs from vertex i to vertex i+1. Pass length null to remove the driving dimension.",
    schema: z.object({ part, edge: z.number().int().min(0), length: z.number().positive().nullable() }),
    annotations: EDIT,
  },
  {
    name: "add_constraint",
    title: "Add a constraint",
    description:
      "Constrain edges so the design keeps its intent when dimensions change. horizontal and vertical take one edge; parallel, perpendicular and equal (equal length) take two.",
    schema: z.object({
      part,
      kind: z.enum(["horizontal", "vertical", "parallel", "perpendicular", "equal"]),
      edges: z.array(z.number().int().min(0)).min(1).max(2).describe("Edge indices"),
    }),
    annotations: EDIT,
  },
  {
    name: "remove_constraint",
    title: "Remove a constraint",
    description: "Remove a constraint by its index in the part's `constraintList` (from get_sketch).",
    schema: z.object({ part, constraint: z.number().int().min(0) }),
    annotations: EDIT,
  },
  {
    name: "undo",
    title: "Undo",
    description: "Undo the last edit to the sketch, whether it was yours or the user's.",
    schema: z.object({}),
    annotations: EDIT,
  },
  {
    name: "redo",
    title: "Redo",
    description: "Redo the edit that was just undone.",
    schema: z.object({}),
    annotations: EDIT,
  },
  {
    name: "fit_view",
    title: "Zoom to fit",
    description: "Zoom the 2D sketch view to fit the active part. Does not change the design.",
    schema: z.object({}),
    annotations: READ,
  },
];

const text = (t: string) => ({ type: "text" as const, text: t });
const failure = (e: unknown): CallToolResult => ({ isError: true, content: [text(e instanceof Error ? e.message : String(e))] });

type Handler = (args: Record<string, unknown>) => Promise<CallToolResult>;
type ToolConfig = { title: string; description: string; inputSchema: z.ZodObject; annotations: object };

/** What the model reads back after a command: what happened, then the data. */
export function describeResult(value: Record<string, unknown>): string {
  const lines: string[] = [];
  if (value.did) lines.push(String(value.did));
  if (value.warning) lines.push(`Warning: ${value.warning}`);
  if (value.summary) lines.push(String(value.summary));
  const data = value.part ?? value.parts;
  if (data !== undefined) lines.push(JSON.stringify(data));
  return lines.join("\n");
}

export function registerLiveTools(app: App, deps: LiveToolDeps) {
  // The SDK's generic signature ties the result type to an output schema; these
  // tools return plain tool results, so register through one loosely typed door.
  const register = (name: string, config: ToolConfig, handler: Handler) =>
    (app.registerTool as unknown as (name: string, config: ToolConfig, cb: Handler) => unknown).call(app, name, config, handler);

  for (const tool of COMMAND_TOOLS) {
    register(
      tool.name,
      { title: tool.title, description: tool.description, inputSchema: tool.schema, annotations: tool.annotations },
      async (args) => {
        try {
          const value = await deps.call(tool.name, args ?? {});
          return { content: [text(describeResult(value))], structuredContent: value };
        } catch (e) {
          return failure(e);
        }
      },
    );
  }

  register(
    "screenshot",
    {
      title: "Look at the editor",
      description:
        "Get a picture of the CADSketch editor as the user sees it: the 3D view and the dimensioned 2D sketch. Use it to check your work visually, or to see what the user is pointing at.",
      inputSchema: z.object({}),
      annotations: READ,
    },
    async () => {
      try {
        const shot = await deps.call("screenshot", {});
        return {
          content: [
            { type: "image" as const, data: String(shot.pngBase64), mimeType: "image/png" },
            text(`CADSketch editor, ${shot.width} x ${shot.height} px.`),
          ],
        };
      } catch (e) {
        return failure(e);
      }
    },
  );

  register(
    "export_stl",
    {
      title: "Export STL",
      description:
        "Export a part as a binary STL for 3D printing. When a .cadsketch file is open, the STL is saved next to it and the path is returned. Otherwise the app offers it as a download.",
      inputSchema: z.object({ part }),
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
    },
    async (args) => {
      try {
        const out = await deps.call("export_stl", args ?? {});
        const where = await deps.saveExport(String(out.fileName), String(out.stlBase64));
        return { content: [text(`${out.did} ${where}`)], structuredContent: { fileName: out.fileName, triangles: out.triangles, saved: where } };
      } catch (e) {
        return failure(e);
      }
    },
  );
}
