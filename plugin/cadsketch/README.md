# CADSketch plugin for Codex and ChatGPT

Puts the CADSketch editor inside the Codex / ChatGPT desktop app:

| Where | What you get |
| --- | --- |
| Sidebar | **CADSketch** opens the editor as a full tab, next to a conversation. |
| Thread | Open the editor as a panel beside the conversation you are in. |
| Files | `.cadsketch`, `.dxf` and featuretree `.ir.json` files in your workspace open in the editor. `.cadsketch` edits save back to the file, and the editor reloads when the agent changes it. The other two open read-only. |
| Agent | The agent works in the sketch you have open: it reads the canvas, moves vertices, adds holes, sketches bosses and pockets on faces, sets driving dimensions and constraints, undoes, takes a screenshot, and exports STL. Plus `draw_parts`, and the `cadsketch` skill that teaches it the workflow. |

## Install

Needs Node.js 18 or later and a recent Codex (tested with 0.157). Node is needed because the
app runs the plugin's server on your machine; that server is one bundled file
with no dependencies to install. Nothing to build: `dist/` is
committed.

```sh
# from a clone of this repository
codex plugin marketplace add /path/to/cadsketch
codex plugin add cadsketch@cadsketch
```

Then restart the desktop app. To update after pulling: `codex plugin remove
cadsketch@cadsketch`, then `codex plugin add cadsketch@cadsketch`.

## Try it

- Click **CADSketch** in the sidebar and sketch a shape.
- Ask: *"Create bracket.cadsketch for a 60 × 30 mm L-bracket, 5 mm thick, with
  three M4 holes"*, then open the file.
- Drag a corner in the editor, then ask *"what changed in bracket.cadsketch?"*
- With the file open: *"make it 95 mm wide, add an M4 hole 8 mm in from each
  corner, and export an STL."*

## What is in here

- `.codex-plugin/plugin.json` — the manifest.
- `.mcp.json` — launches `dist/server.mjs` (a single bundled file) over stdio.
- `dist/widget.html` — the page the app renders; it frames `cadsketch.ai/app`.
- `skills/cadsketch/SKILL.md` — teaches the agent the part format and workflow.

Source and tests are in `../../mcp`. `dist/` is produced by `npm run build` there.
