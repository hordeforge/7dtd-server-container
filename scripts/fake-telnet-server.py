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

A bad invocation exits 2 with a usage line instead of an argv traceback, and
the listening socket is closed on every path, including a failed one.
"""

from __future__ import annotations

import socket
import sys
import time
from pathlib import Path
from typing import NoReturn

QUIET = 0.4  # seconds of silence that end input collection
HOLD_SECS = 300  # --hold silence span; the client timeout must fire long before

USAGE = "usage: fake-telnet-server.py PORT OUTPUT_PATH [--hold]"


def die(msg: str) -> NoReturn:
    print(f"{USAGE}\nfake-telnet-server.py: {msg}", file=sys.stderr)
    raise SystemExit(2)


def parse_args(argv: list[str]) -> tuple[int, Path, bool]:
    """PORT, OUTPUT_PATH and the --hold flag, or exit 2 naming what was wrong."""
    if argv and argv[0] in ("-h", "--help"):
        print(USAGE)
        raise SystemExit(0)
    if not 2 <= len(argv) <= 3:
        die("expected PORT and OUTPUT_PATH, optionally followed by --hold")
    try:
        port = int(argv[0])
    except ValueError:
        die(f"PORT must be an integer, got {argv[0]!r}")
    if not 0 <= port <= 65535:
        die(f"PORT must be in 0..65535, got {port}")
    flags = argv[2:]
    if flags not in ([], ["--hold"]):
        die(f"unexpected argument '{flags[0]}'")
    return port, Path(argv[1]), flags == ["--hold"]


def collect(conn: socket.socket) -> bytes:
    """Every byte the peer sends, until it closes or falls quiet for QUIET."""
    conn.settimeout(QUIET)
    buf = bytearray()
    try:
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
    except OSError:
        pass  # recv timeout = quiescence; reset/error ends collection too
    return bytes(buf)


def record_first_session(srv: socket.socket) -> bytes:
    """Skip probe connections (they send nothing) and return the real bytes."""
    while True:
        conn, _ = srv.accept()
        try:
            recorded = collect(conn)
            if recorded:
                conn.sendall(b"telnet ok\n")
                return recorded
        finally:
            conn.close()


def main() -> int:
    port, out, hold = parse_args(sys.argv[1:])
    srv = socket.socket()
    try:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", port))
        srv.listen(1)
        if port == 0:
            print(srv.getsockname()[1], flush=True)
        if hold:
            conn, _ = srv.accept()
            time.sleep(HOLD_SECS)
            conn.close()
            return 0
        recorded = record_first_session(srv)
    finally:
        srv.close()
    try:
        with out.open("wb") as f:
            f.write(recorded)
    except OSError as exc:
        # The recorded bytes exist nowhere else: name the path rather than
        # dropping them behind a traceback the test never surfaces.
        print(f"fake-telnet-server.py: cannot write {out}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
