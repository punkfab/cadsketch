// End-to-end over the real transports: a client lists the tools, draws parts,
// and reads the widget, exactly as a host does. Once over HTTP (the remote
// server) and once over stdio (the bundled server a Codex plugin launches).
import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { start } from "../dist/main.js";
import { report, tessellate } from "../dist/geometry.js";

const WIDGET = "ui://cadsketch/sketcher-v4.html";
const PLUGIN_DIR = fileURLToPath(new URL("../../plugin/cadsketch/", import.meta.url));

let httpServer;
let client;
let pluginClient;

before(async () => {
  httpServer = await start(0);
  const { port } = httpServer.address();
  client = new Client({ name: "test-host", version: "0.0.0" });
  await client.connect(new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp`)));

  // Launched exactly as plugin/cadsketch/.mcp.json says.
  pluginClient = new Client({ name: "test-codex", version: "0.0.0" });
  await pluginClient.connect(new StdioClientTransport({ command: "node", args: ["./dist/server.mjs"], cwd: PLUGIN_DIR }));
});

after(async () => {
  await client?.close();
  await pluginClient?.close();
  await new Promise((r) => httpServer.close(r));
});

const bracket = {
  name: "bracket",
  depth: 5,
  profile: [[0, 0], [40, 0], [40, 20], [0, 20]],
  holes: [[8, 10, 2.25], [32, 10, 2.25]],
};

test("the tools are listed and linked to the widget", async () => {
  const { tools } = await client.listTools();
  // The remote server offers nothing that touches a filesystem.
  assert.deepEqual(tools.map((t) => t.name).sort(), ["check_parts", "draw_parts", "open_file", "open_sketcher"]);
  for (const t of tools.filter((t) => t.name !== "check_parts")) {
    assert.equal(t._meta?.ui?.resourceUri, WIDGET);
    assert.equal(t._meta?.["openai/outputTemplate"], WIDGET);
    assert.equal(t.annotations?.readOnlyHint, true);
  }
});

test("extension entrypoints: sidebar + thread panel, and a file viewer", async () => {
  const { tools } = await client.listTools();
  const by = Object.fromEntries(tools.map((t) => [t.name, t]));
  assert.deepEqual(by.open_sketcher._meta["openai/ui"].entrypoints, [{ type: "global" }, { type: "thread" }]);
  assert.deepEqual(by.open_file._meta["openai/ui"].entrypoints, [{ type: "file", extensions: [".cadsketch", ".dxf", ".ir.json"] }]);
  // The model-facing tool is not an entrypoint.
  assert.equal(by.draw_parts._meta["openai/ui"], undefined);
  // Entrypoint tools must accept what the host passes: {} and a FileInput.
  assert.deepEqual(by.open_sketcher.inputSchema.required ?? [], []);
  assert.deepEqual(by.open_file.inputSchema.required, ["file"]);
  const opened = await client.callTool({ name: "open_sketcher", arguments: {} });
  assert.deepEqual(opened.structuredContent, { parts: [] });
  const file = { name: "bracket.cadsketch", resourceUri: "host-resource://abc" };
  const viewed = await client.callTool({ name: "open_file", arguments: { file } });
  assert.deepEqual(viewed.structuredContent, { file });
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

test("the widget is a self-contained page that frames only the CADSketch app", async () => {
  const { contents } = await client.readResource({ uri: WIDGET });
  const [res] = contents;
  assert.equal(res.mimeType, "text/html;profile=mcp-app");
  assert.match(res.text, /data-app-url="https:\/\/cadsketch\.ai\/app\/"/);
  assert.ok(!res.text.includes("%%"), "all placeholders filled");
  assert.ok(!/<script[^>]+src=/.test(res.text), "no external scripts");
  assert.deepEqual(res._meta.ui.csp.frameDomains, ["https://cadsketch.ai"]);
  assert.deepEqual(res._meta.ui.csp.connectDomains, []);
  assert.deepEqual(res._meta["openai/ui"].availableDisplayModes, ["inline", "fullscreen"]);
  // A host with a cached tool list still asks for an older address.
  for (const old of ["ui://cadsketch/sketcher-v3.html", "ui://cadsketch/sketcher-v2.html", "ui://cadsketch/sketcher-v1.html"]) {
    const legacy = await client.readResource({ uri: old });
    assert.equal(legacy.contents[0].text, res.text);
  }
});

test("the bundled plugin server (stdio) is the same server", async () => {
  const info = pluginClient.getServerVersion();
  assert.equal(info.name, "cadsketch");
  assert.equal(info.title, "CADSketch");
  assert.match(info.icons[0].src, /^data:image\/svg\+xml,/);
  const { tools } = await pluginClient.listTools();
  assert.deepEqual(tools.map((t) => t.name).sort(), ["check_parts", "draw_parts", "open_file", "open_sketcher", "save_export"]);
  // save_export is for the editor, not the model.
  assert.deepEqual(tools.find((t) => t.name === "save_export")._meta.ui.visibility, ["app"]);
  const result = await pluginClient.callTool({ name: "draw_parts", arguments: { parts: [bracket] } });
  assert.equal(result.structuredContent.report[0].width_mm, 40);
  const { contents } = await pluginClient.readResource({ uri: WIDGET });
  assert.match(contents[0].text, /data-app-url="https:\/\/cadsketch\.ai\/app\/"/);
});

test("the plugin launches exactly as its .mcp.json says, as an unambiguous ES module", async () => {
  const mcp = JSON.parse(await readFile(path.join(PLUGIN_DIR, ".mcp.json"), "utf8"));
  const { command, args } = mcp.mcpServers.cadsketch;
  assert.equal(command, "node");
  // .mjs so Node never has to guess the module type (Node < 20.19 would not).
  assert.deepEqual(args, ["./dist/server.mjs"]);
  await readFile(path.join(PLUGIN_DIR, args[0]));
});

test("check_parts validates without opening the editor", async () => {
  const ok = await client.callTool({ name: "check_parts", arguments: { parts: [bracket] } });
  assert.equal(ok.structuredContent.report[0].width_mm, 40);
  assert.deepEqual(ok.structuredContent.report[0].warnings, []);
  assert.equal(ok._meta, undefined);
  const bad = await client.callTool({ name: "check_parts", arguments: { parts: [{ ...bracket, holes: [[60, 10, 2]] }] } });
  assert.match(bad.structuredContent.report[0].warnings.join(" "), /outside the profile/);
});

test("save_export writes only next to the file the host opened", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "cadsketch-"));
  try {
    const blob = Buffer.from("solid test").toString("base64");
    // The host adds the opened file's real path; the export lands beside it.
    const saved = await pluginClient.callTool({
      name: "save_export",
      arguments: { fileName: "bracket.stl", blob },
      _meta: { "openai/resource": { path: path.join(dir, "bracket.cadsketch") } },
    });
    assert.ok(!saved.isError, JSON.stringify(saved.content));
    assert.equal(saved.structuredContent.path, path.join(dir, "bracket.stl"));
    assert.equal(await readFile(path.join(dir, "bracket.stl"), "utf8"), "solid test");

    // No host-provided path: nowhere trusted to write.
    const refused = await pluginClient.callTool({ name: "save_export", arguments: { fileName: "bracket.stl", blob } });
    assert.equal(refused.isError, true);

    // The name cannot leave the directory or change the file type.
    for (const fileName of ["../evil.stl", "a/b.stl", "notes.txt", ".stl"]) {
      const r = await pluginClient.callTool({
        name: "save_export",
        arguments: { fileName, blob },
        _meta: { "openai/resource": { path: path.join(dir, "bracket.cadsketch") } },
      });
      assert.equal(r.isError, true, fileName);
    }
    // And the remote server does not have the tool at all.
    const remote = await client.callTool({ name: "save_export", arguments: { fileName: "x.stl", blob } });
    assert.equal(remote.isError, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("the directory package builds and passes the portal's limits", async () => {
  const { execFileSync } = await import("node:child_process");
  const out = execFileSync("node", ["package-directory.mjs"], { cwd: fileURLToPath(new URL("../", import.meta.url)), encoding: "utf8" });
  assert.match(out, /cadsketch-plugin-\d+\.\d+\.\d+\.zip/);
  for (const entry of [".codex-plugin/plugin.json", ".mcp.json", "skills/cadsketch/SKILL.md", "assets/logo.svg", "assets/screenshot-1.png"]) {
    assert.ok(out.includes(entry), `ZIP is missing ${entry}`);
  }
  // The local server bundle must not ship to the directory.
  assert.ok(!out.includes("dist/server."));
  const staged = JSON.parse(await readFile(new URL("../dist/directory/cadsketch/.codex-plugin/plugin.json", import.meta.url), "utf8"));
  assert.equal(staged.extensions["com.openai"].review.test_cases.positive.length, 5);
  assert.equal(staged.extensions["com.openai"].review.test_cases.negative.length, 3);
  assert.equal(staged.interface.screenshots.length, staged.interface.defaultPrompt.length);
  const mcp = JSON.parse(await readFile(new URL("../dist/directory/cadsketch/.mcp.json", import.meta.url), "utf8"));
  assert.match(mcp.mcpServers.cadsketch.url, /^https:\/\/.+\/mcp$/);
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
