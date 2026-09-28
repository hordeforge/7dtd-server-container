#!/usr/bin/env python3
"""Unit tests for sbom.py, run via `make test`.

Methodology: pin the CycloneDX contract at its boundaries.
  parsing     a line that is not `name==version` with sha256 hashes is
              rejected, the marker survives the hash continuation, and the
              backslash continuation is joined rather than read as its own line
  rendering   one component per manifest pin (matched by an independent
              regex, not by the parser under test), sorted, each carrying its
              purl, its sha256 hashes and the license its METADATA declares
  document    the root component, the 1.6 envelope, and a serial number that
              is a pure function of the manifest
  cli         --help, stdout, the written file, and the usage-error exit code
Each failed check prints a FAIL line; the process exits nonzero if any failed.
"""

from __future__ import annotations

import contextlib
import io
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import TypedDict, cast

from harness import ROOT, check, exit_status

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sbom

SBOM = ROOT / "scripts" / "sbom.py"
MANIFEST = ROOT / "requirements-lint.txt"
# Read the pins without sbom's parser, so a bug there cannot hide by being
# used on both sides of the comparison.
PIN = re.compile(r"^([A-Za-z0-9_.-]+)==([^ \\\n;]+)", re.MULTILINE)


class Hash(TypedDict):
    alg: str
    content: str


class Prop(TypedDict):
    name: str
    value: str


class Licence(TypedDict):
    id: str


class LicenceEntry(TypedDict):
    license: Licence


class Ref(TypedDict):
    type: str
    url: str


# UP013: "bom-ref" is not a Python identifier, so this one TypedDict cannot be
# written in class syntax like the others.
Component = TypedDict(
    "Component",
    {
        "type": str,
        "bom-ref": str,
        "name": str,
        "version": str,
        "purl": str,
        "hashes": list[Hash],
        "licenses": list[LicenceEntry],
        "properties": list[Prop],
        "externalReferences": list[Ref],
    },
    total=False,
)


class Document(TypedDict):
    bomFormat: str
    specVersion: str
    serialNumber: str
    version: int
    metadata: dict[str, object]
    components: list[Component]


def parse(text: str) -> Document:
    return cast(Document, json.loads(text))


def component(doc: Document, name: str) -> Component:
    return next(c for c in doc["components"] if c["name"] == name)


def tree(tmp: Path, manifest: str) -> Path:
    """A copy of the two marker files and the script, with no venv beside it."""
    root = tmp / "tree"
    (root / "scripts").mkdir(parents=True, exist_ok=True)
    (root / "scripts" / "sbom.py").write_bytes(SBOM.read_bytes())
    (root / "requirements-lint.txt").write_text(manifest, encoding="utf-8")
    (root / "VERSION").write_bytes((ROOT / "VERSION").read_bytes())
    return root


def plant_metadata(root: Path, stem: str, name: str, licence: str) -> None:
    """A dist-info beside the tree, shaped like one the installed venv holds."""
    # Any python* directory name works: the script globs the one it finds and
    # this fixture only has to look like the shape it globs for.
    site = root / ".venv" / "lib" / "python9.9" / "site-packages"
    dist = site / f"{stem}-1.0.dist-info"
    dist.mkdir(parents=True)
    (dist / "METADATA").write_text(
        f"Metadata-Version: 2.4\nName: {name}\nVersion: 1.0\nLicense: {licence}\n",
        encoding="utf-8",
    )


def run(root: Path) -> subprocess.CompletedProcess[str]:
    # encoding="utf-8", never text=True: the document is written with
    # ensure_ascii=False out of UTF-8 metadata, so a locale codec on the pipe
    # either raises on a non-ASCII component or decodes it into mojibake that
    # still parses as JSON.
    return subprocess.run(
        [sys.executable, str(root / "scripts" / "sbom.py")],
        capture_output=True,
        encoding="utf-8",
        cwd="/",
        check=False,
    )


