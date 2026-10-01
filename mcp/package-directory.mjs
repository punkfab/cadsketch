// Builds the ZIP for OpenAI's plugin directory (platform.openai.com/plugins),
// and checks it against every limit the submission portal enforces, so a
// mistake fails here rather than after an upload.
//
//   node package-directory.mjs [--demo-url https://...]
//
// The directory version differs from the local plugin in three ways:
//   * its MCP server is the REMOTE one (plugin/directory/listing.json: mcpUrl),
//     because the directory does not accept a bundled local server;
//   * its starter prompts are ones that work from a cold start, each with a
//     screenshot (plugin/directory/screenshots/);
//   * it carries the review test cases and release notes.
// Everything else (skills, icons, descriptions) is the local plugin's.
import { execFileSync } from "node:child_process";
import { cp, mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const pluginDir = path.join(here, "../plugin/cadsketch");
const directoryDir = path.join(here, "../plugin/directory");
const demoUrl = process.argv.includes("--demo-url") ? process.argv[process.argv.indexOf("--demo-url") + 1] : null;

const manifest = JSON.parse(await readFile(path.join(pluginDir, ".codex-plugin/plugin.json"), "utf8"));
const listing = JSON.parse(await readFile(path.join(directoryDir, "listing.json"), "utf8"));

// ---- assemble the directory manifest ----------------------------------------
manifest.interface.defaultPrompt = listing.prompts.map((p) => p.prompt);
manifest.interface.screenshots = listing.prompts.map((p) => `./assets/${p.screenshot}`);
manifest.mcpServers = "./.mcp.json";
manifest.extensions = {
  "com.openai": {
    review: { ...listing.review, ...(demoUrl ? { demo_recording_url: demoUrl } : {}) },
    publication: { release_notes: listing.release_notes },
  },
};
const mcp = { mcpServers: { cadsketch: { url: listing.mcpUrl } } };

// ---- checks (the portal's own limits) ---------------------------------------
const problems = [];
const warn = [];
const must = (ok, message) => ok || problems.push(message);
const i = manifest.interface;
const CATEGORIES = ["Productivity", "Creativity", "Developer Tools", "Business & Operations", "Data & Analytics", "Communication", "Education & Research", "Security", "Finance", "Healthcare", "Travel", "Entertainment", "Other"];

must(/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(manifest.name), "name: letters, digits, _ or -, at most 64 characters");
must(/^\d+\.\d+\.\d+$/.test(manifest.version), "version: must be semantic, like 1.0.0");
must(manifest.description?.length > 0 && manifest.description.length <= 1024, "description: 1 to 1024 characters");
must(manifest.author?.name?.length > 0 && manifest.author.name.length <= 120, "author.name: 1 to 120 characters");
must(i.displayName?.length > 0 && i.displayName.length <= 30, `displayName: at most 30 characters (is ${i.displayName?.length})`);
must(i.shortDescription?.length > 0 && i.shortDescription.length <= 30, `shortDescription: at most 30 characters (is ${i.shortDescription?.length})`);
must(i.longDescription?.length > 0 && i.longDescription.length <= 4000, "longDescription: 1 to 4000 characters");
must(i.developerName?.length > 0 && i.developerName.length <= 80, "developerName: 1 to 80 characters");
must(CATEGORIES.includes(i.category), `category: must be one of ${CATEGORIES.join(", ")}`);
must(Array.isArray(i.capabilities) && i.capabilities.length <= 20 && i.capabilities.every((c) => c && c.length <= 120), "capabilities: at most 20, each 1 to 120 characters");
for (const key of ["websiteURL", "supportURL", "privacyPolicyURL", "termsOfServiceURL"]) {
  must(typeof i[key] === "string" && i[key].startsWith("https://") && i[key].length <= 1024, `${key}: required, HTTPS, at most 1024 characters`);
}
must(i.defaultPrompt.length <= 3, "defaultPrompt: at most 3");
must(new Set(i.defaultPrompt.map((p) => p.trim().toLowerCase())).size === i.defaultPrompt.length, "defaultPrompt: must be unique");
for (const p of i.defaultPrompt) must(p.length <= 128 && !p.includes("@"), `defaultPrompt: at most 128 characters and no @mentions ("${p.slice(0, 40)}…" is ${p.length})`);
must(/^#[0-9A-Fa-f]{6}$/.test(i.brandColor ?? ""), "brandColor: #RRGGBB");

const luminance = (hex) => {
  const [r, g, b] = [1, 3, 5].map((k) => parseInt(hex.slice(k, k + 2), 16) / 255).map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};
const contrast = (a, b) => (Math.max(luminance(a), luminance(b)) + 0.05) / (Math.min(luminance(a), luminance(b)) + 0.05);
if (i.brandColor) must(contrast(i.brandColor, "#FFFFFF") >= 2, "brandColor: needs 2:1 contrast against white");
if (i.brandColorDark) must(contrast(i.brandColorDark, "#212121") >= 2, "brandColorDark: needs 2:1 contrast against #212121");

async function checkSvg(key) {
  const rel = i[key];
  if (!rel) return;
  must(rel.startsWith("./"), `${key}: path must start with ./`);
  const text = await readFile(path.join(pluginDir, rel), "utf8").catch(() => null);
  if (text === null) return void problems.push(`${key}: ${rel} does not exist`);
  const box = text.match(/viewBox="\s*[\d.]+\s+[\d.]+\s+([\d.]+)\s+([\d.]+)\s*"/);
  must(box && box[1] === box[2] && Number(box[1]) >= 48, `${key}: SVG needs a square viewBox of at least 48 (${rel})`);
}
must(i.logo, "logo: required");
must(i.composerIcon, "composerIcon: required");
for (const key of ["logo", "logoDark", "composerIcon", "composerIconDark"]) await checkSvg(key);

// PNG size straight from the header: width at bytes 16-19, height 20-23.
for (const p of listing.prompts) {
  const file = path.join(directoryDir, "screenshots", p.screenshot);
  const bytes = await readFile(file).catch(() => null);
  if (!bytes) {
    problems.push(`screenshot ${p.screenshot} is missing: run e2e/screenshots.mjs`);
    continue;
  }
  const [w, h] = [bytes.readUInt32BE(16), bytes.readUInt32BE(20)];
  must(w === 706 && h >= 400 && h <= 860, `screenshot ${p.screenshot}: must be 706 px wide and 400 to 860 px tall (is ${w} x ${h})`);
  must(bytes.length <= 5 * 1024 * 1024, `screenshot ${p.screenshot}: at most 5 MiB`);
}

const cases = manifest.extensions["com.openai"].review.test_cases;
must(cases.positive.length === 5, `test cases: exactly 5 positive (have ${cases.positive.length})`);
must(cases.negative.length === 3, `test cases: exactly 3 negative (have ${cases.negative.length})`);
for (const c of cases.positive) must(c.description && c.prompt && c.tools_triggered && c.expected_behavior && c.description.length <= 4000, "positive test case: needs description, prompt, tools_triggered, expected_behavior");
for (const c of cases.negative) must(c.description && c.prompt, "negative test case: needs description and prompt");
must(/^https:\/\/[^/]+\/mcp$/.test(listing.mcpUrl), "mcpUrl: must be the production HTTPS /mcp endpoint");
if (!demoUrl) warn.push("No --demo-url given: add the walkthrough video URL in the portal, or rebuild with --demo-url once it is recorded.");

const skill = await readFile(path.join(pluginDir, "skills/cadsketch/SKILL.md"), "utf8");
const front = skill.match(/^---\n([\s\S]*?)\n---\n/);
must(front, "skill: SKILL.md needs YAML front matter");
const skillDescription = front?.[1].match(/^description: (.*)$/m)?.[1] ?? "";
must(skillDescription.length > 0 && skillDescription.length <= 1024, `skill description: 1 to 1024 characters (is ${skillDescription.length})`);
must(`${manifest.name}:cadsketch`.length <= 64, "skill identity: plugin-name:skill-name at most 64 characters");

// Is the production endpoint actually serving what the listing describes?
try {
  const res = await fetch(listing.mcpUrl.replace(/\/mcp$/, "/"), { signal: AbortSignal.timeout(8000) });
  if (!res.ok) warn.push(`${listing.mcpUrl} answered ${res.status}. The portal's tool scan needs it reachable.`);
} catch {
  warn.push(`${listing.mcpUrl} is not reachable yet (DNS for the hostname?). The portal's domain check and tool scan need it.`);
}

if (problems.length) {
  console.error("Not packaged. Fix these first:\n" + problems.map((p) => "  - " + p).join("\n"));
  process.exit(1);
}

// ---- stage and zip ----------------------------------------------------------
const stage = path.join(here, "dist/directory/cadsketch");
const zip = path.join(here, `dist/cadsketch-plugin-${manifest.version}.zip`);
await rm(path.join(here, "dist/directory"), { recursive: true, force: true });
await rm(zip, { force: true });
await mkdir(path.join(stage, ".codex-plugin"), { recursive: true });
await writeFile(path.join(stage, ".codex-plugin/plugin.json"), JSON.stringify(manifest, null, 2) + "\n");
await writeFile(path.join(stage, ".mcp.json"), JSON.stringify(mcp, null, 2) + "\n");
await cp(path.join(pluginDir, "skills"), path.join(stage, "skills"), { recursive: true });
await cp(path.join(pluginDir, "assets"), path.join(stage, "assets"), { recursive: true });
for (const p of listing.prompts) await cp(path.join(directoryDir, "screenshots", p.screenshot), path.join(stage, "assets", p.screenshot));
// No dist/ (the local server), no .app.json, no hooks: the directory rejects them.
execFileSync("zip", ["-q", "-r", "-X", zip, "."], { cwd: stage });

const entries = execFileSync("unzip", ["-Z1", zip]).toString().trim().split("\n");
console.log(`${path.relative(process.cwd(), zip)}  (${((await stat(zip)).size / 1024).toFixed(0)} kB, ${entries.length} entries)`);
for (const e of entries.filter((e) => !e.endsWith("/"))) console.log("  " + e);
for (const w of warn) console.log("\nNote: " + w);
