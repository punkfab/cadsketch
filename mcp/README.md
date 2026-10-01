# CADSketch inside AI hosts (Codex, ChatGPT, Claude, any MCP Apps host)

This folder makes CADSketch usable *inside* an AI app: the model can draw a part
and have it open in the real editor, files in a workspace open in it, and
whatever the user sketches or edits is visible to the model.

It is the same app. Nothing here forks the editor:

```
 host (Codex / ChatGPT desktop, or a chat host over HTTP)
   │  MCP                      tools: draw_parts, open_sketcher, open_file
   ▼
 mcp/src  ── one stateless server, two entry points ──────────────────────
   │   stdio.ts   launched locally by the plugin   (plugin/cadsketch)
   │   main.ts    Streamable HTTP for remote hosts (the droplet)
   ▼
 widget = mcp/widget/shell.{html,ts}     speaks MCP Apps + OpenAI extensions
   │      └── <iframe>  https://cadsketch.ai/app/?mcp=1   ← the normal Flutter web build
   │   private string messages (lib/mcp/host_bridge_web.dart)
   │      shell → app   load / loadDxf   content to show
   │      app → shell   ready            the editor is up
   │      app → shell   state            what is on the canvas now
   ▼
 the model sees the canvas (ui/update-model-context); an opened .cadsketch file
 is kept in sync both ways
```

- **`lib/mcp/`** (in the Flutter app) — the part format and the bridge. The
  bridge starts only when the page is opened with `?mcp=1`; on iOS, desktop and
  the plain web app `HostBridge.attach` returns null and nothing runs.
- **`mcp/src/`** — the MCP server.
- **`mcp/widget/`** — the shell page the host renders, and the file-sync rules.
  No CAD logic.
- **`plugin/cadsketch/`** — the installable Codex / ChatGPT plugin (built output
  is committed, so it installs from a clone with no build step).

No AI key ships anywhere and the server calls no model: the host's own model
does the thinking.

## Where it shows up

OpenAI's plugin extensions let an MCP App register into the app itself, by
adding `_meta["openai/ui"].entrypoints` to a tool:

| Entrypoint | Tool | Result |
| --- | --- | --- |
| `global` | `open_sketcher` | **CADSketch** in the sidebar, opening as a full tab |
| `thread` | `open_sketcher` | a panel beside the current conversation |
| `file` (`.cadsketch`, `.dxf`) | `open_file` | those files open in the editor |
| (model tool) | `draw_parts` | the agent draws parts inline |

File viewers are desktop-only; sidebar and thread entrypoints also work on the
web. Hosts without the extensions (Claude, plain MCP Apps hosts) ignore the
metadata and still get `draw_parts` and `open_sketcher` as ordinary tools.

### `.cadsketch` files

```json
{ "cadsketch": 1, "units": "mm",
  "parts": [ { "name": "bracket", "depth": 5,
               "profile": [[0,0],[40,0],[40,20],[0,20]],
               "holes": [[8,10,2.25]] } ] }
```

`parts` is exactly the `draw_parts` format, so an agent can write the file with
its ordinary file tools. While a file is open in the editor:

- the host's file is read through `resources/read`, never a raw path;
- a hand edit is written back with `openai/resources/write`, using the etag it
  read, so a concurrent change is a conflict (reload) rather than an overwrite;
- opening a file never rewrites it, and the editor's own save coming back as a
  change notification is recognised and ignored;
- work the format can't hold (an open sketch, a face feature, a mesh) blocks
  saving and says so, instead of being dropped;
- `.dxf` opens read-only.

## The part format

One shape in both directions, so a model can read what is on the canvas, change
a number and send it back. Millimetres, X right, Y up.

```json
{ "name": "bracket", "depth": 5,
  "profile": [[0,0],[60,0],[60,30],[45,30],[45,15],[0,15]],
  "holes":   [[10,7.5,2.25],[35,7.5,2.25]] }
```

A profile vertex may be `[x, y, bulge]`, where bulge = tan(θ/4) of the arc to
the next vertex (positive is counter-clockwise, 1 is a semicircle). A round part
uses `"circle": [cx, cy, r]` instead of a profile. The notation is the
featuretree IR's, and reading parts back out reuses `partToIr`.

`draw_parts` also returns a report per part (size, volume, and warnings such as
a hole outside the outline or a self-crossing profile) so the model can catch
its own mistakes.

## Build and test

