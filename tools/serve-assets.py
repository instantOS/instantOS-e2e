#!/usr/bin/env python3
"""Serve this run's assets on an available port; stdout is the ready handshake."""
import functools
import http.server
import sys

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
with http.server.ThreadingHTTPServer(("0.0.0.0", 0), handler) as server:
    print(server.server_port, flush=True)
    server.serve_forever()
