#!/usr/bin/python3
"""A one-request HTTP sink for testing the alert webhook.

Usage: webhook_sink.py [PORT]

Accepts POSTs on any path, answers 200, and prints each request body on one
line of stdout so a test can read back exactly what Grafana sent.
"""

import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

DEFAULT_PORT = 9000


class Sink(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8", errors="replace")
        sys.stdout.write(body.replace("\n", " ") + "\n")
        sys.stdout.flush()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, format: str, *args: object) -> None:
        """Stay quiet; only request bodies go to stdout."""


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT
    HTTPServer(("0.0.0.0", port), Sink).serve_forever()
