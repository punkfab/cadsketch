"""Serves a directory with a CORS header, for the e2e test.

    python3 e2e/cors-server.py <dir-containing-app/> [port]

<dir>/app must be a Flutter web build made with --base-href /app/.
"""
import functools, http.server, sys

class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()
    def log_message(self, *args):
        pass

port = int(sys.argv[2]) if len(sys.argv) > 2 else 18091
http.server.ThreadingHTTPServer(("127.0.0.1", port), functools.partial(Handler, directory=sys.argv[1])).serve_forever()
