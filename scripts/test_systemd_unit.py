#!/usr/bin/env python3
"""Unit tests pinning the quadlet unit contract (systemd/7dtd-server.container).

Methodology: the unit is the durable lifecycle and it must not drift from the
decisions the ad-hoc lifecycle (scripts/run.sh) owns. The contracts pinned
here:

  graceful stop   the game ignores SIGTERM (no world save), so every
                  systemd-driven stop/restart/shutdown must go through
                  scripts/run.sh stop (telnet save+shutdown, bounded wait,
                  forced-stop fallback) with a TimeoutStopSec covering the
                  worst case (probe 3s + session 10s + podman wait 90s +
                  podman stop 30s).
  shared defaults TELNET_PASSWORD/TELNET_PORT are owned by init_telnet_env in
                  scripts/lib-env.sh (baked into the image); hardcoding them
                  as Environment= lines here would create a second default
                  that can silently drift.
  durability      Restart=always brings a crashed server back on its own,
                  Init=true reaps orphans for the whole uptime, and
                  Network=host is what makes the game/telnet/dashboard ports
                  LAN-reachable at all.

Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UNIT = ROOT / "systemd" / "7dtd-server.container"

# Worst-case graceful-stop path in seconds (see module docstring); the unit
# timeout must exceed it or systemd force-kills mid-save.
WORST_STOP_SECS = 3 + 10 + 90 + 30

failed_checks: list[str] = []


def check(name: str, cond: bool) -> None:
    if cond:
        print(f"OK: {name}")
    else:
        print(f"FAIL: {name}", file=sys.stderr)
        failed_checks.append(name)


text = UNIT.read_text(encoding="utf-8")
service = text.split("[Service]", 1)[1] if "[Service]" in text else ""

exec_stop = re.findall(r"^ExecStop=(.*)$", service, re.MULTILINE)
check(
    "ExecStop routes stops through scripts/run.sh stop",
    exec_stop == ["%h/7dtd-server/scripts/run.sh stop"],
)

timeouts = [int(m) for m in re.findall(r"^TimeoutStopSec=(\d+)$", service, re.MULTILINE)]
check(
    f"TimeoutStopSec covers the worst-case graceful stop ({WORST_STOP_SECS}s)",
    len(timeouts) == 1 and timeouts[0] >= WORST_STOP_SECS,
)

pinned_env = re.findall(r"^Environment=(TELNET_PASSWORD|TELNET_PORT)=", text, re.MULTILINE)
check(
    "unit does not hardcode TELNET_PASSWORD/TELNET_PORT (init_telnet_env owns them)",
    pinned_env == [],
)

init_lines = re.findall(r"^Init=(.*)$", text, re.MULTILINE)
check("Init=true (catatonit zombie reaper, same as start() in run.sh)", init_lines == ["true"])

# Durability: a crashed or host-rebooted server must come back on its own
# (AGENTS.md: the quadlet is the durable lifecycle), and the game/telnet/
# dashboard ports are only reachable on the LAN through host networking.
restart_lines = re.findall(r"^Restart=(.*)$", text, re.MULTILINE)
check("Restart=always (a dead server must come back on its own)", restart_lines == ["always"])
network_lines = re.findall(r"^Network=(.*)$", text, re.MULTILINE)
check(
    "Network=host (game 26900 / telnet / dashboard ports are LAN-reachable)",
    network_lines == ["host"],
)

if failed_checks:
    sys.exit(1)
print("quadlet unit contract OK")
