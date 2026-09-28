#!/usr/bin/env python3
"""Check that the given XML config files are well-formed (CI helper).

Usage: check-config-xml.py [--help] FILE [FILE ...]

`--help` prints this text on stdout and exits 0.
Exits 2 on a missing file list (checking nothing must never read as
success), 1 when any file fails to parse or open.
"""

import sys
import xml.etree.ElementTree as ET


def check(path: str) -> bool:
    """Parse one file; report it on the right stream. True when well-formed.

    Every parse failure is a report, never an exception: the batch keeps
    going and the gate exits 1 with the offending path named.
    """
    try:
        ET.parse(path)
    except (ET.ParseError, OSError, LookupError, ValueError) as exc:
        # LookupError and ValueError are the two ways an XML *declaration*
        # escapes ParseError: an encoding name no codec registry knows
        # ("x-mac-roman", a config edited on a workstation) and a multi-byte
        # encoding expat refuses ("utf-7", "UTF-32"). Both are statements
        # about the file, so the file is not well-formed as declared and takes
        # the same report path as a syntax error instead of a traceback.
        print(f"{path}: NOT well-formed ({exc})", file=sys.stderr)
        return False
    print(path, "well-formed")
    return True


def main(argv: list[str]) -> int:
    # Help wins wherever it appears, like every common CLI parser.
    if any(a in ("-h", "--help") for a in argv[1:]):
        print(__doc__.strip())
        return 0
    files = argv[1:]
    if not files:
        print(f"usage: {argv[0]} FILE [FILE ...]", file=sys.stderr)
        return 2
    # Every file in the batch is checked, not just the ones before the first
    # bad one: a batch that stops at the first failure leaves the remaining
    # files unvalidated while still exiting 1, so a later breakage surfaces
    # only on the run after whoever fixes the first one. The results are
    # materialized first because all() short-circuits on the first False.
    results = [check(f) for f in files]
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
