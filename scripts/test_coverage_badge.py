#!/usr/bin/env python3
"""Unit tests for coverage_badge.py, run via `make test`.

Methodology: pin the rendering contract at its boundaries.
  main()     Cobertura line-rate parsing, half-up rounding of exact ties
             (the documented binary-float distortion case), the missing-
             attribute default, the usage-error exit code, and clean
             nonzero failures (with a named-input message) for malformed
             XML, non-numeric and non-finite (NaN/infinite) line-rate
             values, and unwritable outputs
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

from harness import check, exit_status

sys.path.insert(0, str(Path(__file__).resolve().parent))
import coverage_badge

NS = "{http://www.w3.org/2000/svg}"


def render(line_rate_attr: str | None) -> tuple[int, ET.Element]:
    """Run main() on a minimal Cobertura report; return (rc, parsed SVG root)."""
    attr = "" if line_rate_attr is None else f' line-rate="{line_rate_attr}"'
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "cobertura.xml"
        dst = Path(tmp) / "badge.svg"
        src.write_text(f"<coverage{attr}/>", encoding="utf-8")
        rc = coverage_badge.main(["coverage_badge", str(src), str(dst)])
        return rc, ET.fromstring(dst.read_text(encoding="utf-8"))


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

err = io.StringIO()
with contextlib.redirect_stderr(err):
    usage_rc = coverage_badge.main(["coverage_badge"])
check("usage error exits 2", usage_rc == 2)
# len(argv) != 3, so under- and over-long invocations must be refused too: a
# bare `len(argv) < 3` guard would let a 4-argument call write a badge.
with contextlib.redirect_stderr(io.StringIO()):
    too_few = coverage_badge.main(["coverage_badge", "only-one-operand"])
    too_many = coverage_badge.main(["coverage_badge", "a.xml", "b.svg", "c"])
check("two operands exit 2", too_few == 2)
check("four operands exit 2", too_many == 2)
# The usage line must name both operands so a wrong invocation is diagnosable
# without opening the script (same contract the check-config-xml tests pin).
usage = err.getvalue()
check("usage line names both operands", "COBERTURA_XML" in usage and "OUTPUT.svg" in usage)


# Failure paths must exit 1 with a message naming the input, never a raw
# traceback (the badge step runs unattended in CI; the operator needs the
# culprit file, not a stack). A failed render must also leave the destination
# untouched: a stale badge from an earlier run is exactly the false green this
# script exists to prevent, and a partial write before validation would be
# indistinguishable from it.
STALE_BADGE = "<svg>previous run</svg>"


def failing(content: str, out_name: str = "badge.svg") -> int:
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        src = tmpdir / "cobertura.xml"
        dst = tmpdir / out_name
        src.write_text(content, encoding="utf-8")
        dst.write_text(STALE_BADGE, encoding="utf-8")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = coverage_badge.main(["coverage_badge", str(src), str(dst)])
        check(f"failure names the input ({content!r})", "cobertura.xml" in err.getvalue())
        check(
            f"failed render left the destination untouched ({content!r})",
            dst.read_text() == STALE_BADGE,
        )
        return rc


check("malformed XML exits 1", failing("<coverage><unclosed>") == 1)
check("non-numeric line-rate exits 1", failing('<coverage line-rate="abc"/>') == 1)
# An empty attribute is the realistic truncation shape a broken report takes.
check("empty line-rate exits 1", failing('<coverage line-rate=""/>') == 1)
# Quiet NaN survives Decimal arithmetic and quantize without raising; without
# the finite guard only the final int() would blow up, as an uncaught
# ValueError traceback. Both non-finite forms must take the clean path.
check("NaN line-rate exits 1", failing('<coverage line-rate="NaN"/>') == 1)
check("infinite line-rate exits 1", failing('<coverage line-rate="Infinity"/>') == 1)

# Unwritable output directory: OSError must surface as exit 1, not a crash.
with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / "cobertura.xml"
    src.write_text('<coverage line-rate="0.5"/>', encoding="utf-8")
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        rc = coverage_badge.main(
            ["coverage_badge", str(src), str(Path(tmp) / "no-such-dir" / "badge.svg")]
        )
check("unwritable output exits 1", rc == 1)

# Colour bands: thresholds inclusive, the value below falls through.
for pct, fill in [
    (90, "#4c1"),
    (89, "#97ca00"),
    (75, "#97ca00"),
    (74, "#dfb317"),
    (60, "#dfb317"),
    (59, "#fe7d37"),
    (40, "#fe7d37"),
    (39, "#e05d44"),
    (0, "#e05d44"),
]:
    check(f"colour({pct}) == {fill}", coverage_badge.colour(pct) == fill)

# The value rect must be the third one and the one starting at the label
# width: a bare membership test would pass with the band colour painted on
# the clip rect, the label rect, or the gradient overlay.
_, root = render("0.75")
rects = list(root.iter(f"{NS}rect"))
check("the four rects keep their clip/label/value/overlay order", len(rects) == 4)
value_rect = rects[2] if len(rects) == 4 else ET.Element("rect")
check(
    "value rect carries the band colour at the label boundary "
    f"(rects: {[r.get('fill') for r in rects]})",
    value_rect.get("fill") == "#97ca00"
    and value_rect.get("x") == "64"
    and value_rect.get("width") == "36"
    and value_rect.get("height") == "20",
)

exit_status()
print("coverage_badge rules OK")
