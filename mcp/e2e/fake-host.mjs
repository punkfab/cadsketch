// A stand-in for the Codex / ChatGPT desktop host: speaks the MCP Apps protocol
// plus OpenAI's file-resource extension to the CADSketch widget, so the file
// viewer flow can be tested without the desktop app.
//
//   node fake-host.mjs <widget.html> <app-url> [sandbox-attr]
import { chromium } from "playwright-core";
import { readFile, writeFile } from "node:fs/promises";
import { hostScript } from "./host.mjs";

const [widgetPath, appUrl, sandbox = "allow-scripts allow-same-origin"] = process.argv.slice(2);
const OUT = process.env.OUT ?? ".";
const widgetHtml = (await readFile(widgetPath, "utf8")).replaceAll("%%APP_URL%%", appUrl);

const FILE_TEXT = JSON.stringify({
  cadsketch: 1,
  units: "mm",
  parts: [{ name: "plate", depth: 4, profile: [[0, 0], [80, 0], [80, 40], [0, 40]], holes: [[20, 20, 3]] }],
});

const browser = await chromium.launch({ channel: "chrome", headless: true, args: ["--no-sandbox", "--use-gl=swiftshader", "--enable-unsafe-swiftshader"] });
const errors = [];
const results = [];
const check = (name, ok, detail = "") => {
  results.push(ok);
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  — " + detail : ""}`);
};

async function newHost(prepare) {
  const page = await browser.newPage({ viewport: { width: 1200, height: 760 } });
  page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)));
  page.on("console", (m) => { if (m.type() === "error") errors.push(m.text().slice(0, 200)); });
  await page.setContent("<body></body>");
  await page.evaluate(`(${hostScript.toString()})(${JSON.stringify(widgetHtml)}, ${JSON.stringify(sandbox)}, ${JSON.stringify(prepare)})`);
  return page;
}
const ctxText = (page) => page.evaluate(() => window.H.context?.content?.[0]?.text ?? "");
const waitCtx = async (page, pred, ms = 40000) => {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    const t = await ctxText(page);
    if (pred(t)) return t;
    await page.waitForTimeout(500);
  }
  return ctxText(page);
};

// ---- 1. open a .cadsketch file ---------------------------------------------
{
  const page = await newHost(`window.H.openFile("plate.cadsketch", ${JSON.stringify(FILE_TEXT)})`);
  const text = await waitCtx(page, (t) => t.includes("plate"));
  check("file opens in the editor and is reported to the model", /plate: closed profile, 4 vertices, 80 x 40 mm, extruded 4 mm, 1 hole/.test(text), text.split("\n")[1]);
  check("context names the open file", text.includes("Open file: plate.cadsketch"));
  const h1 = await page.evaluate(() => ({ title: window.H.context?.content?.[0]?._meta?.["openai/title"], readMeta: window.H.lastReadMeta, sub: window.H.subscribed, writes: window.H.writes.length }));
  check("attachment is titled with the file name", h1.title === "plate.cadsketch", String(h1.title));
  check("file is read as text and subscribed to", h1.readMeta?.["openai/resource"]?.representation === "text" && h1.sub.length === 1);
  await page.waitForTimeout(3000);
  check("merely opening a file does not rewrite it", (await page.evaluate(() => window.H.writes.length)) === 0);
  await page.screenshot({ path: `${OUT}/fake-open.png` });

  // ---- 2. the user edits: drag the bottom-right vertex ---------------------
  // Locate the vertex ring (orange) in the 2D pane on the right.
  const png = await page.screenshot();
  await writeFile(`${OUT}/fake-before-drag.png`, png);
  const target = await page.evaluate(async (b64) => {
    const img = new Image();
    img.src = "data:image/png;base64," + b64;
    await img.decode();
    const c = document.createElement("canvas");
    c.width = img.width; c.height = img.height;
    const g = c.getContext("2d");
    g.drawImage(img, 0, 0);
    const d = g.getImageData(0, 0, c.width, c.height).data;
    let best = -1, at = null;
    for (let y = 0; y < c.height; y++) for (let x = Math.floor(c.width * 0.6); x < c.width; x++) {
      const i = (y * c.width + x) * 4;
      if (d[i] > 220 && d[i + 1] > 150 && d[i + 1] < 215 && d[i + 2] < 110 && x + y > best) { best = x + y; at = { x, y }; }
    }
    return at;
  }, png.toString("base64"));
  if (target) {
    const sx = target.x - 6, sy = target.y - 6;
    await page.mouse.move(sx, sy);
    await page.mouse.down();
    for (let k = 1; k <= 12; k++) { await page.mouse.move(sx + k * 5, sy + k * 3, { steps: 2 }); await page.waitForTimeout(30); }
    await page.mouse.up();
  }
  const t0 = Date.now();
  while (Date.now() - t0 < 15000 && (await page.evaluate(() => window.H.writes.length)) === 0) await page.waitForTimeout(400);
  const w = await page.evaluate(() => window.H.writes);
  check("a hand edit is saved back to the file", w.length >= 1, target ? `dragged from ${target.x},${target.y}` : "vertex not found");
  if (w.length) {
    const doc = JSON.parse(w[0].text);
    const xs = doc.parts[0].profile.map((v) => v[0]);
    check("saved file is valid .cadsketch with the edited geometry", doc.cadsketch === 1 && doc.parts[0].name === "plate" && Math.max(...xs) - Math.min(...xs) > 80.5, `width ${(Math.max(...xs) - Math.min(...xs)).toFixed(1)} mm`);
    check("save used the etag it read (no blind overwrite)", w[0].ifMatch === "v1", String(w[0].ifMatch));
  }
  await page.waitForTimeout(2500);
  const afterEcho = await page.evaluate(() => ({ writes: window.H.writes.length, reads: window.H.reads }));
  check("its own save echoing back does not cause another save", afterEcho.writes === w.length, `writes ${afterEcho.writes}`);

  // ---- 3. the agent edits the file on disk ----------------------------------
  const agentText = JSON.stringify({ cadsketch: 1, units: "mm", parts: [{ name: "plate", depth: 6, profile: [[0, 0], [50, 0], [50, 25], [0, 25]], holes: [] }] });
  const before = await page.evaluate(() => window.H.writes.length);
  await page.evaluate((t) => window.H.changeOnDisk("host-resource://plate.cadsketch", t), agentText);
  const t3 = await waitCtx(page, (t) => t.includes("50 x 25 mm"));
  check("an external change to the file reloads the editor", /50 x 25 mm, extruded 6 mm/.test(t3), t3.split("\n")[1]);
  await page.waitForTimeout(2500);
  check("reloading from disk does not write back", (await page.evaluate(() => window.H.writes.length)) === before);
  await page.screenshot({ path: `${OUT}/fake-reloaded.png` });
  await page.close();
}

