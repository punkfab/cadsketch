// The widget shell: the page an AI host (ChatGPT, Codex, Claude, ...) renders
// for a CADSketch tool call, sidebar app, thread panel or opened file. It does
// three jobs and nothing else:
//
//  1. Speaks the MCP Apps protocol to the host, through the official SDKs
//     (plus OpenAI's extensions where the host has them).
//  2. Hosts the real CADSketch web app in a nested frame and relays a few
//     private string messages to it (see lib/mcp/host_bridge_web.dart):
//        shell -> app  load / loadDxf   content to show
//        app -> shell  ready            the editor is up
//        app -> shell  state            what is on the canvas now
//  3. When opened on a workspace file, keeps that file and the canvas in sync.
//
// No CAD logic lives here; the editor is the same build as cadsketch.ai/app.
import { App, applyDocumentTheme, applyHostFonts, applyHostStyleVariables } from "@modelcontextprotocol/ext-apps";
import { OpenAIExtensions, OpenAIFileEntrypointInputSchema } from "@openai/mcp-extensions/app";
import { canonical, fileKind, parseFile, partsFromState, serializeFile, type FilePart } from "./file-sync.js";
import { registerLiveTools } from "./live-tools.js";

const TO_HOST = "cadsketch>host:";
const TO_APP = "cadsketch>app:";
const INLINE_HEIGHT = 620; // bar + editor, in an inline card

const frame = document.getElementById("app") as HTMLIFrameElement;
const veil = document.getElementById("veil") as HTMLElement;
const veilText = document.getElementById("veil-text") as HTMLElement;
const veilOpen = document.getElementById("veil-open") as HTMLButtonElement;
const nameEl = document.querySelector(".bar .name") as HTMLElement;
const statusEl = document.getElementById("status") as HTMLElement;
const reviewBtn = document.getElementById("review") as HTMLButtonElement;
const expandBtn = document.getElementById("expand") as HTMLButtonElement;

const appUrl = new URL(document.documentElement.dataset.appUrl!);
const standaloneUrl = appUrl.toString();
appUrl.searchParams.set("mcp", "1");

type McpUiHostContext = NonNullable<ReturnType<App["getHostContext"]>>;
type State = { structured: Record<string, unknown>; text: string; loadId?: number };
type EditorMessage = { type: "load"; parts: unknown[]; loadId: number } | { type: "loadDxf"; name: string; text: string; loadId: number };
type Pending = { resolve: (value: Record<string, unknown>) => void; reject: (error: Error) => void; timer: ReturnType<typeof setTimeout> };

/** The workspace file this instance was opened on, if any. */
type OpenFile = {
  name: string;
  uri: string;
  kind: "cadsketch" | "dxf";
  writable: boolean;
  etag?: string;
  /** Text we last read or wrote: an update notification carrying it is our own echo. */
  lastText: string | null;
  /** The load we are waiting to see reflected by the editor. */
  pendingLoadId: number | null;
  /** Canvas as of the last load or save. Only a canvas that differs gets written. */
  baseline: string | null;
};

let editorReady = false;
let connected = false;
let pendingLoad: EditorMessage | null = null; // content that arrived before the editor was up
let pendingState: State | null = null; // reported before the host was connected
let displayMode: "inline" | "fullscreen" | "pip" = "inline";
let file: OpenFile | null = null;
let nextLoadId = 1;
let saveTimer: ReturnType<typeof setTimeout> | undefined;
let whenConnected: Promise<void> = Promise.resolve(); // set at the bottom, once connect() is called

// `tools`: this app publishes its own tools to the model while it is mounted.
const app = new App({ name: "CADSketch", version: "0.3.0" }, { tools: { listChanged: true }, availableDisplayModes: ["inline", "fullscreen"] });
const openai = new OpenAIExtensions(app);

function setStatus(text: string) {
  statusEl.textContent = text;
}

// ---- shell <-> editor -------------------------------------------------------

function sendToEditor(message: EditorMessage) {
  if (!editorReady) {
    pendingLoad = message; // only the latest matters
    return;
  }
  // "*" because a host may sandbox nested frames into an opaque origin, where a
  // specific target origin would never match. Nothing in the payload is secret.
  frame.contentWindow?.postMessage(TO_APP + JSON.stringify(message), "*");
}

// ---- commands: model -> editor ---------------------------------------------

