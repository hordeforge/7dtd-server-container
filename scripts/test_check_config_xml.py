#!/usr/bin/env python3
"""Unit tests for check-config-xml.py, run via `make test`.

Methodology: pin the CI-gate contract at its failure boundaries.
  no args     usage error, exit 2 (checking nothing must not read as success)
  valid file  exit 0 with a "well-formed" line
  bad XML     exit 1 with a named-file error on stderr
  missing/    exit 1 (OSError path: unreadable or absent input)
  unreadable
Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "check-config-xml.py"
failed_checks: list[str] = []


def check(name: str, cond: bool) -> None:
    if cond:
        print(f"OK: {name}")
    else:
        print(f"FAIL: {name}", file=sys.stderr)
        failed_checks.append(name)


def run(*args: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, check=False)


with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    good = tmpdir / "good.xml"
    good.write_text("<config><prop name='a'>1</prop></config>")
    malformed = tmpdir / "bad.xml"
    malformed.write_text("<config><unclosed></config>")

    r = run()
    check("no args exits 2", r.returncode == 2)
    check("no args prints usage on stderr", b"usage:" in r.stderr)

    r = run(str(good))
    check("valid file exits 0", r.returncode == 0)
    check("valid file reported well-formed", b"well-formed" in r.stdout)

    # The malformed file must be named in the error so an operator can go
    # straight to it; ParseError detail rides along.
    r = run(str(malformed))
    check("malformed XML exits 1", r.returncode == 1)
    check("malformed XML names the file", b"bad.xml" in r.stderr)
    try:
        ET.parse(malformed)
        parse_raises = False
    except ET.ParseError:
        parse_raises = True
    check("test fixture is genuinely malformed", parse_raises)

    r = run(str(tmpdir / "absent.xml"))
    check("missing file exits 1", r.returncode == 1)
    check("missing file named in error", b"absent.xml" in r.stderr)

    # Multiple files: one bad apple must fail the batch even after a good one.
    r = run(str(good), str(malformed))
    check("one bad file fails the batch", r.returncode == 1)

if failed_checks:
    sys.exit(1)
print("check-config-xml rules OK")