// ---- 4b. a featuretree .ir.json opens read-only, and says what it left out --
{
  const ir = {
    name: "block",
    features: [
      { kind: "sketch", name: "profile", plane: "XY", on: null, circles: [], rects: [[60, 40, 0, 0]], polys: [] },
      { kind: "pad", name: "body", sketch: "profile", length: 20, symmetric: false },
      { kind: "sketch", name: "drill_sk", plane: "XY", on: null, circles: [[-20, 0, 3]], rects: [], polys: [] },
      { kind: "pocket", name: "drill", sketch: "drill_sk", through: true, length: null },
      { kind: "sketch", name: "recess_sk", plane: "XY", on: { face_of: "body", side: "top" }, circles: [], rects: [[20, 16, 10, 0]], polys: [] },
      { kind: "pocket", name: "recess", sketch: "recess_sk", through: false, length: 6 },
      { kind: "fillet", name: "soften", radius: 1, select: { circles: "top_outer" } },
    ],
  };
  const page = await newHost(`window.H.openFile("block.ir.json", ${JSON.stringify(JSON.stringify(ir))})`);
  const text = await waitCtx(page, (t) => t.includes("soften"));
  check("a feature tree opens as a body with its hole", /block: closed profile, 4 vertices, 60 x 40 mm, extruded 20 mm, 1 hole/.test(text), text.split("\n")[1]);
  check("its blind pocket is a cut feature on the body", /recess: closed profile, 4 vertices, 20 x 16 mm, extruded 6 mm.*difference feature on a face of block/.test(text), text.split("\n")[2]);
  check("the model is told which features are not shown", /soften \(fillet\)/.test(text), text.split("\n").pop());
  await page.waitForTimeout(2500);
  check("a feature tree is never written", (await page.evaluate(() => window.H.writes.length)) === 0);
  await page.screenshot({ path: `${OUT}/fake-ir.png` });
  await page.close();
}

// ---- 4. a .dxf opens read-only ---------------------------------------------
{
  const dxf = "0\nSECTION\n2\nENTITIES\n0\nLWPOLYLINE\n90\n4\n70\n1\n10\n0\n20\n0\n10\n50\n20\n0\n10\n50\n20\n25\n10\n0\n20\n25\n0\nCIRCLE\n10\n25\n20\n12.5\n40\n4\n0\nENDSEC\n0\nEOF\n";
  const page = await newHost(`window.H.openFile("gasket.dxf", ${JSON.stringify(dxf)})`);
  const text = await waitCtx(page, (t) => t.includes("gasket"));
  check("a .dxf file opens in the editor", /gasket: closed profile, 4 vertices, 50 x 25 mm.*1 hole/.test(text), text.split("\n")[1]);
  await page.waitForTimeout(2500);
  check("a .dxf is never written", (await page.evaluate(() => window.H.writes.length)) === 0);
  await page.close();
}

