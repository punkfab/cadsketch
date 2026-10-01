# CADSketch as an AI-host app (ChatGPT, Claude, any MCP Apps host)

This folder makes CADSketch usable *inside* a chat: the model can draw a part
and have it open in the real editor, and whatever the user sketches or edits is
visible to the model, which can review it or redraw an improved version.

It is the same app. Nothing here forks the editor:

```
 chat host (ChatGPT / Claude / ...)
   │  MCP over HTTP                       tools: draw_parts, open_sketcher
   ▼
 mcp/  ── this server, stateless ─────────  serves one widget page
   │
   ▼  widget page = mcp/widget/shell.{html,ts}   (speaks MCP Apps via the official SDK)
   │      └── <iframe>  https://cadsketch.ai/app/?mcp=1    ← the normal Flutter web build
   │                         │
   │   three private string messages (lib/mcp/host_bridge_web.dart)
   │      shell → app   load   parts the model drew
   │      app → shell   ready  the editor is up
   │      app → shell   state  what is on the canvas now
   ▼
 the model sees the canvas (ui/update-model-context) and can call draw_parts again
```

- **`lib/mcp/`** (in the Flutter app) — the part format and the bridge. The
  bridge starts only when the page is opened with `?mcp=1`; on iOS, desktop and
  the plain web app `HostBridge.attach` returns null and nothing runs.
- **`mcp/src/`** — the MCP server: two tools and the widget resource.
- **`mcp/widget/`** — the shell page the host renders. No CAD logic.

No AI key ships anywhere and the server calls no model: the host's own model
does the thinking, paid for by the user's subscription to that host.

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

## Run it locally

```sh
cd mcp
npm install
npm test                 # builds, then 8 end-to-end tests over real HTTP
npm run dev              # http://localhost:3001/mcp, editor = https://cadsketch.ai/app/
```

To test against a local Flutter build instead of production:

```sh
flutter build web --release --base-href /app/
# serve build/web at http://localhost:18090/app/ , then
CADSKETCH_APP_URL=http://localhost:18090/app/ npm run dev
```

The reference host from `modelcontextprotocol/ext-apps` (`examples/basic-host`)
renders the widget and shows the model context the editor reports, which is how
this was verified end to end.

## Connect it to ChatGPT (developer mode)

ChatGPT needs a public HTTPS URL for `/mcp`.

1. Expose the server. Temporary: `sudo tailscale funnel 3001` while `npm run dev`
   is running. Permanent: add the service in `do-service.yaml` to the
   DigitalOcean app, which puts it at `https://cadsketch.ai/mcp`.
2. ChatGPT → Settings → Security and login → enable **Developer mode**.
3. ChatGPT → Plugins → **+** → name "CADSketch", the `/mcp` URL, no auth.
4. In a new chat: *"Use CADSketch to draw a 60 × 30 mm L-bracket, 5 mm thick,
   with three M4 holes."*

After changing tools or the widget: restart the server, press **Refresh** on the
connection, start a new chat.

## What is and isn't known to work

- Verified in the reference MCP Apps host: tools, widget render, the editor
  loading a model-drawn part, and hand edits flowing back as model context.
- **Not yet verified in ChatGPT itself.** The widget frames `cadsketch.ai`, which
  is declared in `frameDomains`. If a host refuses nested frames the widget says
  so and offers the editor in a browser tab instead of hanging. The fallback
  design is to load the Flutter build directly into the widget document
  (`window.CADSKETCH_MCP`, already supported by the bridge), which needs the
  host to allow WebAssembly and `cadsketch.ai` to send CORS headers.
- Arcs drawn by a model are tessellated into short edges on load (the same
  thing the DXF importer does), so they come back as many vertices.
- Face features and imported meshes are reported to the model but cannot be
  drawn by it yet; `draw_parts` creates base bodies only.
- A host that re-renders the widget (page reload) replays the model's last
  drawing, so hand edits made after it are not restored.

## Publishing to the ChatGPT directory

Needs, beyond a working endpoint: a verified OpenAI organization, logo and
composer icon, website / support / privacy / terms URLs, the domain challenge
(`OPENAI_APPS_CHALLENGE` env var is served at
`/.well-known/openai-apps-challenge`), five positive and three negative test
cases, and a video walkthrough.
