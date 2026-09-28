#!/usr/bin/env python3
"""Unit tests pinning the quadlet unit contract (systemd/7dtd-server.container)
and the daily save backup (systemd/7dtd-backup.{service,timer}).

Methodology: the unit is the durable lifecycle and it must not drift from the
decisions the ad-hoc lifecycle (scripts/run.sh) owns. The contracts pinned
here:

  graceful stop   the game ignores SIGTERM (no world save), so every
                  systemd-driven stop/restart/shutdown must go through
                  scripts/run.sh stop (telnet save+shutdown, bounded wait,
                  forced-stop fallback) with a TimeoutStopSec covering the
                  whole command: the ops-lock wait run.sh does first
                  (LOCK_WAIT_SECS) plus the stop path (probe 3s + session
                  10s + podman wait 90s + podman stop 30s).
  shared defaults TELNET_PASSWORD/TELNET_PORT are owned by init_telnet_env in
                  scripts/lib-env.sh (baked into the image); hardcoding them
                  as Environment= lines here would create a second default
                  that can silently drift.
  durability      Restart=always brings a crashed server back on its own,
                  with no start rate limit in the way (systemd's default
                  5-in-10s stops a crash-looping server for good, which is
                  the one case the boot-id log is written for), Init=true
                  reaps orphans for the whole uptime, and Network=host is
                  what makes the game/telnet/dashboard ports LAN-reachable
                  at all.
  liveness        the unit probes the shipped lib (scripts/lib-env.sh
                  health_check) for a container that is up but no longer
                  serving, with a start period covering the first-boot depot
                  download, and never restarts on the status alone.
  backup schedule the timer runs the same `run.sh backup` an operator runs,
                  daily, and catches up a missed day at the next boot: the
                  world is unrecoverable past the last archive, so the RPO
                  is the age of whatever ran last.

Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import re
import sys

from harness import ROOT, check, exit_status

UNIT = ROOT / "systemd" / "7dtd-server.container"

# Worst-case graceful-stop path in seconds, excluding the ops-lock wait
# run.sh does before the stop itself (see module docstring); the unit timeout
# must exceed lock wait + this, or systemd force-kills mid-save.
STOP_PATH_SECS = 3 + 10 + 90 + 30


def run_sh_value(name: str) -> int:
    """One integer assignment from scripts/run.sh, e.g. LOCK_WAIT_SECS=120.

    Read from the script rather than restated here: the unit's stop budget is
    only correct as long as it tracks the wait run.sh actually performs, and a
    literal on this side drifts silently the moment that constant moves.
    """
    source = (ROOT / "scripts" / "run.sh").read_text(encoding="utf-8")
    matches = re.findall(rf"^{name}=(\d+)$", source, re.MULTILINE)
    if len(matches) != 1:
        sys.exit(f"expected exactly one {name}=<int> in scripts/run.sh, found {len(matches)}")
    return int(matches[0])


LOCK_WAIT_SECS = run_sh_value("LOCK_WAIT_SECS")
WORST_STOP_SECS = LOCK_WAIT_SECS + STOP_PATH_SECS


text = UNIT.read_text(encoding="utf-8")
service = text.split("[Service]", 1)[1] if "[Service]" in text else ""

exec_stop = re.findall(r"^ExecStop=(.*)$", service, re.MULTILINE)
check(
    "ExecStop routes stops through scripts/run.sh stop",
    exec_stop == ["%h/7dtd-server/scripts/run.sh stop"],
)

timeouts = [int(m) for m in re.findall(r"^TimeoutStopSec=(\d+)$", service, re.MULTILINE)]
check(
    f"TimeoutStopSec covers the lock wait plus the worst-case stop ({WORST_STOP_SECS}s)",
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
# Restart=always is only that without the start limit lifted: systemd's default
# of 5 starts in 10s turns the crash loop into a permanently failed unit, and
# the boot-id log the recovery path depends on then has no last boot to read.
start_limits = re.findall(r"^StartLimitIntervalSec=(\d+)$", text, re.MULTILINE)
check(
    "no start rate limit (a crash loop must not end in a failed unit)",
    start_limits == ["0"],
)
network_lines = re.findall(r"^Network=(.*)$", text, re.MULTILINE)
check(
    "Network=host (game 26900 / telnet / dashboard ports are LAN-reachable)",
    network_lines == ["host"],
)
# The image is built on this host and never published, so quadlet's default
# Pull=missing would only hide that until a prune leaves the unit pulling from
# a registry that does not exist here.
pull_lines = re.findall(r"^Pull=(.*)$", text, re.MULTILINE)
check("Pull=never (the image is built locally, never published)", pull_lines == ["never"])

# Liveness: same probe as run.sh start, so a container that is up but no
# longer serving shows up as unhealthy. The command must reach the port
# through the lib baked into the image (init_telnet_env owns it), never a
# port number written a second time here.
# The unit cannot call into run.sh, so the probe string is written twice; pin
# the two copies against each other here or a fix to one silently leaves the
# other probing a different thing.
run_sh = (ROOT / "scripts" / "run.sh").read_text(encoding="utf-8")
run_health_cmd = re.findall(r'^HEALTH_CMD="(.*)"$', run_sh, re.MULTILINE)
health_cmd = re.findall(r"^HealthCmd=(.*)$", text, re.MULTILINE)
check("run.sh carries exactly one health probe command", len(run_health_cmd) == 1)
check(
    "unit health probe calls the lib shipped in the image",
    run_health_cmd == ["bash -c 'source /usr/local/lib/7dtd-lib-env.sh && health_check'"]
    and health_cmd == run_health_cmd,
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

print("quadlet unit contract OK")

# The backup timer is what bounds the RPO: a world whose only copy is the last
# time someone remembered to run the backup has no bound at all. Its contract:
#
#  schedule   the service runs scripts/run.sh backup, the same command the
#             operator runs by hand, so the scheduled and ad-hoc paths cannot
#             drift apart
#  persistence Persistent=true runs a missed day at the next boot instead of
#             dropping it, and a nonzero exit (a failed backup) leaves the
#             unit failed where systemd's status and the journal can see it
backup_service = (ROOT / "systemd" / "7dtd-backup.service").read_text(encoding="utf-8")
backup_timer = (ROOT / "systemd" / "7dtd-backup.timer").read_text(encoding="utf-8")

exec_start = re.findall(r"^ExecStart=(.*)$", backup_service, re.MULTILINE)
check(
    "the backup timer runs scripts/run.sh backup",
    exec_start == ["%h/7dtd-server/scripts/run.sh backup"],
)
check(
    "the backup service is a oneshot (no daemon to supervise)",
    re.findall(r"^Type=(.*)$", backup_service, re.MULTILINE) == ["oneshot"],
)
check(
    "the backup service needs no privilege escalation",
    re.findall(r"^NoNewPrivileges=(.*)$", backup_service, re.MULTILINE) == ["yes"],
)
# The backup takes the same ops lock the stop does, so its budget has to carry
# the same wait: a timer that fires behind an operator's restore is the ordinary
# case, not the exception, and a budget that ends mid-archive leaves a partial
# file for the next prune to remove.
backup_timeouts = [
    int(m) for m in re.findall(r"^TimeoutStartSec=(\d+)$", backup_service, re.MULTILINE)
]
check(
    f"the backup timeout covers the lock wait ({LOCK_WAIT_SECS}s)",
    len(backup_timeouts) == 1 and backup_timeouts[0] > LOCK_WAIT_SECS,
)
check(
    "a missed backup runs at the next boot (Persistent=true)",
    re.findall(r"^Persistent=(.*)$", backup_timer, re.MULTILINE) == ["true"],
)
check(
    "the timer targets the backup service",
    re.findall(r"^Unit=(.*)$", backup_timer, re.MULTILINE) == ["7dtd-backup.service"],
)
check(
    "the timer is installed into timers.target",
    re.findall(r"^WantedBy=(.*)$", backup_timer, re.MULTILINE) == ["timers.target"],
)
calendars = re.findall(r"^OnCalendar=(.*)$", backup_timer, re.MULTILINE)
check("the timer has a daily schedule", len(calendars) == 1 and "-*-*" in calendars[0])

# The readability check is the other half: a backup nobody can read back is a
# hypothesis, and the daily timer's exit code only speaks for the run that
# wrote the file. The weekly verify runs the same command an operator runs by
# hand, exits nonzero when an archive is unreadable or the newest is older
# than the daily schedule allows, and so leaves the unit failed where
# systemd's status and the journal can see it, like the backup timer does.
verify_service = (ROOT / "systemd" / "7dtd-backup-verify.service").read_text(encoding="utf-8")
verify_timer = (ROOT / "systemd" / "7dtd-backup-verify.timer").read_text(encoding="utf-8")

check(
    "the verify timer runs scripts/run.sh verify-backup",
    re.findall(r"^ExecStart=(.*)$", verify_service, re.MULTILINE)
    == ["%h/7dtd-server/scripts/run.sh verify-backup"],
)
check(
    "the verify service is a oneshot (no daemon to supervise)",
    re.findall(r"^Type=(.*)$", verify_service, re.MULTILINE) == ["oneshot"],
)
check(
    "a missed verify runs at the next boot (Persistent=true)",
    re.findall(r"^Persistent=(.*)$", verify_timer, re.MULTILINE) == ["true"],
)
check(
    "the verify timer targets the verify service",
    re.findall(r"^Unit=(.*)$", verify_timer, re.MULTILINE) == ["7dtd-backup-verify.service"],
)
check(
    "the verify timer is installed into timers.target",
    re.findall(r"^WantedBy=(.*)$", verify_timer, re.MULTILINE) == ["timers.target"],
)
verify_calendars = re.findall(r"^OnCalendar=(.*)$", verify_timer, re.MULTILINE)
check(
    "the verify timer has a weekly schedule",
    len(verify_calendars) == 1 and "Mon" in verify_calendars[0],
)
check(
    "the verify never runs at the same minute as the daily backup",
    verify_calendars[0].split()[-1].split(":")[0] != calendars[0].split()[-1].split(":")[0],
)
check(
    "the verify service never stops the server (it only reads archives)",
    "stop" not in verify_service.split("ExecStart=", 1)[1].splitlines()[0],
)

exit_status()
print("backup and verify timer contract OK")
