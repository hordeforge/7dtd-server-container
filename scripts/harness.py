#!/usr/bin/env python3
"""Shared check reporter for the scripts/test_*.py suites.

Each suite prints one OK line per pinned behavior and exits nonzero if any
failed, so one shared reporter keeps the reporting contract in one place.
"""

from __future__ import annotations

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


def exit_status() -> None:
    if failed_checks:
        sys.exit(1)
