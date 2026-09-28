#!/usr/bin/env python3
"""Shared check reporter and sandbox PATH helper for the scripts/test_*.py
suites.

Each suite prints one OK line per pinned behavior and exits nonzero if any
failed, so one shared reporter keeps the reporting contract in one place.
resolved_bin_path is the one PATH builder the suites that sandbox a shell
script through a resolved toolchain share.
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
ROOT = SCRIPTS.parent

failed_checks: list[str] = []


def check(name: str, cond: bool) -> bool:
    """Print one line and return cond, so a caller can gate on a failed check."""
    if cond:
        print(f"OK: {name}")
    else:
        print(f"FAIL: {name}", file=sys.stderr)
        failed_checks.append(name)
    return cond


def resolved_bin_path(*bins: str) -> str:
    """A PATH carrying the tools the scripts under test shell out to.

    Those scripts run through /usr/bin/env bash, so PATH must resolve them.
    Resolve those directories from the running host instead of assuming a
    fixed /usr/bin:/bin, which is not where coreutils lives on NixOS, a
    brew-only prefix, or a slim test image.
    """
    dirs: set[Path] = set()
    for binary in bins:
        found = shutil.which(binary)
        if found is None:
            print(f"FAIL: required binary not found on PATH: {binary}", file=sys.stderr)
            sys.exit(1)
        dirs.add(Path(found).parent)
    return os.pathsep.join(str(d) for d in sorted(dirs))


def exit_status() -> None:
    if failed_checks:
        sys.exit(1)