```sh
cd mcp
npm install
npm test        # builds, then 15 tests: both transports, the file format, the bundled plugin
npm run dev     # http://localhost:3001/mcp, editor = https://cadsketch.ai/app/
```

`npm run build` also writes `../plugin/cadsketch/dist/`. Commit it: a plugin
installed from Git is not built on the user's machine.

The desktop app's UI can't be run in CI, so `e2e/fake-host.mjs` stands in for
it: a page that speaks the host side of MCP Apps plus OpenAI's file-resource
extension, driven by Playwright against a real Flutter build.

```sh
flutter build web --release --base-href /app/          # from the repo root
mkdir -p /tmp/site && ln -sfn "$PWD/build/web" /tmp/site/app
python3 mcp/e2e/cors-server.py /tmp/site &
cd mcp && node e2e/fake-host.mjs ../plugin/cadsketch/dist/widget.html http://localhost:18091/app/
# add "allow-scripts" as a last argument to test a sandbox with no origin
```

It checks: a file opens and is reported to the model, opening does not rewrite
it, a dragged vertex is saved with the right etag, the save's echo does not
loop, an external change reloads the editor, `.dxf` is never written, and the
sidebar canvas fills its container.

## Install in Codex / ChatGPT desktop

See `plugin/cadsketch/README.md`. In short:

```sh
codex plugin marketplace add /path/to/this/repo
codex plugin add cadsketch@cadsketch
```

## Connect a remote host (ChatGPT connector, Claude)

ChatGPT needs a public HTTPS URL for `/mcp`.

1. Expose the server. It runs on a small droplet behind Caddy (automatic
   HTTPS), deployed with one script from `mcp/`:

   ```sh
   deploy/deploy.sh --setup   # first time: swap, Node 22, Caddy, firewall, service user
   deploy/deploy.sh           # every update: build, copy dist/, restart
   ```

   It answers at `https://mcp.cadsketch.ai/mcp` once that name has an A record
   to the droplet, and at `https://64-23-228-132.sslip.io/mcp` without any DNS.
   The repo is private, so nothing is cloned on the server; only `dist/` and
   the package manifests are copied. Files: `deploy/` (systemd unit, Caddyfile,
   setup). For a throwaway test instead: `npm run dev` plus
   `sudo tailscale funnel 3001`.
2. ChatGPT → Settings → Security and login → enable **Developer mode**.
3. ChatGPT → Plugins → **+** → name "CADSketch", the `/mcp` URL, no auth.
4. In a new chat: *"Use CADSketch to draw a 60 × 30 mm L-bracket, 5 mm thick,
   with three M4 holes."*

After changing tools or the widget: restart the server, press **Refresh** on the
connection, start a new chat.

## What is and isn't known to work

Verified:

- The Codex CLI installs the plugin and a real Codex agent run called
  `draw_parts` through it and reported the right volume.
- In the reference MCP Apps host: tools, widget render, the editor loading a
  model-drawn part, hand edits flowing back as model context.
- In the stand-in host: the whole file viewer flow above, in sandboxes with and
  without an origin.
- In Claude: the tool call and widget render.

**Not yet verified: the editor inside the Codex / ChatGPT desktop app itself.**
The widget frames `cadsketch.ai`, declared in `frameDomains`. If a host refuses
the frame, the panel says so with a reason code and offers the editor in a
browser tab:

| Code | Meaning | Fix |
| --- | --- | --- |
| `frame-blocked` | the host refuses nested frames | load the Flutter build directly in the widget (`window.CADSKETCH_MCP`, already supported by the bridge) |
| `editor-stalled` | the page loaded but its files were refused | CORS on the app; `.do/app.yaml` has the rule and it is live |
| `no-load` | the page never arrived | the host's network policy |

Other limits:

- Arcs drawn by a model are tessellated into short edges on load (the same
  thing the DXF importer does), so they come back as many vertices.
- Face features and imported meshes are reported to the model but cannot be
  drawn by it or saved to a `.cadsketch` file.
- A chat host that re-renders an inline widget replays the model's last
  drawing, so hand edits made after it are not restored. Files don't have this
  problem: the file is the state.

## Publishing to the ChatGPT directory

Needs, beyond a working endpoint: a verified OpenAI organization, logo and
composer icon, website / support / privacy / terms URLs, the domain challenge
(put `OPENAI_APPS_CHALLENGE=...` in `/etc/cadsketch-mcp.env` on the server; it is
served at `/.well-known/openai-apps-challenge`), five positive and three negative test
cases, and a video walkthrough.
