// The host side of the MCP Apps channel, as a function that runs IN THE PAGE.
// It stands in for the Codex / ChatGPT desktop app: answers the handshake,
// serves and writes "workspace files" through OpenAI's file-resource extension,
// records what the widget reports, and can call the tools the widget publishes.
// Shared by fake-host.mjs (the tests) and screenshots.mjs.
//
// Usage from Node:  page.evaluate(`(${hostScript})(html, sandbox, prepare)`)
//   window.H.openFile(name, text)   register a file to open (call in `prepare`)
//   window.H.callTool(name, args)   call a tool the mounted widget publishes
//   window.H.context                last ui/update-model-context params
//   window.H.writes                 every openai/resources/write
export function hostScript(widgetHtml, sandbox, prepare, size) {
  size = size || { width: 1180, height: 720 };
  const H = (window.H = { log: [], files: {}, etag: 1, context: null, writes: [], reads: 0, subscribed: [], pending: {}, rid: 1, serverCalls: [], downloads: [] });
  const frame = document.createElement("iframe");
  frame.setAttribute("sandbox", sandbox);
  frame.style.cssText = `width:${size.width}px;height:${size.height}px;border:0;display:block`;
  document.body.style.margin = "0";
  document.body.appendChild(frame);
  const send = (msg) => frame.contentWindow.postMessage({ jsonrpc: "2.0", ...msg }, "*");
  H.notify = (method, params) => send({ method, params });
  // Host -> app requests: how the model calls the tools the mounted app publishes.
  H.request = (method, params) =>
    new Promise((resolve) => {
      const id = "h" + H.rid++;
      H.pending[id] = resolve;
      send({ id, method, params });
    });
  // The model calling a tool on the SERVER, which relays it to the editor.
  H.relayQueue = []; H.relayPending = {}; H.relayPolls = 0; H.relayWaiter = null; H.relayId = 1;
  H.relay = (tool, args) =>
    new Promise((resolve) => {
      const command = { id: H.relayId++, tool, args: args ?? {} };
      H.relayPending[command.id] = resolve;
      if (H.relayWaiter) H.relayWaiter(command);
      else H.relayQueue.push(command);
    });
  H.callTool = (name, args) => H.request("tools/call", { name, arguments: args ?? {} });
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
    if (!m || m.jsonrpc !== "2.0") return;
    if (!m.method) {
      // A response to one of our requests.
      const done = H.pending[m.id];
      if (done) {
        delete H.pending[m.id];
        done(m.result ?? { isError: true, content: [{ type: "text", text: m.error?.message ?? "error" }] });
      }
      return;
    }
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
            serverTools: {},
            downloadFile: {},
            openLinks: {},
            logging: {},
          },
          hostContext: {
            theme: "dark",
            displayMode: "fullscreen",
            availableDisplayModes: ["inline", "fullscreen"],
            containerDimensions: { width: size.width, height: size.height },
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
      case "tools/call":
        if (m.params.name === "editor_sync") {
          // The local plugin server's relay (src/relay.ts), in miniature: hand
          // the editor the next queued command, take back the last one's result.
          if (!H.relayOn) return reply({ isError: true, content: [{ type: "text", text: "Unknown tool" }] });
          const back = m.params.arguments?.reply;
          if (back && H.relayPending[back.id]) {
            H.relayPending[back.id](back.result);
            delete H.relayPending[back.id];
          }
          H.relayPolls++;
          const next = H.relayQueue.shift();
          if (next) return reply({ content: [{ type: "text", text: next.tool }], structuredContent: { command: next } });
          const timer = setTimeout(() => { H.relayWaiter = null; reply({ content: [{ type: "text", text: "idle" }], structuredContent: {} }); }, 2000);
          H.relayWaiter = (command) => { clearTimeout(timer); H.relayWaiter = null; reply({ content: [{ type: "text", text: command.tool }], structuredContent: { command } }); };
          return;
        }
        // The app calling a SERVER tool (save_export). A real host adds the
        // opened file's path for the server; here we just answer as the server would.
        H.serverCalls.push({ name: m.params.name, fileName: m.params.arguments?.fileName, bytes: (m.params.arguments?.blob ?? "").length });
        if (m.params.name === "save_export" && H.pendingFile)
          return reply({ content: [{ type: "text", text: "Saved" }], structuredContent: { path: "/workspace/" + m.params.arguments.fileName } });
        return reply({ isError: true, content: [{ type: "text", text: "No open workspace file to save next to." }] });
      case "ui/download-file":
        H.downloads.push(m.params.contents?.[0]?.resource?.uri);
        return reply({});
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

