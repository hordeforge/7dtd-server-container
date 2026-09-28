#!/usr/bin/env python3
"""Unit tests for check-config-xml.py, run via `make test`.

Methodology: pin the CI-gate contract at its failure boundaries.
  no args     usage error, exit 2 (checking nothing must not read as success)
  --help      exit 0 on stdout, even beside file arguments
  valid file  exit 0 with a "well-formed" line
  bad XML     exit 1 with the script's own "<path>: NOT well-formed" error
  bad in a    exit 1 at the first bad file, in either batch position
  batch
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

from harness import check, exit_status

SCRIPT = Path(__file__).resolve().parent / "check-config-xml.py"


def run(*args: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, check=False)


with tempfile.TemporaryDirectory() as tmp:
    tmpdir = Path(tmp)
    good = tmpdir / "good.xml"
    good.write_text("<config><prop name='a'>1</prop></config>", encoding="utf-8")
    malformed = tmpdir / "bad.xml"
    malformed.write_text("<config><unclosed></config>", encoding="utf-8")
    # A declared encoding is the file's own statement about its bytes, and the
    # parse must follow it: config files carry player and world names, so
    # non-ASCII text is normal content, not a corrupt file.
    utf8 = tmpdir / "utf8.xml"
    utf8.write_text(
        "<?xml version='1.0' encoding='utf-8'?>\n"
        "<config><prop name='a'>café \U0001f600</prop></config>",
        encoding="utf-8",
    )

    r = run()
    check("no args exits 2", r.returncode == 2)
    check(
        "no args prints usage with the operand list on stderr",
        b"usage:" in r.stderr and b"FILE [FILE ...]" in r.stderr and r.stdout == b"",
    )

    r = run("--help")
    check("help exits 0 on stdout", r.returncode == 0 and b"FILE [FILE ...]" in r.stdout)
    check("help writes nothing to stderr", r.stderr == b"")
    # Help wins wherever it appears, so a file argument beside it must not be
    # parsed (and cannot turn the run into a parse failure).
    r = run(str(malformed), "--help")
    check(
        "help wins over file arguments (no per-file report, no parse failure)",
        r.returncode == 0 and r.stdout == run("--help").stdout and r.stderr == b"",
    )

    r = run(str(good))
    check("valid file exits 0", r.returncode == 0)
    check("valid file reported well-formed", b"well-formed" in r.stdout)

    r = run(str(utf8))
    check("UTF-8 declared file exits 0", r.returncode == 0)
    check("UTF-8 declared file reported well-formed", b"well-formed" in r.stdout)
    prop = ET.parse(utf8).getroot().find("prop")
    check(
        "non-ASCII content survives the parse",
        prop is not None and prop.text == "café \U0001f600",
    )

    # The malformed file must be named in the error so an operator can go
    # straight to it; ParseError detail rides along. The script's own
    # "NOT well-formed" wording is the contract: the exception's strerror
    # alone would also contain the path, so matching only the name would pass
    # even if the script printed nothing but the exception.
    r = run(str(malformed))
    check("malformed XML exits 1", r.returncode == 1)
    check(
        "malformed XML names the file in the script's error",
        f"{malformed}: NOT well-formed".encode() in r.stderr,
    )
    try:
        ET.parse(malformed)
        parse_raises = False
    except ET.ParseError:
        parse_raises = True
    check("test fixture is genuinely malformed", parse_raises)

    r = run(str(tmpdir / "absent.xml"))
    check("missing file exits 1", r.returncode == 1)
    check("missing file named in the script's error", b"absent.xml: NOT well-formed" in r.stderr)

    # Multiple files: one bad apple must fail the batch in either position,
    # and name it so the operator goes straight to the culprit.
    r = run(str(good), str(malformed))
    check("one bad file fails the batch", r.returncode == 1)
    check("batch failure names the bad file", str(malformed).encode() in r.stderr)
    check("the good file ahead of the bad one was reported", str(good).encode() in r.stdout)
    r = run(str(malformed), str(good))
    check("a bad first file fails the batch too", r.returncode == 1)
    check("the batch stops at the first bad file", str(good).encode() not in r.stdout)

    # A bad file must not cut the batch short: every file is reported, so the
    # operator sees all the breakage in one run instead of one file per fix.
    second_bad = tmpdir / "bad2.xml"
    second_bad.write_text("<config><unclosed>")
    r = run(str(malformed), str(second_bad), str(good))
    check("every file in a failing batch is reported", b"bad2.xml" in r.stderr)
    check("a good file after a bad one is still checked", str(good).encode() in r.stdout)

    # OSError path beyond a missing file: a directory opens but cannot be
    # parsed (IsADirectoryError); must exit 1 cleanly, not traceback.
    r = run(str(tmpdir))
    check("directory input exits 1", r.returncode == 1)
    check(
        "directory input named in the script's error",
        f"{tmpdir}: NOT well-formed".encode() in r.stderr,
    )

exit_status()
print("check-config-xml rules OK")
