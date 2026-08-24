#!/usr/bin/env python3
"""Fake telnet endpoint for the telnet_session CI test.

Tolerates probe connections, records every byte of the first connection that
sends data, replies once, then closes (the EOF ends the helper instead of its
timeout) and writes the recorded bytes to the output path.

Usage: fake-telnet-server.py PORT OUTPUT_PATH

PORT 0 binds an ephemeral port and prints the chosen port on stdout (flushed)
once listening; the test reads it instead of racing on a fixed port.

Framing is quiescence-based: input is collected until QUIET seconds pass with
nothing new or the peer closes, so the exchange stays byte-exact no matter how
TCP segments the client's write and no matter how many lines the payload spans.
The client never half-closes while waiting for the reply, so peer-close and
quiescence are both just end-of-input signals here.
"""

import socket
import sys

QUIET = 0.4  # seconds of silence that end input collection

port, out = int(sys.argv[1]), sys.argv[2]
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(1)
if port == 0:
    print(srv.getsockname()[1], flush=True)
while True:
    conn, _ = srv.accept()
    buf = bytearray()
    try:
        conn.settimeout(QUIET)
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
    except OSError:
        pass  # recv timeout = quiescence; reset/error ends collection too
    if not buf:
        conn.close()
        continue  # readiness probe; wait for the real client
    conn.sendall(b"telnet ok\n")
    conn.close()
    break
srv.close()
with open(out, "wb") as f:
    f.write(buf)
