// Generates the store screenshots: one per starter prompt, showing the editor
// with the part that prompt produces. The directory requires PNG/JPEG, 706 px
// wide and 400 to 860 px tall, one per prompt.
//
//   node e2e/screenshots.mjs <widget.html> <app-url>
//
// The parts come from plugin/directory/listing.json, next to their prompts, so
// a screenshot can't drift from the prompt it illustrates.
import { chromium } from "playwright-core";
import { mkdir, readFile } from "node:fs/promises";
import { hostScript } from "./host.mjs";

const [widgetPath, appUrl] = process.argv.slice(2);
const SIZE = { width: 706, height: 560 };
const listing = JSON.parse(await readFile(new URL("../../plugin/directory/listing.json", import.meta.url), "utf8"));
const outDir = new URL("../../plugin/directory/screenshots/", import.meta.url);
await mkdir(outDir, { recursive: true });
const widgetHtml = (await readFile(widgetPath, "utf8")).replaceAll("%%APP_URL%%", appUrl);

const browser = await chromium.launch({ channel: "chrome", headless: true, args: ["--no-sandbox", "--use-gl=swiftshader", "--enable-unsafe-swiftshader"] });
for (const item of listing.prompts) {
  const page = await browser.newPage({ viewport: SIZE, deviceScaleFactor: 1 });
  await page.setContent('<body style="margin:0;background:#0F2747"></body>');
  await page.evaluate(`(${hostScript.toString()})(${JSON.stringify(widgetHtml)}, "allow-scripts allow-same-origin", "void 0", ${JSON.stringify(SIZE)})`);
  // Draw the part the way the model would, through the editor's own tool.
  const result = await page.evaluate((parts) => window.H.callTool("replace_parts", { parts }), item.parts);
  if (result.isError) throw new Error(`${item.screenshot}: ${result.content?.[0]?.text}`);
  const t0 = Date.now();
  while (Date.now() - t0 < 30000) {
    const text = await page.evaluate(() => window.H.context?.content?.[0]?.text ?? "");
    if (text.includes(item.parts[0].name)) break;
    await page.waitForTimeout(400);
  }
  await page.waitForTimeout(1500); // let the fit and the 3D view settle
  const file = new URL(item.screenshot, outDir);
  await page.screenshot({ path: file.pathname, clip: { x: 0, y: 0, ...SIZE } });
  console.log(`${item.screenshot}  ${SIZE.width}x${SIZE.height}  "${item.prompt}"`);
  await page.close();
}
await browser.close();
