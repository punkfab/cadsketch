# Submitting CADSketch to OpenAI's plugin directory

The package is built and checked by a script. What is left needs a person:
an OpenAI account, a DNS record, and a screen recording.

## 1. Three things only you can do first

1. **DNS.** At Namecheap, add an A record: host `mcp`, value `64.23.228.132`.
   The server already answers to `mcp.cadsketch.ai` and gets its certificate
   automatically within a minute or two. Check:

   ```sh
   curl https://mcp.cadsketch.ai/        # -> "CADSketch MCP server. Endpoint: /mcp"
   ```

2. **Verify your OpenAI organization.** platform.openai.com → Settings →
   Organization → verification (individual or business). The developer name on
   the listing comes from this, so use the name you want shown.

3. **Record the walkthrough** (2 to 4 minutes, any screen recorder, upload
   somewhere a reviewer can open without signing in, e.g. an unlisted YouTube
   video). Show the five positive test cases in order, in ChatGPT with the
   plugin connected:

   1. "Draw a 60 x 30 mm L-bracket, 5 mm thick, with three M4 holes." Let the
      editor appear; drag one corner so it is clear the part is editable.
   2. "Design an 80 x 40 mm mounting plate, 4 mm thick, with an M4 hole 8 mm in
      from each corner."
   3. "Open CADSketch so I can sketch a part myself." Draw a rough rectangle and
      a circle inside it; show it snapping and extruding.
   4. "Check this design before I make it: a 40 x 20 mm plate, 5 mm thick, with
      a 3 mm radius hole centred 2 mm from the short edge." No editor opens; the
      assistant reports the hole breaks through the edge.
   5. Back in the L-bracket chat: "Make it 8 mm thick and change the holes to M5."

   Then one negative case: "What is the tensile strength of 6061-T6 aluminium?"
   answered without CADSketch.

## 2. Build the package

```sh
cd mcp
node package-directory.mjs --demo-url "https://…your video…"
# -> dist/cadsketch-plugin-<version>.zip
```

The script refuses to build if anything breaks a portal limit (name lengths,
icon sizes, screenshot dimensions, five positive and three negative test cases,
HTTPS URLs) and warns if the production server is not reachable.

To regenerate the screenshots after the editor's look changes:

```sh
flutter build web --release --base-href /app/      # repo root
mkdir -p /tmp/site && ln -sfn "$PWD/build/web" /tmp/site/app
python3 mcp/e2e/cors-server.py /tmp/site &
cd mcp && node e2e/screenshots.mjs ../plugin/cadsketch/dist/widget.html http://localhost:18091/app/
```

## 3. Submit

At https://platform.openai.com/plugins :

1. **Upload** the ZIP. Choose **With MCP** (not skills-only).
2. **Connect the MCP server.** URL `https://mcp.cadsketch.ai/mcp`,
   authentication: none.
3. **Domain verification.** The portal shows a token. Put it on the server:

   ```sh
   ssh root@64.23.228.132 "echo 'OPENAI_APPS_CHALLENGE=PASTE_TOKEN_HERE' > /etc/cadsketch-mcp.env && chmod 600 /etc/cadsketch-mcp.env && systemctl restart cadsketch-mcp"
   curl https://mcp.cadsketch.ai/.well-known/openai-apps-challenge    # must print exactly the token
   ```

   Then press verify in the portal.
4. **Tool scan.** It should find four tools. Each needs its annotations
   justified; paste these:

   | Tool | readOnly | destructive | openWorld | Justification |
   | --- | --- | --- | --- | --- |
   | `draw_parts` | true | false | false | Computes a geometry report from the parts in the request and returns them for display. It changes no data anywhere and contacts no other service. |
   | `open_sketcher` | true | false | false | Returns an empty canvas for display. No data is read, written or sent elsewhere. |
   | `open_file` | true | false | false | Echoes the file reference the host passed so the viewer can open it. The server never reads or writes the file; the host does, on the user's machine. |
   | `check_parts` | true | false | false | Pure computation on the parts in the request: sizes, volume and warnings. Nothing is stored or sent elsewhere. |

5. **Frame domain explanation** (the scan reports `https://cadsketch.ai`):

   > The plugin's interface is the CADSketch editor itself, a web application
   > we publish at https://cadsketch.ai/app. The widget embeds that editor in a
   > frame so users get the same editor as the standalone app. It is our own
   > first-party domain; no third-party content is framed.

6. **Review details.**
   - Test account: none needed. The plugin has no sign-in and no user data.
   - Test cases, release notes, screenshots and starter prompts come from the
     ZIP. Check they appear.
   - Commerce: no.
7. **Submit for review**, accept the policy attestations.
8. When approved, press **Publish plugin**.

## What reviewers will see

Listing URLs, all live:

- https://cadsketch.ai
- https://cadsketch.ai/support/
- https://cadsketch.ai/privacy/ (has a section on what the plugin shares)
- https://cadsketch.ai/terms/

The directory version uses the remote server, so:

- drawing, the sidebar and thread panel, the live editing tools and screenshots
  work everywhere the host supports them;
- opening `.cadsketch` / `.dxf` files works on desktop (the host reads the file);
- STL export is offered as a download rather than saved into the workspace
  (saving next to a file needs the locally installed plugin).

## Updating later

- **Tools or the editor changed:** deploy (`mcp/deploy/deploy.sh`, and the web
  app deploys on push). OpenAI rescans the server daily; no new ZIP.
- **Name, descriptions, icons, prompts, screenshots, the skill, or test cases
  changed:** bump `version` in `plugin/cadsketch/.codex-plugin/plugin.json`,
  rebuild the ZIP, upload it. That goes through review again.