with tempfile.TemporaryDirectory() as tmp:
    out = Path(tmp) / "sbom.cdx.json"
    check("rendering to a file exits 0", sbom.main([str(SBOM), str(out)]) == 0)
    doc = parse(out.read_text(encoding="utf-8"))

    check("bomFormat is CycloneDX", doc["bomFormat"] == "CycloneDX")
    check("specVersion is 1.6", doc["specVersion"] == "1.6")
    check("document version is 1", doc["version"] == 1)
    check(
        "serial number is a deterministic urn:uuid",
        doc["serialNumber"].startswith("urn:uuid:")
        and len(doc["serialNumber"]) == len("urn:uuid:") + 36
        and sbom.main([str(SBOM), str(Path(tmp) / "again.json")]) == 0
        and parse((Path(tmp) / "again.json").read_text(encoding="utf-8")) == doc,
    )

    root_component = cast(Component, doc["metadata"]["component"])
    check(
        "root component carries VERSION and the repo license",
        root_component["version"] == (ROOT / "VERSION").read_text(encoding="utf-8").strip()
        and root_component["licenses"] == [{"license": {"id": "MIT"}}],
    )
    check(
        "root component links the repository",
        any(
            ref["type"] == "vcs" and ref["url"].endswith("7dtd-server-container")
            for ref in root_component["externalReferences"]
        ),
    )
    meta_props = cast(list[Prop], doc["metadata"]["properties"])
    check(
        "the inventory says it is dev-only and ships in no image",
        any(
            p["name"] == "hordeforge:dependency-surface" and ".venv" in p["value"]
            for p in meta_props
        ),
    )

    manifest_text = MANIFEST.read_text(encoding="utf-8")
    check(
        "one component per manifest pin",
        sorted((c["name"], c["version"]) for c in doc["components"])
        == sorted((n.lower().replace("_", "-"), v) for n, v in PIN.findall(manifest_text)),
    )
    names = [c["name"] for c in doc["components"]]
    check("components are sorted by name", names == sorted(names))
    check(
        "every manifest hash is carried",
        {h["content"] for c in doc["components"] for h in c["hashes"]}
        == set(re.findall(r"--hash=sha256:([0-9a-f]{64})", manifest_text)),
    )
    check(
        "hashes are declared as SHA-256",
        all(h["alg"] == "SHA-256" for c in doc["components"] for h in c["hashes"]),
    )
    check(
        "purl matches name, version and bom-ref",
        all(
            c["purl"] == f"pkg:pypi/{c['name']}@{c['version']}" and c["bom-ref"] == c["purl"]
            for c in doc["components"]
        ),
    )

    # The pin the venv does not install at the .python-version pin, the pin
    # whose marker sits between the pin and its hashes, and the two licenses
    # only the older metadata forms carry.
    tomli = component(doc, "tomli")
    check(
        "a marker-gated pin that is not installed says so and claims no license",
        {p["name"] for p in tomli["properties"]}
        == {"hordeforge:pip:marker", "hordeforge:pip:installed"}
        and "licenses" not in tomli
        and tomli["properties"][0]["value"] == 'python_version < "3.11"',
    )
    librt = component(doc, "librt")
    check(
        "a marker before the hashes is read as a marker, not as part of them",
        {p["name"] for p in librt["properties"]} == {"hordeforge:pip:marker"}
        and librt["properties"][0]["value"] == 'platform_python_implementation != "PyPy"'
        and all(len(h["content"]) == 64 for h in librt["hashes"]),
    )
    check(
        "a classifier-only license resolves to its SPDX id",
        component(doc, "pathspec")["licenses"] == [{"license": {"id": "MPL-2.0"}}],
    )
    check(
        "the copyleft tool keeps the license its METADATA declares",
        component(doc, "yamllint")["licenses"] == [{"license": {"id": "GPL-3.0-or-later"}}],
    )
    check(
        "every other installed component declares a license",
        all("licenses" in c for c in doc["components"] if c["name"] != "tomli"),
    )

    # A copy of the tree with no venv beside it: the script finds its own root
    # from any cwd, and says it found no metadata rather than guessing.
    with tempfile.TemporaryDirectory() as bare:
        bare_root = tree(Path(bare), manifest_text)
        result = run(bare_root)
        check("runs from an unrelated cwd in a tree it discovers", result.returncode == 0)
        bare_doc = parse(result.stdout)
        check(
            "without a venv no license is claimed and every pin is flagged uninstalled",
            all("licenses" not in c for c in bare_doc["components"])
            and all(
                "hordeforge:pip:installed" in {p["name"] for p in c.get("properties", [])}
                for c in bare_doc["components"]
            ),
        )
        check(
            "the pins themselves are identical with and without metadata",
            sorted((c["name"], c["version"]) for c in bare_doc["components"])
            == sorted((c["name"], c["version"]) for c in doc["components"]),
        )

    # Non-ASCII text on the way in, out through both sinks, and out through a
    # pipe: a pin name, a license field and a marker all reach the document
    # verbatim, and the document is written with ensure_ascii=False, so this is
    # where a locale codec on either end of the pipe shows up. The names stand
    # in for whatever non-ASCII text a manifest or an installed METADATA
    # carries; what is pinned is the hop, not the particular string. The bytes
    # are compared, not the decoded text: a mojibake round trip decodes to
    # something JSON still parses.
    with tempfile.TemporaryDirectory() as uni:
        uni_root = tree(
            Path(uni),
            f'spätzle==1.0; python_version < "3.11" <café> \\\n    --hash=sha256:{"0" * 64}\n',
        )
        plant_metadata(uni_root, "spätzle", "spätzle", "Café Proprietary")
        uni_out = Path(uni) / "sbom.cdx.json"
        check("a non-ASCII pin renders to a file", sbom.main([str(SBOM), str(uni_out)]) == 0)
        uni_bytes = uni_out.read_bytes()
        uni_text = uni_bytes.decode("utf-8")
        uni_doc = parse(uni_text)
        uni_comp = uni_doc["components"][0]
        check(
            "the component name, license and marker survive the render verbatim",
            uni_comp["name"] == "spätzle"
            and uni_comp["licenses"] == [{"license": {"id": "Café Proprietary"}}]
            and uni_comp["properties"][0]["value"] == 'python_version < "3.11" <café>',
        )
        check("the document is written as UTF-8", uni_bytes.decode("utf-8") == uni_text)
        result = run(uni_root)
        check(
            "stdout is the same UTF-8 document, byte for byte",
            result.returncode == 0 and result.stdout.encode("utf-8") == uni_bytes,
        )

    with tempfile.TemporaryDirectory() as bad:
        bad_root = tree(Path(bad), "ruff==0.16.6\n")
        result = run(bad_root)
        check(
            "an unhashed pin is a clean failure, not a partial document",
            result.returncode == 1 and not result.stdout,
        )
        check("the failure names the pin", "no --hash pinning on ruff==0.16.6" in result.stderr)

        ranged = tree(Path(bad), f"ruff 0.16.6 --hash=sha256:{'0' * 64}\n")
        result = run(ranged)
        check(
            "a range pin is a clean failure",
            result.returncode == 1 and "not a pinned requirement" in result.stderr,
        )

        short = tree(Path(bad), f"ruff==0.16.6 --hash=sha256:{'0' * 63}\n")
        result = run(short)
        check(
            "a truncated hash is a clean failure",
            result.returncode == 1 and "unusable hash" in result.stderr,
        )

        empty = tree(Path(bad), "# nothing pinned\n")
        result = run(empty)
        check(
            "an empty manifest is a clean failure",
            result.returncode == 1 and "names no packages" in result.stderr,
        )

    result = subprocess.run(
        [sys.executable, str(SBOM)], capture_output=True, encoding="utf-8", check=False
    )
    check("stdout carries the same document as the file", parse(result.stdout) == doc)
    with contextlib.redirect_stdout(io.StringIO()) as help_out:
        rc = sbom.main([str(SBOM), "--help"])
    check(
        "--help exits 0 and prints the usage", rc == 0 and "Usage: sbom.py" in help_out.getvalue()
    )
    with contextlib.redirect_stderr(io.StringIO()) as usage_out:
        rc = sbom.main([str(SBOM), "a.json", "b.json"])
    check("a third operand is a usage error", rc == 2 and "usage:" in usage_out.getvalue())

exit_status()
