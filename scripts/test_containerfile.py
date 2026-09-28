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
from fnmatch import fnmatch
from pathlib import Path, PurePosixPath

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

# tzdata asks a debconf question; a noninteractive front end is what keeps the
# apt step from blocking on a prompt, or from answering itself differently on
# two machines and producing two images from one tree.
check(
    "the apt step runs non-interactively",
    re.search(r"^ARG\s+DEBIAN_FRONTEND=noninteractive\s*$", text, re.MULTILINE) is not None,
)

entrypoints = re.findall(r"^ENTRYPOINT\s+(.*)$", text, re.MULTILINE)
check(
    "ENTRYPOINT is exec form (PID 1 is the script, not a shell)",
    len(entrypoints) == 1 and entrypoints[0].startswith("["),
)

# The apt install runs debconf (tzdata asks for a zone) with no terminal to
# answer on. A build ARG keeps that answer out of the runtime image; an ENV
# would leave every later apt run in the container silently non-interactive.
check(
    "the apt layer is non-interactive, via a build ARG that does not persist",
    re.findall(r"^ARG\s+DEBIAN_FRONTEND=(\S+)$", text, re.MULTILINE) == ["noninteractive"]
    and re.findall(r"^ENV\s+DEBIAN_FRONTEND", text, re.MULTILINE) == [],
)

copies = re.findall(r"^COPY\s+(\S+)\s+", text, re.MULTILINE)
check(
    "COPY carries exactly the two files entrypoint.sh needs at boot",
    set(copies) == REQUIRED_COPIES,
)
check(
    "entrypoint.sh is executable in the tree", bool((ROOT / "entrypoint.sh").stat().st_mode & 0o111)
)


def ignored_by(path: str, rules: list[str]) -> bool:
    """Whether a build-context-relative path is dropped by these ignore rules.

    The subset of the pattern language this repo's .dockerignore uses: a
    comment line, `!` negation, and a glob with no `/` matched against the
    basename at any depth (a pattern with a `/` is matched against the whole
    relative path). The last matching rule wins, which is what makes the
    negations after the blanket `*` work.
    """
    parts = PurePosixPath(path).parts
    excluded = False
    for raw in rules:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        negate = line.startswith("!")
        pattern = line[1:] if negate else line
        pattern = pattern.rstrip("/")
        target = PurePosixPath(path).name if "/" not in pattern else path
        if fnmatch(target, pattern) or any(fnmatch(part, pattern) for part in parts[:-1]):
            excluded = not negate
    return excluded


# The image is never built in CI, so a rule that quietly drops a COPY source
# out of the build context would not fail a gate: the error surfaces on the
# server host at `podman build` time, and only as a missing file. .containerignore
# takes precedence when it exists, so that is the one read when there is one.
containerignore = ROOT / ".containerignore"
dockerignore = ROOT / ".dockerignore"
ignore_file = containerignore if containerignore.is_file() else dockerignore
check("the build context has a .dockerignore", ignore_file.is_file())
if ignore_file.is_file():
    rules = ignore_file.read_text(encoding="utf-8").splitlines()
    dropped = sorted(p for p in REQUIRED_COPIES if ignored_by(p, rules))
    check(
        f"every COPY source survives {ignore_file.name}",
        not dropped,
    )
    if dropped:
        print(f"      dropped from the build context: {', '.join(dropped)}", file=sys.stderr)

if failed_checks:
    sys.exit(1)
print("container image contract OK")
