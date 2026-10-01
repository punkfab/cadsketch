// The widget shell: the page an AI host (ChatGPT, Claude, ...) renders for a
// CADSketch tool call. It does two jobs and nothing else:
//
//  1. Speaks the MCP Apps protocol to the host, through the official SDK.
//  2. Hosts the real CADSketch web app in a nested frame and relays three
//     private string messages to it (see lib/mcp/host_bridge_web.dart):
//        shell -> app  load   parts the model drew
//        app -> shell  ready  the editor is up
//        app -> shell  state  what is on the canvas now (for the model)
//
// No CAD logic lives here; the editor is the same build as cadsketch.ai/app.
import { App, applyDocumentTheme, applyHostFonts, applyHostStyleVariables, type McpUiHostContext } from "@modelcontextprotocol/ext-apps";

const TO_HOST = "cadsketch>host:";
const TO_APP = "cadsketch>app:";
const INLINE_HEIGHT = 620; // bar + editor, in an inline card

const frame = document.getElementById("app") as HTMLIFrameElement;
const veil = document.getElementById("veil") as HTMLElement;
const veilText = document.getElementById("veil-text") as HTMLElement;
const veilOpen = document.getElementById("veil-open") as HTMLButtonElement;
const statusEl = document.getElementById("status") as HTMLElement;
const reviewBtn = document.getElementById("review") as HTMLButtonElement;
const expandBtn = document.getElementById("expand") as HTMLButtonElement;

const appUrl = new URL(document.documentElement.dataset.appUrl!);
const standaloneUrl = appUrl.toString();
appUrl.searchParams.set("mcp", "1");

type State = { structured: Record<string, unknown>; text: string };

let editorReady = false;
let connected = false;
let pendingParts: unknown[] | null = null; // drawn before the editor was up
let pendingState: State | null = null; // reported before the host was connected
let displayMode: "inline" | "fullscreen" | "pip" = "inline";

const app = new App({ name: "CADSketch", version: "0.1.0" }, { availableDisplayModes: ["inline", "fullscreen"] });

// ---- shell <-> editor -------------------------------------------------------

function sendToEditor(message: Record<string, unknown>) {
  // "*" because a host may sandbox nested frames into an opaque origin, where a
  // specific target origin would never match. Nothing in the payload is secret.
  frame.contentWindow?.postMessage(TO_APP + JSON.stringify(message), "*");
}

window.addEventListener("message", (event) => {
  if (event.source !== frame.contentWindow) return;
  if (typeof event.data !== "string" || !event.data.startsWith(TO_HOST)) return;
  let message: { type?: string; structured?: Record<string, unknown>; text?: string; message?: string };
  try {
    message = JSON.parse(event.data.slice(TO_HOST.length));
  } catch {
    return;
  }
  if (message.type === "ready") {
    editorReady = true;
    veil.hidden = true;
    reviewBtn.hidden = false;
    if (pendingParts) {
      sendToEditor({ type: "load", parts: pendingParts });
      pendingParts = null;
    }
  } else if (message.type === "state" && message.structured && typeof message.text === "string") {
    reportState({ structured: message.structured, text: message.text });
  } else if (message.type === "error" && message.message) {
    statusEl.textContent = message.message;
  }
});

// ---- shell <-> host ---------------------------------------------------------

/** Makes the canvas visible to the model. */
function reportState(state: State) {
  const parts = (state.structured.parts as unknown[] | undefined) ?? [];
  statusEl.textContent = state.text.split("\n")[0].replace(" (mm, Y up).", "");
  if (!connected) {
    pendingState = state;
    return;
  }
  app.updateModelContext({ content: [{ type: "text", text: state.text }], structuredContent: state.structured }).catch(() => {
    // Hosts without model-context support: ChatGPT's own widget state reaches
    // the model too, so fall back to it when it exists.
    const openai = (window as unknown as { openai?: { setWidgetState?: (s: unknown) => void } }).openai;
    openai?.setWidgetState?.({ modelContent: state.text, privateContent: { parts } });
  });
}

app.ontoolresult = (result) => {
  const parts = (result.structuredContent as { parts?: unknown[] } | undefined)?.parts;
  if (!Array.isArray(parts) || result.isError) return;
  if (editorReady) sendToEditor({ type: "load", parts });
  else pendingParts = parts;
};

app.onteardown = async () => ({});
app.onerror = console.error;

function applyHostContext(ctx: McpUiHostContext) {
  if (ctx.theme) applyDocumentTheme(ctx.theme);
  if (ctx.styles?.variables) applyHostStyleVariables(ctx.styles.variables);
  if (ctx.styles?.css?.fonts) applyHostFonts(ctx.styles.css.fonts);
  if (ctx.displayMode) displayMode = ctx.displayMode;
  if (ctx.availableDisplayModes) expandBtn.hidden = !ctx.availableDisplayModes.includes("fullscreen");
  expandBtn.textContent = displayMode === "fullscreen" ? "Shrink" : "Expand";

  // The host sizes the widget from its content height, so set the editor
  // stage explicitly. Inline: a fixed, usable height. Fullscreen: fill what
  // the host gives us (or the viewport when it doesn't say).
  const dims = ctx.containerDimensions as { height?: number; maxHeight?: number } | undefined;
  const bar = (document.querySelector(".bar") as HTMLElement).offsetHeight;
  const total =
    displayMode === "fullscreen"
      ? (dims?.height ?? dims?.maxHeight ?? window.innerHeight)
      : Math.min(INLINE_HEIGHT, dims?.maxHeight ?? INLINE_HEIGHT);
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
  try {
    await app.sendMessage({
      role: "user",
      content: [
        {
          type: "text",
          text: "Review my current CADSketch sketch. Is the profile closed and fully defined? Call out anything that would be hard to make (thin walls, holes too close to an edge, sharp internal corners) and suggest specific improvements.",
        },
      ],
    });
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

frame.src = appUrl.toString();

// If the editor never reports in, say so plainly instead of spinning forever
// (a host that blocks nested frames or WebAssembly lands here).
setTimeout(() => {
  if (editorReady) return;
  veilText.textContent = "The editor could not start inside this chat. You can still use it in a browser tab.";
  (veil.querySelector("b") as HTMLElement).textContent = "CADSketch didn't load here";
  veilOpen.hidden = false;
}, 25000);

app.connect().then(() => {
  connected = true;
  const ctx = app.getHostContext();
  if (ctx) applyHostContext(ctx);
  if (pendingState) {
    reportState(pendingState);
    pendingState = null;
  }
});
