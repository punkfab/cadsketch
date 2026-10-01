// The editing tools act on the editor the user has open, but a tool call from
// the model arrives at this server, not at the editor. A host that lets a
// mounted app publish its own tools needs nothing from us; Codex does not show
// those to the model, so the server offers the same tools and relays each call:
//
//   model  -> server   set_dimension {...}          (waits)
//   editor -> server   editor_sync                  (a long poll; gets the call)
//   editor -> server   editor_sync {reply}          (the result; poll again)
//   server -> model    the result
//
// State lives in this process, so the relay exists only in the local server a
// plugin launches for one user (see ServerOptions.local).
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

export type RelayCommand = { id: number; tool: string; args: Record<string, unknown> };

type Editor = {
  opened: number;
  seen: number;
  visible: boolean;
  queue: RelayCommand[];
  waiter?: (command: RelayCommand | null) => void;
};
type Pending = { resolve: (result: CallToolResult) => void; timer: ReturnType<typeof setTimeout> };

export interface RelayTimings {
  /** How long one poll is held open waiting for a command. */
  holdMs: number;
  /** An editor that has not polled for this long is gone. */
  staleMs: number;
  /** How long a call waits for an editor to appear (one may be loading). */
  waitForEditorMs: number;
  /** How long a call waits for the editor's answer. */
  answerMs: number;
}

const DEFAULTS: RelayTimings = { holdMs: 15000, staleMs: 40000, waitForEditorMs: 12000, answerMs: 60000 };

const error = (text: string): CallToolResult => ({ isError: true, content: [{ type: "text", text }] });

export class EditorRelay {
  private editors = new Map<string, Editor>();
  private pending = new Map<number, Pending>();
  private nextId = 1;
  private timings: RelayTimings;

  constructor(timings: Partial<RelayTimings> = {}) {
    this.timings = { ...DEFAULTS, ...timings };
  }

  /** One poll from an editor: delivers the previous command's result, then waits for the next command. */
  sync(id: string, visible: boolean, reply?: { id: number; result: CallToolResult }): Promise<RelayCommand | null> {
    const now = Date.now();
    let editor = this.editors.get(id);
    if (!editor) {
      editor = { opened: now, seen: now, visible, queue: [] };
      this.editors.set(id, editor);
    }
    editor.seen = now;
    editor.visible = visible;
    editor.waiter?.(null); // a newer poll replaces an older one
    editor.waiter = undefined;

    if (reply) {
      const waiting = this.pending.get(reply.id);
      if (waiting) {
        this.pending.delete(reply.id);
        clearTimeout(waiting.timer);
        waiting.resolve(reply.result);
      }
    }

    const queued = editor.queue.shift();
    if (queued) return Promise.resolve(queued);
    const target = editor;
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        if (target.waiter === deliver) target.waiter = undefined;
        target.seen = Date.now();
        resolve(null);
      }, this.timings.holdMs);
      const deliver = (command: RelayCommand | null) => {
        clearTimeout(timer);
        resolve(command);
      };
      target.waiter = deliver;
    });
  }

  /** The editor a call should go to: one that is still polling; a visible one first, then the newest. */
  private pick(): Editor | undefined {
    const now = Date.now();
    let best: Editor | undefined;
    for (const [id, editor] of this.editors) {
      if (!editor.waiter && now - editor.seen > this.timings.staleMs) {
        this.editors.delete(id);
        continue;
      }
      if (!best || (editor.visible && !best.visible) || (editor.visible === best.visible && editor.opened > best.opened)) best = editor;
    }
    return best;
  }

  /** Runs one tool in the open editor and resolves with its result. Never rejects. */
  async send(tool: string, args: Record<string, unknown>): Promise<CallToolResult> {
    const deadline = Date.now() + this.timings.waitForEditorMs;
    let editor = this.pick();
    while (!editor && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 200));
      editor = this.pick();
    }
    if (!editor) {
      return error(
        "The CADSketch editor is not open, so there is no sketch to act on. Call open_sketcher (or draw_parts to start from a design), wait for the editor to appear, then call this again.",
      );
    }
    const command: RelayCommand = { id: this.nextId++, tool, args };
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(command.id);
        resolve(error(`The CADSketch editor did not answer "${tool}". It may have been closed; call open_sketcher and try again.`));
      }, this.timings.answerMs);
      this.pending.set(command.id, { resolve, timer });
      if (editor.waiter) {
        const deliver = editor.waiter;
        editor.waiter = undefined;
        deliver(command);
      } else {
        editor.queue.push(command);
      }
    });
  }
}
