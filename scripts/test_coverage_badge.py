#!/usr/bin/env python3
"""Unit tests for coverage_badge.py, run via `make test`.

Methodology: pin the rendering contract at its boundaries.
  main()     Cobertura line-rate parsing, half-up rounding of exact ties
             (the documented binary-float distortion case), the missing-
             attribute default, and the usage-error exit code
  colour()   every threshold inclusive; one step below drops to the next band
  badge SVG  well-formed XML whose text nodes carry label + percentage and
             whose value rect carries the band colour
Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""
from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import coverage_badge

NS = "{http://www.w3.org/2000/svg}"
failures = 0


def check(name: str, cond: bool) -> None:
    global failures
    if cond:
        print(f"OK: {name}")
    else:
        print(f"FAIL: {name}", file=sys.stderr)
        failures += 1


def render(line_rate_attr: str | None) -> tuple[int, ET.Element]:
    """Run main() on a minimal Cobertura report; return (rc, parsed SVG root)."""
    attr = "" if line_rate_attr is None else f' line-rate="{line_rate_attr}"'
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "cobertura.xml"
        dst = Path(tmp) / "badge.svg"
        src.write_text(f"<coverage{attr}/>")
        rc = coverage_badge.main(["coverage_badge", str(src), str(dst)])
        return rc, ET.fromstring(dst.read_text())


def svg_texts(root: ET.Element) -> list[str]:
    return [t.text or "" for t in root.iter(f"{NS}text")]


rc, root = render("0.985")
check("render exits 0", rc == 0)
check("0.985 rounds half-up to 99%", svg_texts(root) == ["coverage", "99%"])
check("aria-label carries the rounded value", root.get("aria-label") == "coverage: 99%")

rc, root = render("0.98")
check("0.98 renders 98%", rc == 0 and svg_texts(root) == ["coverage", "98%"])

rc, root = render(None)
check("missing line-rate defaults to 0%", rc == 0 and svg_texts(root) == ["coverage", "0%"])

with contextlib.redirect_stderr(io.StringIO()):
    usage_rc = coverage_badge.main(["coverage_badge"])
check("usage error exits 2", usage_rc == 2)

# Colour bands: thresholds inclusive, the value below falls through.
for pct, fill in [
    (90, "#4c1"), (89, "#97ca00"),
    (75, "#97ca00"), (74, "#dfb317"),
    (60, "#dfb317"), (59, "#fe7d37"),
    (40, "#fe7d37"), (39, "#e05d44"),
    (0, "#e05d44"),
]:
    check(f"colour({pct}) == {fill}", coverage_badge.colour(pct) == fill)

_, root = render("0.75")
fills = [r.get("fill") for r in root.iter(f"{NS}rect")]
check("value rect carries the band colour", "#97ca00" in fills)

if failures:
    sys.exit(1)
print("coverage_badge rules OK")
