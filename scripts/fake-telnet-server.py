#!/usr/bin/env python3
"""Fake telnet endpoint for the telnet_session CI test.

Tolerates probe connections, records every byte of the first connection that
sends data, replies once, then closes (the EOF ends the helper instead of its
timeout) and writes the recorded bytes to the output path.

Usage: fake-telnet-server.py PORT OUTPUT_PATH
"""
import socket
import sys

port, out = int(sys.argv[1]), sys.argv[2]
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(1)
while True:
    conn, _ = srv.accept()
    conn.settimeout(8)
    try:
        data = conn.recv(4096)
        if not data:
            continue  # readiness probe; wait for the real client
        while data.count(b"\n") < 2:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
        conn.sendall(b"telnet ok\n")
        break
    finally:
        conn.close()
srv.close()
with open(out, "wb") as f:
    f.write(data)