const calls = new Map<number, Pending>();
const readyWaiters: (() => void)[] = [];
let nextCallId = 1;

/** Runs one editing command in the live editor and resolves with its result. */
async function callEditor(op: string, args: Record<string, unknown>): Promise<Record<string, unknown>> {
  if (!editorReady) {
    // A tool can be called the moment the app mounts; give the editor time to start.
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("The CADSketch editor has not finished loading. Try again in a moment.")), 25000);
      readyWaiters.push(() => {
        clearTimeout(timer);
        resolve();
      });
    });
  }
  const id = nextCallId++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      calls.delete(id);
      reject(new Error(`The editor did not answer "${op}".`));
    }, 15000);
    calls.set(id, { resolve, reject, timer });
    frame.contentWindow?.postMessage(TO_APP + JSON.stringify({ type: "call", id, op, args }), "*");
  });
}

/** Where an export goes: next to the open file when there is one, else a download. */
async function saveExport(fileName: string, base64: string): Promise<string> {
  if (file) {
    // The local plugin server may write next to the file the host opened; the
    // host adds that file's real path to this call, the app never sees it.
    const saved = await app.callServerTool({ name: "save_export", arguments: { fileName, blob: base64 } }).catch(() => null);
    const path = (saved?.structuredContent as { path?: string } | undefined)?.path;
    if (saved && !saved.isError && path) return `Saved ${path}.`;
  }
  if (app.getHostCapabilities()?.downloadFile) {
    const result = await app.downloadFile({
      contents: [{ type: "resource", resource: { uri: `file:///${fileName}`, mimeType: "model/stl", blob: base64 } }],
    });
    if (!result.isError) return `Offered ${fileName} to the user as a download.`;
  }
  throw new Error(
    "This app could not save the STL. Open a .cadsketch file from the workspace in CADSketch and export again (the STL is then saved next to it), or ask the user to use Export STL in the editor's command menu.",
  );
}

registerLiveTools(app, { call: callEditor, saveExport });

window.addEventListener("message", (event) => {
  if (event.source !== frame.contentWindow) return;
  if (typeof event.data !== "string" || !event.data.startsWith(TO_HOST)) return;
  let message: {
    type?: string;
    structured?: Record<string, unknown>;
    text?: string;
    message?: string;
    loadId?: number;
    id?: number;
    ok?: boolean;
    value?: Record<string, unknown>;
    error?: string;
  };
  try {
    message = JSON.parse(event.data.slice(TO_HOST.length));
  } catch {
    return;
  }
  if (message.type === "ready") {
    editorReady = true;
    veil.hidden = true;
    reviewBtn.hidden = false;
    for (const wake of readyWaiters.splice(0)) wake();
    if (pendingLoad) {
      const queued = pendingLoad;
      pendingLoad = null;
      sendToEditor(queued);
    }
  } else if (message.type === "state" && message.structured && typeof message.text === "string") {
    const state = { structured: message.structured, text: message.text, loadId: message.loadId };
    syncFile(state);
    reportState(state);
  } else if (message.type === "result" && typeof message.id === "number") {
    const pending = calls.get(message.id);
    if (!pending) return;
    calls.delete(message.id);
    clearTimeout(pending.timer);
    if (message.ok) pending.resolve(message.value ?? {});
    else pending.reject(new Error(message.error ?? "The editor rejected the command."));
  } else if (message.type === "error" && message.message) {
    setStatus(message.message);
  }
});

// ---- canvas -> model --------------------------------------------------------

/** Makes the canvas visible to the model. */
function reportState(state: State) {
  if (!file) setStatus(state.text.split("\n")[0].replace(" (mm, Y up).", ""));
  if (!connected) {
    pendingState = state;
    return;
  }
  const text = file ? `${state.text}\nOpen file: ${file.name}` : state.text;
  const params = {
    content: [{ type: "text" as const, text, _meta: { "openai/title": file ? file.name : "CADSketch canvas" } }],
    structuredContent: state.structured,
  };
  const update: Promise<unknown> = openai.modelContext ? openai.modelContext.update(params) : app.updateModelContext(params);
  update.catch(() => {
    // Hosts without model-context support: ChatGPT's own widget state reaches
    // the model too, so fall back to it when it exists.
    const legacy = (window as unknown as { openai?: { setWidgetState?: (s: unknown) => void } }).openai;
    legacy?.setWidgetState?.({ modelContent: text, privateContent: state.structured });
  });
}

