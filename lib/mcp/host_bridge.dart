// Bridge to an AI host (ChatGPT, Claude, any MCP Apps host) when the web build
// is embedded as an MCP App widget. On every other target, and on the plain
// web app, it does nothing: `HostBridge.attach` returns null.
//
// See mcp/README.md for the whole picture.
export 'host_bridge_stub.dart' if (dart.library.js_interop) 'host_bridge_web.dart';