// ---- 5. live tools: the model edits the open file through the editor --------
{
  const page = await newHost(`window.H.openFile("plate.cadsketch", ${JSON.stringify(FILE_TEXT)})`);
  await waitCtx(page, (t) => t.includes("plate"));
  const call = (name, args) => page.evaluate(([n, a]) => window.H.callTool(n, a), [name, args]);

  const listed = await page.evaluate(() => window.H.request("tools/list", {}));
  const names = (listed.tools ?? []).map((t) => t.name);
  const expected = ["get_sketch", "replace_parts", "add_part", "delete_part", "select_part", "set_depth", "add_hole", "move_hole", "remove_hole", "move_vertex", "set_dimension", "add_constraint", "remove_constraint", "undo", "redo", "fit_view", "screenshot", "export_stl"];
  check("the mounted editor publishes its tools to the model", expected.every((n) => names.includes(n)), `${names.length} tools`);
  check("every published tool has a description and an input schema", (listed.tools ?? []).every((t) => t.description && t.inputSchema?.type === "object"));

  const sketch = await call("get_sketch");
  const p0 = sketch.structuredContent?.parts?.[0];
  check("get_sketch returns edges the model can address", p0?.edges?.length === 4 && p0?.name === "plate", sketch.content?.[0]?.text?.split("\n")[0]);

  const writesBefore = await page.evaluate(() => window.H.writes.length);
  const holed = await call("add_hole", { center: [60, 20], radius: 2.25 });
  check("add_hole edits the live sketch", holed.structuredContent?.part?.holes?.length === 2 && !holed.isError, holed.content?.[0]?.text?.split("\n")[0]);
  const t0 = Date.now();
  while (Date.now() - t0 < 12000 && (await page.evaluate(() => window.H.writes.length)) === writesBefore) await page.waitForTimeout(300);
  const lastWrite = await page.evaluate(() => window.H.writes.at(-1)?.text);
  check("a tool edit is saved to the open file, like a hand edit", !!lastWrite && JSON.parse(lastWrite).parts[0].holes.length === 2);

  const long = p0.edges.find((e) => e.length === 80).edge;
  const dim = await call("set_dimension", { edge: long, length: 95 });
  const driven = dim.structuredContent?.part?.edges?.find((e) => e.edge === long);
  check("set_dimension drives an edge to an exact length", Math.abs((driven?.length ?? 0) - 95) < 0.05 && driven?.driving === 95, `edge ${long}: ${driven?.length} mm`);

  const w = dim.structuredContent?.part?.edges?.map((e) => e.length).sort((a, b) => a - b) ?? [];
  check("a driven rectangle stays a rectangle (95 x 40), it does not skew", w.length === 4 && Math.abs(w[0] - 40) < 0.05 && Math.abs(w[1] - 40) < 0.05 && Math.abs(w[2] - 95) < 0.05 && Math.abs(w[3] - 95) < 0.05, w.join(", "));

  const baseline = dim.structuredContent?.part?.constraintList?.length ?? -1;
  const opposite = (long + 2) % 4;
  const con = await call("add_constraint", { kind: "equal", edges: [long, opposite] });
  check("add_constraint records design intent", con.structuredContent?.part?.constraintList?.length === baseline + 1, `${baseline} + 1`);
  const undone = await call("undo");
  check("undo reverts the last tool edit", undone.structuredContent?.parts?.[0]?.constraintList?.length === baseline, undone.content?.[0]?.text?.split("\n")[0]);

  const bad = await call("move_vertex", { vertex: 99, to: [0, 0] });
  check("a wrong index comes back as an instruction", bad.isError === true && /index from 0 to 3/.test(bad.content?.[0]?.text ?? ""), bad.content?.[0]?.text);

  const shot = await call("screenshot");
  const img = shot.content?.find((c) => c.type === "image");
  check("screenshot returns a PNG of the editor", !!img && img.mimeType === "image/png" && img.data.startsWith("iVBOR") && img.data.length > 8000, img ? `${Math.round(img.data.length / 1024)} kB base64` : "no image");
  if (img) await writeFile(`${OUT}/fake-tool-screenshot.png`, Buffer.from(img.data, "base64"));

  const stl = await call("export_stl");
  const sc = await page.evaluate(() => window.H.serverCalls);
  check("export_stl saves next to the open file via the local server", !stl.isError && /Saved \/workspace\/plate\.stl/.test(stl.content?.[0]?.text ?? "") && sc.at(-1)?.fileName === "plate.stl" && sc.at(-1)?.bytes > 1000, stl.content?.[0]?.text);
  await page.close();
}

