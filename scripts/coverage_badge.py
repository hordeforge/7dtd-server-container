#!/usr/bin/env python3
"""Render the line-coverage badge SVG from a Cobertura XML report."""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from pathlib import Path


def colour(pct: int) -> str:
    if pct >= 90:
        return "#4c1"
    if pct >= 75:
        return "#97ca00"
    if pct >= 60:
        return "#dfb317"
    if pct >= 40:
        return "#fe7d37"
    return "#e05d44"


def badge(pct: int, fill: str) -> str:
    lw, vw = 64, 36
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{lw + vw}" height="20" role="img" aria-label="coverage: {pct}%">
<title>coverage: {pct}%</title>
<linearGradient id="s" x2="0" y2="100%"><stop offset="0" stop-color="#bbb" stop-opacity=".1"/><stop offset="1" stop-opacity=".1"/></linearGradient>
<clipPath id="r"><rect width="{lw + vw}" height="20" rx="3" fill="#fff"/></clipPath>
<g clip-path="url(#r)"><rect width="{lw}" height="20" fill="#555"/><rect x="{lw}" width="{vw}" height="20" fill="{fill}"/><rect width="{lw + vw}" height="20" fill="url(#s)"/></g>
<g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" font-size="11"><text x="{lw // 2}" y="14">coverage</text><text x="{lw + vw // 2}" y="14">{pct}%</text></g>
</svg>
"""


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} COBERTURA_XML OUTPUT.svg", file=sys.stderr)
        return 2
    try:
        root = ET.parse(argv[1]).getroot()
        # Parse the ratio as an exact decimal and round half-up to a whole
        # percent: going through binary float distorts ties unpredictably
        # (0.985 * 100 reads back as 98.4999... and displays 98 instead of 99).
        rate = Decimal(root.get("line-rate", "0"))
        if not rate.is_finite():
            # A quiet NaN survives the multiply and quantize below without
            # raising and would blow up in int() with an uncaught ValueError;
            # Infinity fails later inside quantize. Reject both here so every
            # bad value takes the one clean failure path.
            msg = f"line-rate must be finite, got '{rate}'"
            raise InvalidOperation(msg)
        pct = int((rate * 100).quantize(Decimal(1), rounding=ROUND_HALF_UP))
        Path(argv[2]).write_text(badge(pct, colour(pct)))
    except (OSError, ET.ParseError, ArithmeticError) as exc:
        # InvalidOperation (a non-numeric line-rate) is an ArithmeticError.
        print(f"{argv[0]}: cannot render badge from {argv[1]}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
