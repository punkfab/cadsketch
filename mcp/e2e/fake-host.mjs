// A stand-in for the Codex / ChatGPT desktop host: speaks the MCP Apps protocol
// plus OpenAI's file-resource extension to the CADSketch widget, so the file
// viewer flow can be tested without the desktop app.
//
//   node fake-host.mjs <widget.html> <app-url> [sandbox-attr]
import { chromium } from "playwright-core";
import { readFile, writeFile } from "node:fs/promises";

const [widgetPath, appUrl, sandbox = "allow-scripts allow-same-origin"] = process.argv.slice(2);
const OUT = process.env.OUT ?? ".";
const widgetHtml = (await readFile(widgetPath, "utf8")).replaceAll("%%APP_URL%%", appUrl);

const FILE_TEXT = JSON.stringify({
  cadsketch: 1,
  units: "mm",
  parts: [{ name: "plate", depth: 4, profile: [[0, 0], [80, 0], [80, 40], [0, 40]], holes: [[20, 20, 3]] }],
});

// Runs in the page: the host side of the JSON-RPC channel.
function hostScript(widgetHtml, sandbox, prepare) {
  const H = (window.H = { log: [], files: {}, etag: 1, context: null, writes: [], reads: 0, subscribed: [] });
  const frame = document.createElement("iframe");
  frame.setAttribute("sandbox", sandbox);
  frame.style.cssText = "width:1180px;height:720px;border:0";
  document.body.style.margin = "0";
  document.body.appendChild(frame);
  const send = (msg) => frame.contentWindow.postMessage({ jsonrpc: "2.0", ...msg }, "*");
  H.notify = (method, params) => send({ method, params });
  H.openFile = (name, text) => {
    H.files["host-resource://" + name] = { name, text, etag: "v" + H.etag++ };
    H.pendingFile = { name, resourceUri: "host-resource://" + name };
  };
  H.changeOnDisk = (uri, text) => {
    H.files[uri].text = text;
    H.files[uri].etag = "v" + H.etag++;
    H.notify("notifications/resources/updated", { uri });
  };
  window.addEventListener("message", (e) => {
    if (e.source !== frame.contentWindow) return;
    const m = e.data;
    if (!m || m.jsonrpc !== "2.0" || !m.method) return;
    H.log.push(m.method);
    const reply = (result) => m.id !== undefined && send({ id: m.id, result });
    const fail = (message) => send({ id: m.id, error: { code: -32000, message } });
    switch (m.method) {
      case "ui/initialize":
        return reply({
          protocolVersion: "2026-01-26",
          hostInfo: { name: "fake-codex", version: "0.0.1" },
          hostCapabilities: {
            experimental: { "openai/resource": {}, "openai/modelContext": {}, "openai/message": {} },
            updateModelContext: { text: {}, structuredContent: {} },
            message: { text: {} },
            serverResources: {},
            openLinks: {},
            logging: {},
          },
          hostContext: {
            theme: "dark",
            displayMode: "fullscreen",
            availableDisplayModes: ["inline", "fullscreen"],
            containerDimensions: { width: 1180, height: 720 },
            platform: "desktop",
          },
        });
      case "ui/notifications/initialized":
        if (H.pendingFile) {
          H.notify("ui/notifications/tool-input", { arguments: { file: H.pendingFile } });
          H.notify("ui/notifications/tool-result", { content: [{ type: "text", text: "Opened." }], structuredContent: { file: H.pendingFile } });
        } else {
          H.notify("ui/notifications/tool-input", { arguments: {} });
          H.notify("ui/notifications/tool-result", { content: [], structuredContent: { parts: [] } });
        }
        return;
      case "resources/read": {
        const f = H.files[m.params.uri];
        if (!f) return fail("no such resource");
        H.reads++;
        H.lastReadMeta = m.params._meta;
        return reply({ contents: [{ uri: m.params.uri, mimeType: "text/plain", text: f.text, _meta: { "openai/resource": { etag: f.etag, writable: !f.name.endsWith(".dxf") } } }] });
      }
      case "resources/subscribe":
        H.subscribed.push(m.params.uri);
        return reply({});
      case "resources/unsubscribe":
        return reply({});
      case "openai/resources/write": {
        const f = H.files[m.params.uri];
        if (!f) return fail("no such resource");
        if (m.params.ifMatch && m.params.ifMatch !== f.etag) return reply({ outcome: "conflict", etag: f.etag });
        f.text = m.params.text;
        f.etag = "v" + H.etag++;
        H.writes.push({ uri: m.params.uri, ifMatch: m.params.ifMatch, text: m.params.text });
        reply({ outcome: "saved", etag: f.etag });
        // A real host also notifies subscribers that the file changed.
        return H.notify("notifications/resources/updated", { uri: m.params.uri });
      }
      case "ui/update-model-context":
        H.context = m.params;
        return reply({ _meta: { "openai/modelContext": { updateId: "u" + Date.now() } } });
      case "ping":
        return reply({});
      default:
        if (m.id !== undefined) reply({});
    }
  });
  new Function(prepare)(); // register the file BEFORE the widget boots
  frame.srcdoc = widgetHtml;
}

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

// ---- 5. sidebar / thread entrypoint: empty canvas ----------------------------
{
  const page = await newHost("void 0");
  const text = await waitCtx(page, (t) => t.includes("CADSketch canvas"));
  check("sidebar entry opens an empty canvas and reports it", /CADSketch canvas: 1 part/.test(text) && text.includes("empty"), text.replace(/\n/g, " | "));
  const stage = await page.frameLocator("iframe").locator("#app").boundingBox();
  check("editor fills the host's fixed-height container", !!stage && stage.height > 600, stage ? `${Math.round(stage.height)} px` : "no box");
  await page.close();
}

await browser.close();
console.log(`\n${results.filter(Boolean).length}/${results.length} checks passed; ${errors.length} page errors`);
for (const e of [...new Set(errors)].slice(0, 6)) console.log("  error:", e);
process.exit(results.every(Boolean) ? 0 : 1);
