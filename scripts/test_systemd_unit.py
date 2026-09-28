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
  liveness        the unit probes the shipped lib (scripts/lib-env.sh
                  health_check) for a container that is up but no longer
                  serving, with a start period covering the first-boot depot
                  download, and never restarts on the status alone.

Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import re

from harness import ROOT, check, exit_status

UNIT = ROOT / "systemd" / "7dtd-server.container"

# Worst-case graceful-stop path in seconds (see module docstring); the unit
# timeout must exceed it or systemd force-kills mid-save.
WORST_STOP_SECS = 3 + 10 + 90 + 30


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


def environment_names(unit_text: str) -> set[str]:
    """Every variable named by any Environment= assignment in the unit.

    systemd accepts several forms a line-anchored regex misses: leading
    indentation, and one line carrying several assignments
    (`Environment=A=1 TELNET_PORT=9999`). Reading the names, not the lines,
    is what the "no second default" contract is about.
    """
    names: set[str] = set()
    for line in unit_text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if stripped.startswith("Environment="):
            for assignment in stripped.removeprefix("Environment=").split():
                names.add(assignment.partition("=")[0])
    return names


pinned_env = environment_names(text) & {"TELNET_PASSWORD", "TELNET_PORT"}
check(
    "unit does not hardcode TELNET_PASSWORD/TELNET_PORT (init_telnet_env owns them)",
    not pinned_env,
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

# Liveness: same probe as run.sh start, so a container that is up but no
# longer serving shows up as unhealthy. The command must reach the port
# through the lib baked into the image (init_telnet_env owns it), never a
# port number written a second time here.
health_cmd = re.findall(r"^HealthCmd=(.*)$", text, re.MULTILINE)
check(
    "unit health probe calls the lib shipped in the image",
    health_cmd == ["bash -c 'source /usr/local/lib/7dtd-lib-env.sh && health_check'"],
)
check(
    "unit carries a health interval and a start period for the first boot",
    re.findall(r"^HealthInterval=(.*)$", text, re.MULTILINE) == ["60s"]
    and re.findall(r"^HealthStartPeriod=(.*)$", text, re.MULTILINE) == ["30m"]
    and re.findall(r"^HealthRetries=(\d+)$", text, re.MULTILINE) != [],
)

# Least privilege: container root is a deliberate choice (rootless podman maps
# it to the host user), and nothing in the image needs a setuid escalation.
podman_args = re.findall(r"^PodmanArgs=(.*)$", text, re.MULTILINE)
check(
    "PodmanArgs keeps no-new-privileges on every start",
    len(podman_args) == 1 and podman_args[0].strip() == "--security-opt=no-new-privileges",
)

exit_status()
print("quadlet unit contract OK")
