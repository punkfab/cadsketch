import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../ui/sketch_canvas.dart';
import 'host_document.dart';
import 'part_spec.dart';

// Web host bridge. Active ONLY when the page was opened as an embedded widget:
//   * `?mcp=1` in the URL  -> we are an iframe inside the widget shell, and
//     talk to `window.parent`;
//   * `window.CADSKETCH_MCP` set before Flutter loads -> we ARE the widget
//     document, and the shell script lives in this same window.
// Otherwise `attach` returns null and the app is exactly the standalone app.
//
// The MCP Apps protocol itself (handshake, sizing, model context, display
// modes) is spoken by the small JS shell in mcp/widget, using the official
// SDK. This file only exchanges three private messages with that shell, as
// plain strings so nothing depends on structured-clone details:
//
//   app  -> shell   "cadsketch>host:" + {"type":"ready"}
//   app  -> shell   "cadsketch>host:" + {"type":"state","structured":{},"text":""}
//   shell -> app    "cadsketch>app:"  + {"type":"load","parts":[...]}

@JS('CADSKETCH_MCP')
external JSAny? get _directFlag;

const _toHost = 'cadsketch>host:';
const _toApp = 'cadsketch>app:';

class HostBridge {
  HostBridge._(this._controller, this._framed) {
    _listener = _onMessage.toJS;
    web.window.addEventListener('message', _listener);
    _controller.addListener(_onDocumentChanged);
    _post({'type': 'ready'});
    _onDocumentChanged(); // report the initial (empty) document too
  }

  /// Starts the bridge if this page is running as an embedded widget.
  static HostBridge? attach(SketchController controller) {
    final framed = Uri.base.queryParameters['mcp'] == '1';
    final direct = _directFlag != null;
    if (!framed && !direct) return null;
    return HostBridge._(controller, framed);
  }

  final SketchController _controller;
  final bool _framed;
  late final JSFunction _listener;
  Timer? _debounce;
  String? _lastSent;

  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onDocumentChanged);
    web.window.removeEventListener('message', _listener);
  }

  void _post(Map<String, dynamic> message) {
    final text = (_toHost + jsonEncode(message)).toJS;
    if (_framed) {
      web.window.parent?.postMessage(text, '*'.toJS);
    } else {
      web.window.postMessage(text, '*'.toJS);
    }
  }

  // Coalesce bursts (a drag fires many notifications) into one update.
  void _onDocumentChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), _sendState);
  }

  void _sendState() {
    final ctx = modelContextOf(_controller);
    final payload = {
      'type': 'state',
      'structured': ctx.structured,
      'text': ctx.text,
    };
    final encoded = jsonEncode(payload);
    if (encoded == _lastSent) return; // selection changes etc. — nothing new
    _lastSent = encoded;
    _post(payload);
  }

  void _onMessage(web.Event event) {
    final data = (event as web.MessageEvent).data;
    if (data == null || !data.typeofEquals('string')) return;
    final text = (data as JSString).toDart;
    if (!text.startsWith(_toApp)) return;
    try {
      final msg = jsonDecode(text.substring(_toApp.length));
      if (msg is! Map) return;
      switch (msg['type']) {
        case 'load':
          loadPartSpecs(_controller, partSpecsFromJson(msg['parts']));
        case 'ping':
          _post({'type': 'ready'});
          _lastSent = null;
          _onDocumentChanged();
      }
    } on PartSpecException catch (e) {
      _post({'type': 'error', 'message': e.message});
    } catch (e) {
      _post({'type': 'error', 'message': 'could not apply host message'});
    }
  }
}
