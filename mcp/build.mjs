// Builds two things:
//
//   dist/                      the server for `npm start` and the tests
//                              (deps stay in node_modules)
//   ../plugin/cadsketch/dist/  the installable Codex / ChatGPT plugin: ONE
//                              bundled stdio server + the widget + the icon.
//                              Needs Node, but no `npm install`.
//
// The widget is a single self-contained HTML file in both.
import { build } from "esbuild";
import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";

const PLUGIN_DIST = "../plugin/cadsketch/dist";
await mkdir("dist", { recursive: true });
await mkdir(PLUGIN_DIST, { recursive: true });

// --- widget ------------------------------------------------------------------
const shell = await build({
  entryPoints: ["widget/shell.ts"],
  bundle: true,
  format: "iife",
  target: "es2020",
  minify: true,
  write: false,
});
const js = shell.outputFiles[0].text.replaceAll("</script", "<\\/script");
const html = (await readFile("widget/shell.html", "utf-8")).replace("/*%%SHELL_JS%%*/", () => js);

// --- server, unbundled (dev / droplet / tests) -------------------------------
await build({
  entryPoints: ["src/main.ts", "src/stdio.ts", "src/server.ts", "src/geometry.ts", "src/assets.ts", "widget/file-sync.ts"],
  outdir: "dist",
  outbase: ".",
  platform: "node",
  format: "esm",
  target: "node22",
  bundle: false,
});
// main.js etc. land in dist/src; keep the entry points at dist/ root.
for (const name of ["main", "stdio", "server", "geometry", "assets"]) {
  await copyFile(`dist/src/${name}.js`, `dist/${name}.js`);
}
await copyFile("dist/widget/file-sync.js", "dist/file-sync.js");
await writeFile("dist/widget.html", html);
await copyFile("widget/icon.svg", "dist/icon.svg");

// --- plugin: one bundled stdio server -----------------------------------------
await build({
  entryPoints: ["src/stdio.ts"],
  outfile: `${PLUGIN_DIST}/server.js`,
  platform: "node",
  format: "esm",
  target: "node22",
  bundle: true,
  minify: false,
  legalComments: "none",
  // Some dependencies are CommonJS and call require() for Node built-ins.
  banner: { js: "import { createRequire as __createRequire } from 'node:module';\nconst require = __createRequire(import.meta.url);" },
});
await writeFile(`${PLUGIN_DIST}/widget.html`, html);
await copyFile("widget/icon.svg", `${PLUGIN_DIST}/icon.svg`);

console.log(`built dist/ and ${PLUGIN_DIST}/ (widget ${(html.length / 1024).toFixed(0)} kB)`);
