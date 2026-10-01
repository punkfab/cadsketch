// Pure logic for the file viewer/editor: what a workspace file means to the
// editor, and what the editor's canvas means as a file. No DOM, no host calls,
// so it runs under `node --test`.
//
// A .cadsketch file is the agent-facing document format:
//
//   { "cadsketch": 1, "units": "mm",
//     "parts": [ { "name": "bracket", "depth": 5,
//                  "profile": [[0,0],[40,0],[40,20],[0,20]],
//                  "holes": [[8,10,2.25]] } ] }
//
// `parts` is exactly the draw_parts format (see lib/mcp/part_spec.dart), so an
// agent can write the file, the user can edit it in the editor, and the agent
// reads the result back with an ordinary file read.

export type FilePart = {
  name: string;
  depth: number;
  profile?: number[][];
  circle?: number[];
  holes: number[][];
};

export type OpenedFile = { kind: "parts"; parts: unknown[] } | { kind: "dxf"; text: string };

export const CADSKETCH_FORMAT = 1;

export function fileKind(name: string): "cadsketch" | "dxf" | null {
  const lower = name.toLowerCase();
  if (lower.endsWith(".cadsketch")) return "cadsketch";
  if (lower.endsWith(".dxf")) return "dxf";
  return null;
}

/** Parses a file's text. Throws an Error with a message fit to show the user. */
export function parseFile(name: string, text: string): OpenedFile {
  const kind = fileKind(name);
  if (kind === "dxf") return { kind: "dxf", text };
  if (kind !== "cadsketch") throw new Error(`CADSketch can't open ${name}.`);
  if (text.trim() === "") return { kind: "parts", parts: [] }; // a new, empty file
  let doc: unknown;
  try {
    doc = JSON.parse(text);
  } catch (e) {
    throw new Error(`${name} is not valid JSON: ${(e as Error).message}`);
  }
  // Accept the documented object, or a bare parts array.
  const parts = Array.isArray(doc) ? doc : (doc as { parts?: unknown })?.parts;
  if (!Array.isArray(parts)) throw new Error(`${name} has no "parts" array.`);
  return { kind: "parts", parts };
}

/**
 * The canvas as file parts, from the editor's reported state. `blocker` is set
 * when something on the canvas can't be written to the file yet, in which case
 * saving would lose it and must not happen.
 */
export function partsFromState(structured: Record<string, unknown>): { parts: FilePart[]; blocker: string | null } {
  const parts: FilePart[] = [];
  let blocker: string | null = null;
  for (const raw of (structured.parts as Record<string, unknown>[] | undefined) ?? []) {
    const name = String(raw.name ?? "Part");
    const holes = (raw.holes as number[][] | undefined) ?? [];
    if (raw.importedMesh) {
      blocker ??= `"${name}" is an imported mesh`;
      continue;
    }
    if (raw.featureOf) {
      blocker ??= `"${name}" is a feature on a face`;
      continue;
    }
    if (!raw.closed) {
      // An untouched placeholder part is simply nothing; an open sketch is work
      // in progress that the file format can't hold.
      if (Number(raw.segments ?? 0) > 0 || holes.length > 0) blocker ??= `"${name}" isn't a closed shape yet`;
      continue;
    }
    parts.push({
      name,
      depth: Number(raw.depth),
      ...(raw.profile ? { profile: raw.profile as number[][] } : {}),
      ...(raw.circle && !raw.profile ? { circle: raw.circle as number[] } : {}),
      holes,
    });
  }
  return { parts, blocker };
}

/** Stable comparison key for "did the canvas change?". */
export function canonical(parts: FilePart[]): string {
  return JSON.stringify(parts);
}

/** The file text for a set of parts: readable, diff-friendly, one vertex per line. */
export function serializeFile(parts: FilePart[]): string {
  const row = (v: number[]) => `[${v.join(", ")}]`;
  const list = (rows: number[][], indent: string) =>
    rows.length === 0 ? "[]" : `[\n${rows.map((r) => `${indent}  ${row(r)}`).join(",\n")}\n${indent}]`;
  const body = parts.map((p) => {
    const fields = [`      "name": ${JSON.stringify(p.name)}`, `      "depth": ${p.depth}`];
    if (p.profile) fields.push(`      "profile": ${list(p.profile, "      ")}`);
    if (p.circle) fields.push(`      "circle": ${row(p.circle)}`);
    fields.push(`      "holes": ${list(p.holes, "      ")}`);
    return `    {\n${fields.join(",\n")}\n    }`;
  });
  const partsText = body.length ? `[\n${body.join(",\n")}\n  ]` : "[]";
  return `{\n  "cadsketch": ${CADSKETCH_FORMAT},\n  "units": "mm",\n  "parts": ${partsText}\n}\n`;
}
