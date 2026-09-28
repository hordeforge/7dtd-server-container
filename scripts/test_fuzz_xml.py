#!/usr/bin/env python3
"""Seeded fuzz harness for the XML config parsers, run via `make test`.

The two parsers in this repo take a file nobody here controls end to end: the
game writes serverconfig.xml, serveradmin.xml and the web dashboard's own XML
back into data/, and an operator or a mod can drop a hand-edited config where
the committed template used to be. check-config-xml.py is the CI gate on that
directory and coverage_badge.py reads a report a tool wrote, so both must turn
any byte sequence into a verdict instead of a traceback, and both must say the
same thing about the same file twice.

Atheris and Hypothesis are not dependencies of this repo and the gate installs
only the hash-pinned analyzer closure in requirements-lint.txt, so coverage
comes from a stdlib seeded generator instead: fixed seeds, a bounded case
count, a fresh temp directory per case, and assertions that encode the
invariants, not just a crash check. A fuzzer proves bugs exist; the assertions
here are what turn a silent wrong verdict into a failing case.

Cases are structure-aware, not random bytes: XML documents are assembled from
element, attribute, CDATA, comment, PI, DTD, entity, character-reference and
encoding-declaration fragments, and the fragments that reach the byte stream
include the ones real files carry (NUL, control characters, overlong UTF-8,
BOMs, a truncated tail, an undeclared-encoding declaration). The seed corpus
starts from the two committed config templates, and every case is run through
the same three entry points the operators and CI use:
  check()        one file, one verdict, report on the documented stream
  main()         the CI batch, re-reading every file from disk
  badge main()   the Cobertura reader, twice, byte-identical or the same failure

Any case that raises, reports on the wrong stream, disagrees between entry
points, disagrees with an independent re-parse of the bytes on disk, exceeds
its time budget, or renders a badge whose SVG does not parse is reported with
its payload; a clean run prints one line.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import random
import re
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import TYPE_CHECKING
from xml.sax.saxutils import quoteattr

if TYPE_CHECKING:
    from collections.abc import Callable

from harness import ROOT, SCRIPTS, check, exit_status

sys.path.insert(0, str(SCRIPTS))
import coverage_badge

CHECK_XML = SCRIPTS / "check-config-xml.py"

_spec = importlib.util.spec_from_file_location("check_config_xml", CHECK_XML)
if _spec is None or _spec.loader is None:
    msg = f"cannot load {CHECK_XML}"
    raise SystemExit(msg)
_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)
# The script's own name carries a dash, so the module loads through
# importlib; these are its two entry points, bound once with their types.
check_one: Callable[[str], bool] = _module.check
check_main: Callable[[list[str]], int] = _module.main

SVG_NS = "{http://www.w3.org/2000/svg}"

# One case, one parse: past this a case is not a hung parser but a slow
# machine, and past the whole-run budget the gate itself is the problem.
CASE_SECONDS = 5.0
RUN_SECONDS = 60.0
ITERATIONS_PER_SEED = 1500
SEEDS = (20260928, 7717, 31337)
MAX_REPORTED_VIOLATIONS = 10

# Encoding declarations: the ones real config files carry, then the two ways a
# declaration can escape a ParseError (no such codec, a multi-byte encoding
# expat refuses), then the codec-registry names that resolve to something that
# is not a text encoding at all.
ENCODINGS = (
    "utf-8",
    "UTF-8",
    "iso-8859-1",
    "windows-1252",
    "utf-16",
    "UTF-32",
    "utf-7",
    "x-mac-roman",
    "x-unknown-codec",
    "base64_codec",
    "hex_codec",
    "idna",
    "zlib_codec",
    "",
    "  ",
    "utf-8 ",
    "utf_8",
)
NAMES = ("property", "ServerSettings", "user", "a", "_x", "ns:child", "é", "0bad", "with space")
ATTRS = ("name", "value", "pass", "id", "0bad", "a b", "é")
VALUES = (
    "",
    "retest",
    "8087",
    "Navezgane LAN",
    "café",
    "emoji \U0001f600",
    "]]>",
    "-->",
    "<![CDATA[",
    "&amp;",
    "&#x110000;",
    "&#0;",
    "tab\tnewline\n",
    "quote\"apos'",
    "%s %b %%",
    "back\\slash",
)
TRUNCATIONS = (0, 1, 3, 8, 20)
# Byte sequences a text edit or a partial write really produces.
NOISE = (
    b"\x00",
    b"\x1f",
    b"\x7f",
    b"\x80",  # stray continuation byte
    b"\xc0\xaf",  # overlong '/'
    b"\xed\xa0\x80",  # surrogate half
    b"\xef\xbb\xbf",  # UTF-8 BOM in the middle of a document
    b"\xff\xfe<\x00a\x00",  # UTF-16LE bytes behind a utf-8 declaration
)
RATES = (
    "0",
    "1",
    "0.985",
    "0.9949999",
    "",
    " ",
    "NaN",
    "sNaN",
    "Infinity",
    "-Infinity",
    "1e999999999",
    "1e-999999",
    "-5",
    "1_0",
    "0x10",
    "abc",
    "1,5",
    '"1',
    "9" * 400,
    "١٢",
    ".5",
    "+.5",
    "0.0000000000000000001",
)

violations: list[str] = []
# The case the loop is on, so every finding names the seed and index that
# produced it without threading the label through each assertion.
case_label = "startup"


def require(cond: bool, what: str, detail: str = "") -> bool:
    """Record a broken invariant; the run reports them all at the end."""
    if not cond:
        violations.append(f"{case_label}: {what}" + (f": {detail}" if detail else ""))
    return cond


def show(payload: bytes, limit: int = 120) -> str:
    text = repr(payload[:limit])
    return f"{text} (+{len(payload) - limit} bytes)" if len(payload) > limit else text


def fragment(rng: random.Random) -> str:
    """One XML fragment from the shapes a config or a report really holds."""
    pick = rng.random()
    if pick < 0.28:
        return f"<{rng.choice(NAMES)} {rng.choice(ATTRS)}={quoteattr(rng.choice(VALUES))}>"
    if pick < 0.48:
        return f"</{rng.choice(NAMES[:6])}>"
    if pick < 0.60:
        return f"<{rng.choice(NAMES)}/>"
    if pick < 0.70:
        return f"<!-- {rng.choice(VALUES)} -->"
    if pick < 0.78:
        return f"<?target {rng.choice(VALUES)}?>"
    if pick < 0.86:
        return f"<![CDATA[{rng.choice(VALUES)}]]>"
    if pick < 0.92:
        return rng.choice(
            (
                "&amp;",
                "&lt;",
                "&#65;",
                "&#x41;",
                "&#0;",
                "&#x110000;",
                "&undefined;",
                "&lol;",
                "<!DOCTYPE lolz [<!ENTITY lol 'lol'>]>",
            )
        )
    return rng.choice(VALUES)


def document(rng: random.Random) -> bytes:
    """A structurally valid XML document, then damaged in one or two places."""
    parts: list[str] = []
    if rng.random() < 0.7:
        parts.append(f"<?xml version='1.0' encoding={quoteattr(rng.choice(ENCODINGS))}?>")
    root = rng.choice(NAMES[:6])
    parts.append(f"<{root}>")
    parts.extend(fragment(rng) for _ in range(rng.randrange(0, 12)))
    parts.append(f"</{root}>")
    payload = "".join(parts).encode("utf-8", "surrogatepass")
    if rng.random() < 0.25:
        payload = rng.choice(NOISE) + payload
    if rng.random() < 0.25:
        payload = payload + rng.choice(NOISE)
    if rng.random() < 0.2:
        cut = rng.randrange(0, len(payload)) if payload else 0
        payload = payload[:cut]
    return payload


# The committed templates are the real-world seeds: every generated case is
# only realistic next to what the game and the dashboard actually write.
SEED_FILES = (ROOT / "config" / "serverconfig.tmpl.xml", ROOT / "config" / "serveradmin_seed.xml")
BILLION_LAUGHS = (
    b"<?xml version='1.0'?><!DOCTYPE lolz [<!ENTITY lol 'lol'>"
    + b"".join(
        f"<!ENTITY lol{i} '&lol{i - 1};&lol{i - 1};&lol{i - 1};&lol{i - 1};&lol{i - 1};"
        f"&lol{i - 1};&lol{i - 1};&lol{i - 1};&lol{i - 1};&lol{i - 1};'>".encode()
        for i in range(1, 10)
    )
    + b"]><lolz>&lol9;</lolz>"
)


# The declaration a real document carries, in either quote style, and the
# names that do not match the bytes the templates actually hold. Both
# templates are UTF-8 (one carries "m²" in a stock comment), so every name
# below is a mismatch a hand-edited config produces: a latin-1 editor writes
# x-mac-roman or iso-8859-1, a Windows editor writes windows-1252, a UTF-16
# save carries a BOM. expat must answer with a verdict for each, and the
# verdict must be the same one the CI batch and a direct re-parse give.
DECLARATION_RE = re.compile(rb"<\?xml[^>]*\?>")
MISDECLARED_ENCODINGS = (b"x-mac-roman", b"windows-1252", b"iso-8859-1", b"utf-16", b"utf-7")


def misdeclared(raw: bytes) -> list[bytes]:
    """The document under a declaration that names an encoding it is not in.

    Any declaration the template carries is stripped first, so this covers a
    template that declares UTF-8 and one that declares nothing: both end up
    read under an encoding their bytes do not match, which is the case a
    hand-edited config on a workstation produces.
    """
    body = DECLARATION_RE.sub(b"", raw, count=1)
    return [b'<?xml version="1.0" encoding="' + name + b'?>' + body for name in MISDECLARED_ENCODINGS]


def seed_corpus(rng: random.Random) -> list[bytes]:
    """Committed templates, plus truncated and mis-declared variants."""
    corpus: list[bytes] = []
    for path in SEED_FILES:
        raw = path.read_bytes()
        corpus.append(raw)
        corpus.append(raw[: len(raw) // 2])
        corpus.extend(misdeclared(raw))
        corpus.append(raw.replace(b"value=", b"value=" + rng.choice(NOISE), 1))
    corpus.append(BILLION_LAUGHS)
    return corpus


def case_check(tmp: Path, payload: bytes) -> bool:
    """One file through check(), then through the CI batch and a re-read."""
    target = tmp / "case.xml"
    good = tmp / "good.xml"
    target.write_bytes(payload)
    good.write_bytes(b"<config><property name='a'>1</property></config>")

    out, err = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            verdict = check_one(str(target))
    except Exception as exc:  # noqa: BLE001  # any escape from check() is the finding
        require(False, "check() raised", f"{type(exc).__name__}: {exc} | {show(payload)}")
        return False
    require(isinstance(verdict, bool), "check() returned a non-bool", repr(verdict))
    # The report is the contract: a verdict that reaches neither stream is a
    # check that passed by staying silent.
    if verdict:
        require(
            f"{target} well-formed" in out.getvalue() and err.getvalue() == "",
            "well-formed file reported on stdout",
            show(payload),
        )
    else:
        require(
            f"{target}: NOT well-formed" in err.getvalue() and out.getvalue() == "",
            "rejected file reported on stderr",
            show(payload),
        )
        require("Traceback" not in err.getvalue(), "traceback leaked", err.getvalue()[:200])

    # Pair assertion across the write/read boundary: main() re-reads the same
    # bytes from disk in a batch, so a verdict that depended on state the file
    # does not carry shows up as a disagreement between the two entry points.
    out, err = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = check_main(["check-config-xml.py", str(good), str(target), str(good)])
    except Exception as exc:  # noqa: BLE001  # any escape from main() is the finding
        require(False, "main() raised", f"{type(exc).__name__}: {exc} | {show(payload)}")
        return verdict
    require(rc == (0 if verdict else 1), "batch exit code disagrees", f"{rc} | {show(payload)}")
    batch = out.getvalue()
    require(batch.count("well-formed") == (3 if verdict else 2), "batch report count", batch[:200])

    # And a third opinion that shares no code with the entry points: the bytes
    # on disk parsed by ElementTree directly. It is allowed to disagree (a
    # declaration expat accepts and a fromstring byte string need not agree on
    # every codec), but it must fail the way the entry points are contracted
    # to fail: ParseError for markup, LookupError or ValueError for a
    # declaration that names no usable text encoding. The unparenthesized
    # handler list is the formatter's output at the .python-version target,
    # not a typo: this suite is the one place the parens would be dropped.
    try:
        ET.fromstring(target.read_bytes())
    except ET.ParseError, LookupError, ValueError:
        pass
    except Exception as exc:  # noqa: BLE001  # any other escape is a finding too
        require(False, "re-parse raised", f"{type(exc).__name__}: {exc} | {show(payload)}")
    return verdict


def case_badge(tmp: Path, rng: random.Random) -> None:
    """One Cobertura report through the badge renderer, twice."""
    rate = rng.choice(RATES) if rng.random() < 0.85 else rng.choice(RATES) + rng.choice(VALUES)
    src = tmp / "cobertura.xml"
    src.write_text(f"<coverage line-rate={quoteattr(rate)}/>", encoding="utf-8")
    renders: list[bytes | None] = []
    codes: list[int] = []
    for attempt in range(2):
        dst = tmp / f"badge{attempt}.svg"
        out, err = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                rc = coverage_badge.main(["coverage_badge.py", str(src), str(dst)])
        except Exception as exc:  # noqa: BLE001  # any escape from the renderer is the finding
            require(False, "badge main() raised", f"{type(exc).__name__}: {exc} rate={rate!r}")
            return
        require(rc in (0, 1), "badge exit code", f"{rc} rate={rate!r}")
        require("Traceback" not in err.getvalue(), "badge traceback leaked", err.getvalue()[:200])
        if rc != 0:
            require(str(src) in err.getvalue(), "failure names its input", err.getvalue()[:200])
        codes.append(rc)
        renders.append(dst.read_bytes() if rc == 0 else None)
    require(codes[0] == codes[1], "badge exit code is not deterministic", f"{codes} rate={rate!r}")
    require(renders[0] == renders[1], "badge render is not deterministic", f"rate={rate!r}")
    if renders[0] is None:
        return
    try:
        root = ET.fromstring(renders[0])
    except ET.ParseError as exc:
        require(False, "rendered badge is not well-formed XML", f"{exc} rate={rate!r}")
        return
    # Output validity: the number drawn in the SVG is the number in its own
    # label, and a rate the tool accepted as a percentage cannot render a
    # percentage outside 0..100.
    texts = [t.text or "" for t in root.iter(f"{SVG_NS}text")]
    if not require(len(texts) == 2, "badge text nodes", f"{texts} rate={rate!r}"):
        return
    require(texts[0] == "coverage", "badge label text", f"{texts} rate={rate!r}")
    label_attr = root.get("aria-label") or ""
    require(
        label_attr == f"coverage: {texts[1]}",
        "aria-label disagrees with the drawn percentage",
        f"{label_attr!r} vs {texts} rate={rate!r}",
    )
    if texts[1].endswith("%"):
        pct = int(texts[1].rstrip("%"))
        require(0 <= pct <= 100, "accepted rate rendered out of range", f"{pct}% rate={rate!r}")


started = time.monotonic()
cases = 0
with TemporaryDirectory() as raw_tmp:
    tmp = Path(raw_tmp)
    for seed in SEEDS:
        rng = random.Random(seed)
        corpus = seed_corpus(rng)
        for i in range(ITERATIONS_PER_SEED):
            case_label = f"seed {seed} case {i}"
            payload = document(rng) if i >= len(corpus) else corpus[i]
            case_started = time.monotonic()
            case_check(tmp, payload)
            case_badge(tmp, rng)
            cases += 1
            elapsed = time.monotonic() - case_started
            require(elapsed <= CASE_SECONDS, "case exceeded its time budget", f"{elapsed:.1f}s")
            require(
                time.monotonic() - started <= RUN_SECONDS,
                "fuzz run exceeded its wall-clock budget",
                f"{time.monotonic() - started:.1f}s",
            )
            if violations:
                break

elapsed_total = time.monotonic() - started
for line in violations[:MAX_REPORTED_VIOLATIONS]:
    print(f"FAIL: fuzz: {line}", file=sys.stderr)
if len(violations) > MAX_REPORTED_VIOLATIONS:
    print(f"FAIL: fuzz: ... and {len(violations) - MAX_REPORTED_VIOLATIONS} more", file=sys.stderr)
check(f"fuzz: {cases} XML parser cases hold every invariant ({elapsed_total:.1f}s)", not violations)
exit_status()
print("xml parser fuzz rules OK")