// ---- workspace file <-> canvas ----------------------------------------------

async function openFile(input: { name: string; resourceUri: string }) {
  const kind = fileKind(input.name);
  if (!kind) return setStatus(`CADSketch can't open ${input.name}.`);
  file = { name: input.name, uri: input.resourceUri, kind, writable: false, lastText: null, pendingLoadId: null, baseline: null };
  nameEl.textContent = input.name;
  await whenConnected; // host capabilities (and so openai.resources) exist only after the handshake
  const resources = openai.resources;
  if (!resources) return setStatus("This app can't read workspace files.");
  resources.addUpdateHandler(async ({ params }) => {
    if (file && params.uri === file.uri) await readFile();
  });
  await readFile();
  await resources.subscribe({ uri: input.resourceUri }).catch(() => {});
}

async function readFile() {
  const resources = openai.resources;
  if (!file || !resources) return;
  try {
    const result = await resources.read({ uri: file.uri, representation: "text" });
    const content = result.contents[0];
    if (!content) throw new Error(`${file.name} could not be read.`);
    const text =
      "text" in content && typeof content.text === "string"
        ? content.text
        : new TextDecoder().decode(Uint8Array.from(atob(String((content as { blob?: string }).blob ?? "")), (c) => c.charCodeAt(0)));
    file.etag = content.openaiMetadata?.etag;
    file.writable = content.openaiMetadata?.writable === true && file.kind === "cadsketch";
    if (text === file.lastText) return; // our own save coming back
    file.lastText = text;
    const opened = parseFile(file.name, text);
    file.pendingLoadId = nextLoadId++;
    file.baseline = null;
    if (opened.kind === "dxf") sendToEditor({ type: "loadDxf", name: file.name.replace(/\.dxf$/i, ""), text: opened.text, loadId: file.pendingLoadId });
    else sendToEditor({ type: "load", parts: opened.parts, loadId: file.pendingLoadId });
    setStatus(file.writable ? "" : "read-only");
  } catch (e) {
    setStatus((e as Error).message);
  }
}

/** Writes the canvas back to the open .cadsketch file when the user changed it. */
function syncFile(state: State) {
  if (!file || file.kind !== "cadsketch") return;
  const { parts, blocker } = partsFromState(state.structured);
  const now = canonical(parts);
  if (file.pendingLoadId !== null) {
    // Wait for the editor to reflect what we loaded; that becomes the baseline,
    // so merely opening a file never rewrites it.
    if (state.loadId !== file.pendingLoadId) return;
    file.pendingLoadId = null;
    file.baseline = now;
    return;
  }
  if (now === file.baseline) return;
  if (blocker) return setStatus(`not saved: ${blocker}`);
  if (!file.writable) return setStatus("read-only: changes are not saved");
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => void saveFile(parts, now), 400);
}

async function saveFile(parts: FilePart[], key: string) {
  const resources = openai.resources;
  if (!file || !resources) return;
  const text = serializeFile(parts);
  try {
    const result = await resources.write(file.uri, { text, ...(file.etag ? { ifMatch: file.etag } : {}) });
    if (result.outcome === "saved") {
      file.etag = result.etag;
      file.lastText = text;
      file.baseline = key;
      setStatus("saved");
    } else if (result.outcome === "too-large") {
      setStatus(`not saved: file would exceed ${result.maxBytes} bytes`);
    } else {
      setStatus("file changed on disk: reloaded");
      file.lastText = null;
      await readFile();
    }
  } catch (e) {
    setStatus(`not saved: ${(e as Error).message}`);
  }
}

// ---- host -> shell ----------------------------------------------------------

// A file entrypoint delivers the file as the tool INPUT; register before
// connecting so the initial one is not missed.
app.addEventListener("toolinput", ({ arguments: args }) => {
  const input = OpenAIFileEntrypointInputSchema.safeParse(args);
  if (input.success) void openFile(input.data.file);
});

app.ontoolresult = (result) => {
  if (result.isError || file) return; // a file instance is driven by its file
  const parts = (result.structuredContent as { parts?: unknown[] } | undefined)?.parts;
  if (Array.isArray(parts)) sendToEditor({ type: "load", parts, loadId: nextLoadId++ });
};

app.onteardown = async () => ({});

