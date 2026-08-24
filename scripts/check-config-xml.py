#!/usr/bin/env python3
"""Check that the given XML config files are well-formed (CI helper).

Usage: check-config-xml.py FILE [FILE ...]

Exits 2 on a missing file list (checking nothing must never read as
success), 1 when any file fails to parse or open.
"""

import sys
import xml.etree.ElementTree as ET


def main(argv: list[str]) -> int:
    files = argv[1:]
    if not files:
        print(f"usage: {argv[0]} FILE [FILE ...]", file=sys.stderr)
        return 2
    for f in files:
        try:
            ET.parse(f)
        except (ET.ParseError, OSError) as exc:
            print(f"{f}: NOT well-formed ({exc})", file=sys.stderr)
            return 1
        print(f, "well-formed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
