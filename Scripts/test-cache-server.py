#!/usr/bin/env python3
"""A minimal remote cache for tests: GET, HEAD and PUT of files under a directory.

    python3 -I Scripts/test-cache-server.py <directory> <port-file> [bearer-token]

Listens on 127.0.0.1 (a free port, written to <port-file> once ready). With a token, every request
must carry `Authorization: Bearer <token>`; anything else gets 401.
"""

import http.server
import os
import sys

root = os.path.abspath(sys.argv[1])
port_file = sys.argv[2]
token = sys.argv[3] if len(sys.argv) > 3 else None


class Handler(http.server.BaseHTTPRequestHandler):
    def path_on_disk(self):
        relative = self.path.split("?", 1)[0].lstrip("/")
        path = os.path.abspath(os.path.join(root, relative))
        return path if path.startswith(root + os.sep) else None

    def authorized(self):
        if token is None or self.headers.get("Authorization") == "Bearer " + token:
            return True
        self.send_response(401)
        self.end_headers()
        return False

    def serve(self, with_body):
        if not self.authorized():
            return
        path = self.path_on_disk()
        if path is None or not os.path.isfile(path):
            self.send_response(404)
            self.end_headers()
            return
        with open(path, "rb") as handle:
            data = handle.read()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if with_body:
            self.wfile.write(data)

    def do_GET(self):
        self.serve(with_body=True)

    def do_HEAD(self):
        self.serve(with_body=False)

    def do_PUT(self):
        if not self.authorized():
            return
        path = self.path_on_disk()
        if path is None:
            self.send_response(400)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(length)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(data)
        self.send_response(201)
        self.end_headers()

    def log_message(self, *arguments):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
