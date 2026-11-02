#!/usr/bin/env python3
"""Stand-in for S3 presigned URLs in the smoke test.

  server.py PORT SERVE_DIR UPLOAD_DIR

GET /<name>  serves SERVE_DIR/<name>
PUT /<name>  stores the body to UPLOAD_DIR/<name> and its Content-Type to
             UPLOAD_DIR/<name>.ctype

Query strings are ignored so the test can hand out URLs that look presigned
(?X-Amz-Signature=...) and then assert that they never leak.
"""
import http.server
import os
import sys
from urllib.parse import urlparse

PORT, SERVE, UPLOAD = int(sys.argv[1]), sys.argv[2], sys.argv[3]


class Handler(http.server.BaseHTTPRequestHandler):
    def _name(self):
        return os.path.basename(urlparse(self.path).path)

    def do_GET(self):
        path = os.path.join(SERVE, self._name())
        if not os.path.isfile(path):
            self.send_response(404)
            self.end_headers()
            return
        with open(path, "rb") as fh:
            body = fh.read()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_PUT(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        name = self._name()
        with open(os.path.join(UPLOAD, name), "wb") as fh:
            fh.write(body)
        with open(os.path.join(UPLOAD, name + ".ctype"), "w") as fh:
            fh.write(self.headers.get("Content-Type", ""))
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
