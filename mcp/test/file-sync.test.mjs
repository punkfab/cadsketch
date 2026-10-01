// The .cadsketch file format and the rules for writing the canvas back to it.
import assert from "node:assert/strict";
import { test } from "node:test";
import { canonical, fileKind, parseFile, partsFromState, serializeFile } from "../dist/file-sync.js";

const bracket = { name: "bracket", depth: 5, profile: [[0, 0], [40, 0], [40, 20], [0, 20]], holes: [[8, 10, 2.25]] };

// What the editor reports for a part (lib/mcp/part_spec.dart, partToSpecJson).
const reported = (extra = {}) => ({ ...bracket, closed: true, segments: 4, constraints: {}, dimensionedSegments: 0, ...extra });

test("file kinds", () => {
  assert.equal(fileKind("a/b/Bracket.CADSKETCH"), "cadsketch");
  assert.equal(fileKind("plate.dxf"), "dxf");
  assert.equal(fileKind("part.step"), null);
});

test("a written file parses back to the same parts", () => {
  const text = serializeFile([bracket, { name: "spacer", depth: 8, circle: [0, 0, 6], holes: [] }]);
  const doc = JSON.parse(text);
  assert.equal(doc.cadsketch, 1);
  assert.equal(doc.units, "mm");
  const opened = parseFile("x.cadsketch", text);
  assert.equal(opened.kind, "parts");
  assert.deepEqual(opened.parts, [bracket, { name: "spacer", depth: 8, circle: [0, 0, 6], holes: [] }]);
  // One vertex per line keeps agent diffs readable.
  assert.match(text, /\n        \[40, 20\],\n/);
  assert.ok(text.endsWith("}\n"));
});

test("an empty file is an empty canvas; a bare array is accepted; junk is refused clearly", () => {
  assert.deepEqual(parseFile("new.cadsketch", "  \n"), { kind: "parts", parts: [] });
  assert.deepEqual(parseFile("a.cadsketch", JSON.stringify([bracket])).parts, [bracket]);
  assert.throws(() => parseFile("a.cadsketch", "{nope"), /not valid JSON/);
  assert.throws(() => parseFile("a.cadsketch", '{"name":"x"}'), /no "parts" array/);
  assert.deepEqual(parseFile("p.dxf", "0\nEOF\n"), { kind: "dxf", text: "0\nEOF\n" });
});

test("the canvas becomes file parts, without the editor-only fields", () => {
  const { parts, blocker } = partsFromState({ parts: [reported()] });
  assert.equal(blocker, null);
  assert.deepEqual(parts, [bracket]);
  assert.equal(canonical(parts), canonical([bracket]));
});

test("an untouched placeholder part is nothing, not a blocker", () => {
  const { parts, blocker } = partsFromState({ parts: [{ name: "Part 1", depth: 100, closed: false, holes: [], segments: 0 }] });
  assert.deepEqual(parts, []);
  assert.equal(blocker, null);
});

test("work the file can't hold blocks saving instead of being dropped", () => {
  const open = partsFromState({ parts: [reported(), { name: "wip", depth: 5, closed: false, holes: [], segments: 3 }] });
  assert.match(open.blocker, /"wip" isn't a closed shape yet/);
  assert.match(partsFromState({ parts: [reported({ featureOf: "base", operation: "union" })] }).blocker, /feature on a face/);
  assert.match(partsFromState({ parts: [{ name: "m", depth: 1, closed: false, holes: [], segments: 0, importedMesh: true }] }).blocker, /imported mesh/);
});