// ---- 6. sidebar / thread entrypoint: empty canvas ----------------------------
{
  const page = await newHost("void 0");
  const text = await waitCtx(page, (t) => t.includes("CADSketch canvas"));
  check("sidebar entry opens an empty canvas and reports it", /CADSketch canvas: 1 part/.test(text) && text.includes("empty"), text.replace(/\n/g, " | "));
  const stage = await page.frameLocator("iframe").locator("#app").boundingBox();
  check("editor fills the host's fixed-height container", !!stage && stage.height > 600, stage ? `${Math.round(stage.height)} px` : "no box");
  // No file open: the model draws straight into the sidebar canvas, and an
  // export is offered as a download.
  const call = (name, args) => page.evaluate(([n, a]) => window.H.callTool(n, a), [name, args]);
  const drawn = await call("replace_parts", { parts: [{ name: "tab", depth: 3, profile: [[0, 0], [30, 0], [30, 12], [0, 12]], holes: [[6, 6, 1.7]] }] });
  check("replace_parts draws into the open sidebar canvas", drawn.structuredContent?.parts?.[0]?.name === "tab" && !drawn.isError);
  const t5 = await waitCtx(page, (t) => t.includes("tab"));
  check("the model's context follows its own edit", /tab: closed profile, 4 vertices, 30 x 12 mm/.test(t5), t5.split("\n")[1]);
  const dl = await call("export_stl");
  const downloads = await page.evaluate(() => window.H.downloads);
  check("with no file open, export_stl is offered as a download", !dl.isError && downloads[0] === "file:///tab.stl", dl.content?.[0]?.text);
  await page.close();
}

// ---- 7. the server's relayed tools: what Codex's model actually calls ---------
{
  const page = await newHost("window.H.relayOn = true");
  await waitCtx(page, (t) => t.includes("CADSketch canvas"));
  const relay = (tool, args) => page.evaluate(([t, a]) => window.H.relay(t, a), [tool, args]);
  const drawn = await relay("replace_parts", { parts: [{ name: "plate", depth: 4, profile: [[0, 0], [80, 0], [80, 40], [0, 40]], holes: [[20, 20, 3]] }] });
  check("a relayed tool call runs in the open editor", !drawn.isError && drawn.structuredContent?.parts?.[0]?.name === "plate", drawn.content?.[0]?.text?.split("\n")[0]);
  const faces = await relay("list_faces", {});
  check("list_faces names the top, bottom and four sides", faces.structuredContent?.part?.faces?.length === 6, JSON.stringify(faces.structuredContent?.part?.faces?.[2]?.face));
  const lug = await relay("sketch_on_face", { face: "top", operation: "boss", depth: 6, rect: [10, 8, 60, 30], name: "lug" });
  check("sketch_on_face adds a boss on the top face", !lug.isError && lug.structuredContent?.part?.face === "top" && !lug.structuredContent?.warning, lug.content?.[0]?.text?.split("\n")[0]);
  const slot = await relay("sketch_on_face", { part: "plate", face: { edge: 1 }, operation: "cut", depth: 3, circle: [0, 0, 1.2], name: "port" });
  check("sketch_on_face cuts into a side face", !slot.isError && slot.structuredContent?.part?.face === "side", slot.content?.[0]?.text?.split("\n")[0]);
  const t7 = await waitCtx(page, (t) => t.includes("port"));
  check("the model's context shows the features on their body", /lug: .*union feature on a face of plate/.test(t7) && /port: .*difference feature on a face of plate/.test(t7), t7.split("\n").slice(2).join(" | "));
  const shot = await relay("screenshot", {});
  check("a relayed screenshot comes back as an image", shot.content?.[0]?.type === "image" && shot.content[0].data.length > 5000);
  const bad = await relay("sketch_on_face", { face: "front", operation: "cut", depth: 1, circle: [0, 0, 1] });
  check("a relayed mistake comes back as an instruction", bad.isError === true && /"top", "bottom"/.test(bad.content?.[0]?.text ?? ""), bad.content?.[0]?.text);
  await relay("select_part", { part: "plate" });
  await page.waitForTimeout(800);
  await page.screenshot({ path: `${OUT}/fake-faces.png` });
  await page.close();
}

await browser.close();
console.log(`\n${results.filter(Boolean).length}/${results.length} checks passed; ${errors.length} page errors`);
for (const e of [...new Set(errors)].slice(0, 6)) console.log("  error:", e);
process.exit(results.every(Boolean) ? 0 : 1);
