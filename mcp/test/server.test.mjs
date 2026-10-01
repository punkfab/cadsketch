// End-to-end over real HTTP: a client lists the tools, draws parts, and reads
// the widget, exactly as a host does.
import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";
import { start } from "../dist/main.js";
import { report, tessellate } from "../dist/geometry.js";

let httpServer;
let client;

before(async () => {
  httpServer = await start(0);
  const { port } = httpServer.address();
  client = new Client({ name: "test-host", version: "0.0.0" });
  await client.connect(new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp`)));
});

after(async () => {
  await client?.close();
  await new Promise((r) => httpServer.close(r));
});

const bracket = {
  name: "bracket",
  depth: 5,
  profile: [[0, 0], [40, 0], [40, 20], [0, 20]],
  holes: [[8, 10, 2.25], [32, 10, 2.25]],
};

test("both tools are listed and linked to the widget", async () => {
  const { tools } = await client.listTools();
  const names = tools.map((t) => t.name).sort();
  assert.deepEqual(names, ["draw_parts", "open_sketcher"]);
  for (const t of tools) {
    assert.equal(t._meta?.ui?.resourceUri, "ui://cadsketch/sketcher-v1.html");
    assert.equal(t._meta?.["openai/outputTemplate"], "ui://cadsketch/sketcher-v1.html");
    assert.equal(t.annotations?.readOnlyHint, true);
  }
});

test("draw_parts returns the parts for the widget and a report for the model", async () => {
  const result = await client.callTool({ name: "draw_parts", arguments: { parts: [bracket] } });
  assert.ok(!result.isError);
  const { parts, report: reports } = result.structuredContent;
  assert.equal(parts.length, 1);
  assert.deepEqual(parts[0].profile, bracket.profile);
  assert.equal(reports[0].width_mm, 40);
  assert.equal(reports[0].height_mm, 20);
  // 40*20 minus two r=2.25 holes, times 5 mm.
  const expected = (800 - 2 * Math.PI * 2.25 ** 2) * 5;
  assert.ok(Math.abs(reports[0].volume_mm3 - expected) < 0.1);
  assert.deepEqual(reports[0].warnings, []);
  assert.match(result.content[0].text, /bracket: 40 x 20 mm/);
});

test("geometry problems come back as warnings the model can act on", async () => {
  const result = await client.callTool({
    name: "draw_parts",
    arguments: {
      parts: [{ ...bracket, holes: [[60, 10, 2], [39, 10, 2], [8, 10, 2], [9, 10, 2]] }],
    },
  });
  const warnings = result.structuredContent.report[0].warnings.join(" | ");
  assert.match(warnings, /Hole 1 .* outside the profile/);
  assert.match(warnings, /Hole 2 .* breaks through the edge/);
  assert.match(warnings, /Holes 3 and 4 overlap/);
});

test("a part with neither profile nor circle is refused, not drawn", async () => {
  const result = await client.callTool({ name: "draw_parts", arguments: { parts: [{ name: "x", depth: 5 }] } });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /Nothing was drawn/);
});

test("open_sketcher opens an empty canvas", async () => {
  const result = await client.callTool({ name: "open_sketcher", arguments: {} });
  assert.deepEqual(result.structuredContent, { parts: [] });
});

test("the widget is a self-contained page that frames only the CADSketch app", async () => {
  const { contents } = await client.readResource({ uri: "ui://cadsketch/sketcher-v1.html" });
  const [res] = contents;
  assert.equal(res.mimeType, "text/html;profile=mcp-app");
  assert.match(res.text, /data-app-url="https:\/\/cadsketch\.ai\/app\/"/);
  assert.ok(!res.text.includes("%%"), "all placeholders filled");
  assert.ok(!/<script[^>]+src=/.test(res.text), "no external scripts");
  assert.deepEqual(res._meta.ui.csp.frameDomains, ["https://cadsketch.ai"]);
  assert.deepEqual(res._meta.ui.csp.connectDomains, []);
});

test("bulge arcs: a semicircle end adds half a disc of area", () => {
  // 20 x 20 square with a CCW semicircle (r = 10) on the right edge.
  const r = report({ name: "tab", depth: 1, profile: [[0, 0], [20, 0, 1], [20, 20], [0, 20]] });
  assert.ok(Math.abs(r.width_mm - 30) < 0.2);
  assert.ok(Math.abs(r.area_mm2 - (400 + (Math.PI * 100) / 2)) < 2);
  assert.ok(tessellate([[0, 0], [20, 0, 1], [20, 20], [0, 20]]).length > 10);
});

test("a self-crossing outline is flagged", () => {
  const r = report({ name: "bowtie", depth: 1, profile: [[0, 0], [10, 10], [10, 0], [0, 10]] });
  assert.ok(r.warnings.some((w) => /crosses itself/.test(w)));
});