function applyHostContext(ctx: McpUiHostContext) {
  if (ctx.theme) applyDocumentTheme(ctx.theme);
  if (ctx.styles?.variables) applyHostStyleVariables(ctx.styles.variables);
  if (ctx.styles?.css?.fonts) applyHostFonts(ctx.styles.css.fonts);
  if (ctx.displayMode) displayMode = ctx.displayMode;
  if (ctx.availableDisplayModes) expandBtn.hidden = !ctx.availableDisplayModes.includes("fullscreen");
  expandBtn.textContent = displayMode === "fullscreen" ? "Shrink" : "Expand";

  // The host sizes the widget from its content height, so set the editor stage
  // explicitly. A host that gives a fixed height (sidebar app, file tab,
  // fullscreen) gets filled; an inline card gets a fixed, usable height.
  const dims = ctx.containerDimensions as { height?: number; maxHeight?: number } | undefined;
  const bar = (document.querySelector(".bar") as HTMLElement).offsetHeight;
  const total =
    dims?.height ??
    (displayMode === "fullscreen" ? (dims?.maxHeight ?? window.innerHeight) : Math.min(INLINE_HEIGHT, dims?.maxHeight ?? INLINE_HEIGHT));
  document.documentElement.style.setProperty("--stage-h", `${Math.max(240, total - bar)}px`);
}

app.onhostcontextchanged = applyHostContext;

expandBtn.addEventListener("click", async () => {
  const mode = displayMode === "fullscreen" ? "inline" : "fullscreen";
  try {
    const result = await app.requestDisplayMode({ mode });
    displayMode = result.mode;
    applyHostContext({ ...(app.getHostContext() ?? {}), displayMode });
  } catch (e) {
    console.error(e);
  }
});

reviewBtn.addEventListener("click", async () => {
  reviewBtn.disabled = true;
  const message = {
    role: "user" as const,
    content: [
      {
        type: "text" as const,
        text: "Review my current CADSketch sketch. Is the profile closed and fully defined? Call out anything that would be hard to make (thin walls, holes too close to an edge, sharp internal corners) and suggest specific improvements.",
      },
    ],
  };
  try {
    await (openai.message ? openai.message.send(message) : app.sendMessage(message));
  } catch (e) {
    console.error(e);
  } finally {
    reviewBtn.disabled = false;
  }
});

veilOpen.addEventListener("click", () => {
  app.openLink({ url: standaloneUrl }).catch(() => window.open(standaloneUrl, "_blank", "noopener"));
});

// ---- start ------------------------------------------------------------------

// Evidence for the failure message: did the host's policy refuse the frame, and
// did the editor page at least load?
let blocked: string | null = null;
let frameLoaded = false;
document.addEventListener("securitypolicyviolation", (e) => {
  if (e.violatedDirective.startsWith("frame-src") || e.violatedDirective.startsWith("child-src")) {
    blocked = e.violatedDirective;
  }
});
frame.addEventListener("load", () => {
  frameLoaded = true;
});

frame.src = appUrl.toString();

// If the editor never reports in, say so plainly and say WHY, instead of
// spinning forever. Three distinguishable cases:
//   frame-blocked  the host's content policy refused the nested frame
//   editor-stalled the page loaded but could not start (its own files were
//                  refused: a sandbox without an origin needs CORS on the app)
//   no-load        the page never arrived (network, or the frame was dropped)
setTimeout(() => {
  if (editorReady) return;
  const reason = blocked ? "frame-blocked" : frameLoaded ? "editor-stalled" : "no-load";
  const detail = {
    "frame-blocked": "This chat app does not allow the embedded editor frame.",
    "editor-stalled": "The editor page opened but could not start inside this chat's sandbox.",
    "no-load": "The editor page did not load inside this chat.",
  }[reason];
  (veil.querySelector("b") as HTMLElement).textContent = "CADSketch didn't load here";
  veilText.textContent = `${detail} You can still use it in a browser tab. (${reason})`;
  veilOpen.hidden = false;
  setStatus(`editor unavailable: ${reason}`);
  if (connected) app.sendLog({ level: "error", data: `CADSketch editor failed to start: ${reason}${blocked ? " " + blocked : ""}` }).catch(() => {});
}, 20000);

whenConnected = app.connect().then(() => {
  connected = true;
  const ctx = app.getHostContext();
  if (ctx) applyHostContext(ctx);
  if (pendingState) {
    reportState(pendingState);
    pendingState = null;
  }
});
