// Builds dist/: the server (deps left in node_modules) and the single-file
// widget (shell script bundled and inlined into shell.html).
import { build } from "esbuild";
import { mkdir, readFile, writeFile } from "node:fs/promises";

await mkdir("dist", { recursive: true });

await build({
  entryPoints: ["src/main.ts", "src/server.ts", "src/geometry.ts"],
  outdir: "dist",
  platform: "node",
  format: "esm",
  target: "node20",
  bundle: false,
});

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
await writeFile("dist/widget.html", html);

console.log(`built dist/ (widget ${(html.length / 1024).toFixed(0)} kB)`);
