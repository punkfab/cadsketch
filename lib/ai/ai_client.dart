// AI assistant binding facade. The assistant shells out to the local `claude`
// CLI (desktop harness only, no API key); on web there's no process to spawn,
// so the web variant is a graceful stub. The rest of the app imports only this.
export 'ai_client_io.dart' if (dart.library.js_interop) 'ai_client_web.dart';
