#!/usr/bin/env python3
"""Pin the secret-transport contract of scripts/run.sh.

Methodology: TELNET_PASSWORD and WEBADMIN_PASSWORD must reach the container
through an owner-only env file passed via podman --env-file. Interpolating
them into -e K=V arguments would keep them world-readable in
/proc/<pid>/cmdline for the whole `podman run` (minutes during an
install-only download) and persist them in the container config; lib-env.sh
applies the same argv-versus-environment rule to telnet_session. Pin:

  env-file   make_common writes the secret env file with mktemp and passes
             --env-file, and an EXIT trap removes it
  argv       no -e/--env argument names either secret variable

Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUN_SH = ROOT / "scripts" / "run.sh"

failed_checks: list[str] = []


def check(name: str, cond: bool) -> None:
    if cond:
        print(f"OK: {name}")
    else:
        print(f"FAIL: {name}", file=sys.stderr)
        failed_checks.append(name)


text = RUN_SH.read_text(encoding="utf-8")

check(
    "make_common renders the secret env file with mktemp",
    'SECRET_ENV_FILE="$(mktemp' in text,
)
check(
    "secrets travel via --env-file",
    '--env-file "$SECRET_ENV_FILE"' in text,
)
check(
    "an EXIT trap removes the secret env file",
    bool(re.search(r"^trap cleanup_secret_env_file EXIT$", text, re.MULTILINE))
    and 'rm -f "$SECRET_ENV_FILE"' in text,
)

argv_secrets = re.findall(r"-e\s+(?:TELNET|WEBADMIN)_PASSWORD=", text)
check("no -e argument carries a secret", argv_secrets == [])

if failed_checks:
    sys.exit(1)
print("run.sh secret-transport contract OK")
