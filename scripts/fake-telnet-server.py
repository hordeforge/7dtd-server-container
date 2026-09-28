#!/usr/bin/env python3
"""Fake telnet endpoint for the telnet_session CI test.

Tolerates probe connections, records every byte of the first connection that
sends data, replies once, then closes (the EOF ends the helper instead of its
timeout) and writes the recorded bytes to the output path.

Usage: fake-telnet-server.py PORT OUTPUT_PATH [--hold]

PORT 0 binds an ephemeral port and prints the chosen port on stdout (flushed)
once listening; the test reads it instead of racing on a fixed port.

--hold accepts the first connection and then goes silent forever (never
replies, never closes): the endpoint behind the bounded-session test, which
asserts the client side ends itself at its timeout instead of hanging.

Framing is quiescence-based: input is collected until QUIET seconds pass with
nothing new or the peer closes, so the exchange stays byte-exact no matter how
TCP segments the client's write and no matter how many lines the payload spans.
The client never half-closes while waiting for the reply, so peer-close and
quiescence are both just end-of-input signals here.
"""

import socket
import sys
import time
from pathlib import Path

QUIET = 0.4  # seconds of silence that end input collection
HOLD_SECS = 300  # --hold silence span; the client timeout must fire long before

port, out = int(sys.argv[1]), sys.argv[2]
hold = "--hold" in sys.argv[3:]


def main() -> None:
    # Every socket is a with-block: a send/reply error on a probed connection
    # would otherwise unwind past the closes below and leave the listener and
    # the accepted connection open for the life of the process.
    with socket.socket() as srv:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", port))
        srv.listen(1)
        if port == 0:
            print(srv.getsockname()[1], flush=True)
        if hold:
            with srv.accept()[0]:
                time.sleep(HOLD_SECS)
            return
        while True:
            with srv.accept()[0] as conn:
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
                    continue  # readiness probe; wait for the real client
                conn.sendall(b"telnet ok\n")
                break
    with Path(out).open("wb") as f:
        f.write(buf)


if __name__ == "__main__":
    main()
