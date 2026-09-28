#!/usr/bin/env python3
"""Contract tests for the shipped container image (Containerfile).

Methodology: the image is built by hand on the server host and never pushed to
a registry, so nothing downstream inspects its metadata. That left the OCI
labels free to go stale and the entrypoint form unchecked until the game booted
badly on the host. Pin what a reader of the image alone can verify:
  labels    every OCI label a consumer reads is present, the license matches
            LICENSE, the source is this repository, and the version label is
            the VERSION file (the release tag is gated against VERSION, so a
            bump that skips the label would otherwise ship mismatched metadata)
  base      the base image is one build arg (BASE_IMAGE) resolved to a
            named registry reference, so a release cut can pin a digest
            without editing the Containerfile
  entrypoint exec form only, so PID 1 is the script and signals reach it
  payload   the two files entrypoint.sh sources at boot are the two COPYs, and
            the entrypoint is executable in the tree
Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTAINERFILE = ROOT / "Containerfile"
VERSION = ROOT / "VERSION"
LICENSE = ROOT / "LICENSE"

REPO_URL = "https://github.com/hordeforge/7dtd-server-container"

# Files the image must carry: the entrypoint and the telnet/env library it
# sources from the absolute path the Containerfile copies it to.
REQUIRED_COPIES = {"entrypoint.sh", "scripts/lib-env.sh"}

failed_checks: list[str] = []


def check(name: str, cond: bool) -> None:
    if cond:
        print(f"OK: {name}")
    else:
        print(f"FAIL: {name}", file=sys.stderr)
        failed_checks.append(name)


text = CONTAINERFILE.read_text(encoding="utf-8")
# A LABEL block spans continuation lines; flatten them before parsing.
flat = re.sub(r"\\\n", " ", text)
labels: dict[str, str] = {}
for line in re.findall(r"^LABEL\s+(.*)$", flat, re.MULTILINE):
    labels.update(re.findall(r'([a-z0-9.\-]+)="([^"]*)"', line))

for key in (
    "org.opencontainers.image.title",
    "org.opencontainers.image.description",
    "org.opencontainers.image.source",
    "org.opencontainers.image.licenses",
    "org.opencontainers.image.version",
):
    check(f"{key} label present and non-empty", bool(labels.get(key, "").strip()))

version = VERSION.read_text(encoding="utf-8").strip()
check(
    f"version label matches VERSION ({version})",
    labels.get("org.opencontainers.image.version") == version,
)

license_id = LICENSE.read_text(encoding="utf-8").splitlines()[0].strip()
check(
    f"license label matches LICENSE ({license_id})",
    license_id.split()[0] in labels.get("org.opencontainers.image.licenses", ""),
)
check(
    "source label points at this repository",
    labels.get("org.opencontainers.image.source") == REPO_URL,
)

froms = re.findall(r"^FROM\s+(\S+)", text, re.MULTILINE)
check("exactly one FROM", len(froms) == 1)
base_args = re.findall(r"^ARG\s+BASE_IMAGE=(\S+)", text, re.MULTILINE)
check(
    "the base image is a single build arg the FROM consumes",
    len(base_args) == 1 and bool(froms) and froms[0] in {"${BASE_IMAGE}", "$BASE_IMAGE"},
)
check(
    "the default base image is a fully qualified registry reference",
    bool(base_args)
    and base_args[0].count("/") >= 1
    and (":" in base_args[0] or "@" in base_args[0]),
)

entrypoints = re.findall(r"^ENTRYPOINT\s+(.*)$", text, re.MULTILINE)
check(
    "ENTRYPOINT is exec form (PID 1 is the script, not a shell)",
    len(entrypoints) == 1 and entrypoints[0].startswith("["),
)

copies = re.findall(r"^COPY\s+(\S+)\s+", text, re.MULTILINE)
check(
    "COPY carries exactly the two files entrypoint.sh needs at boot",
    set(copies) == REQUIRED_COPIES,
)
check(
    "entrypoint.sh is executable in the tree", bool((ROOT / "entrypoint.sh").stat().st_mode & 0o111)
)

if failed_checks:
    sys.exit(1)
print("container image contract OK")
