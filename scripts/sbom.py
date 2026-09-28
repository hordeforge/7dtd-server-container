#!/usr/bin/env python3
"""Emit a CycloneDX 1.6 SBOM for the pinned analyzer closure.

Usage: sbom.py [--help] [OUTPUT.json]

OUTPUT.json is the SBOM file to write; with no operand the document goes to
stdout, so the same call serves a pipe and a committed file. The previous
contents of OUTPUT.json are left untouched when the render fails. `--help`
prints this text on stdout and exits 0, like every other CLI here. Exits 2 on
a wrong operand count, 1 when the manifest is unusable.

The package set, versions, environment markers and sha256 hashes come from
requirements-lint.txt, the one manifest this repo resolves from, so the SBOM
covers the closure that is declared rather than the one a given machine
happened to install. Licenses come from the installed .venv dist-info
METADATA; a package whose marker excludes it from this interpreter (tomli on
Python 3.11+) is listed with no license and says so in a property, because
guessing a license from the name is how a compliance record turns into fiction.

The document is deterministic: no timestamp, components sorted by name, and
the serial number derived from the manifest's own bytes. The same manifest
and venv always produce byte-identical JSON, so the file diffs cleanly and a
regenerate is a no-op when nothing was bumped.
"""

from __future__ import annotations

import json
import sys
import uuid
from pathlib import Path

BOM_FORMAT = "CycloneDX"
SPEC_VERSION = "1.6"
# Root component identity, so a consumer reading the SBOM alone knows what the
# inventory belongs to without the repository URL.
PROJECT_NAME = "7dtd-server-container"
PROJECT_SOURCE = "https://github.com/hordeforge/7dtd-server-container"
PROJECT_LICENSE = "MIT"
# Namespace the serial number is derived in. Any fixed UUID works; reusing the
# URL namespace keeps the derivation a pure function of the manifest.
SERIAL_NAMESPACE = uuid.UUID("6ba7b811-9dad-11d1-80b4-00c04fd430c8")
# The two files that make a directory this project: the resolved-from manifest
# and the version root component reports.
MARKER_FILES = ("requirements-lint.txt", "VERSION")
# trove classifier tail -> SPDX id, for the packages whose metadata predates
# the PEP 639 License-Expression field. The vocabulary is the fixed list of
# OSI classifier strings, so the mapping cannot drift into inventing a license
# for a package that declares none; anything absent here stays unlicensed in
# the output rather than being guessed at.
CLASSIFIER_PREFIX = "Classifier: License :: OSI Approved :: "
CLASSIFIER_LICENSES = {
    "Apache Software License": "Apache-2.0",
    "GNU General Public License v2 (GPLv2)": "GPL-2.0-only",
    "GNU General Public License v2 or later (GPLv2+)": "GPL-2.0-or-later",
    "GNU General Public License v3 (GPLv3)": "GPL-3.0-only",
    "GNU General Public License v3 or later (GPLv3+)": "GPL-3.0-or-later",
    "ISC License (ISCL)": "ISC",
    "MIT License": "MIT",
    "Mozilla Public License 2.0 (MPL 2.0)": "MPL-2.0",
    "Python Software Foundation License": "PSF-2.0",
    "The Unlicense (Unlicense)": "Unlicense",
    "zlib/libpng License": "Zlib",
}


class ManifestError(Exception):
    """A requirements line that is not a pinned, hashed requirement."""


def find_root(start: Path) -> Path:
    """Walk up from start to the first directory holding both marker files."""
    for candidate in (start, *start.parents):
        if all((candidate / name).is_file() for name in MARKER_FILES):
            return candidate
    msg = f"no project root above {start} (looked for {', '.join(MARKER_FILES)})"
    raise ManifestError(msg)


def normalise(name: str) -> str:
    """PEP 503 name normalisation, which is also the spelling a purl carries."""
    out: list[str] = []
    prev_sep = False
    for ch in name.strip().lower():
        if ch in "-_.":
            prev_sep = True
            continue
        if prev_sep and out:
            out.append("-")
        prev_sep = False
        out.append(ch)
    return "".join(out)


def logical_lines(text: str) -> list[str]:
    """Yield the requirements lines, a trailing backslash continuing the line."""
    joined: list[str] = []
    buf = ""
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.endswith("\\"):
            buf = f"{buf} {line[:-1].strip()}"
            continue
        joined.append(f"{buf} {line}".strip())
        buf = ""
    if buf:
        joined.append(buf)
    return joined


def parse_requirement(line: str) -> tuple[str, str, str | None, list[str]]:
    """Split one logical requirement line into name, version, marker, hashes.

    The marker sits between the pin and the hashes (`librt==0.15.0; <marker> \\
    --hash=...`), so the hashes are collected from the whole line and the pin
    is what remains of the part before the semicolon.
    """
    pin_part, _, marker = line.partition(";")
    marker = marker.split("--hash=", 1)[0]
    digests = [tok.partition("=")[2] for tok in line.split() if tok.startswith("--hash=")]
    pin = pin_part.split("--hash=", 1)[0].strip()
    name, sep, version = pin.partition("==")
    if not sep or not name or not version:
        msg = f"not a pinned requirement: {line}"
        raise ManifestError(msg)
    if not digests:
        msg = f"no --hash pinning on {name}=={version}"
        raise ManifestError(msg)
    hashes = [checked_digest(d, name, version) for d in digests]
    return normalise(name), version, marker.strip() or None, hashes


def checked_digest(digest: str, name: str, version: str) -> str:
    """The hex sha256 behind a `sha256:<hex>` hash option, or a refusal."""
    algorithm, _, hexdigest = digest.partition(":")
    if algorithm != "sha256" or len(hexdigest) != 64:
        msg = f"unusable hash '{digest}' on {name}=={version}"
        raise ManifestError(msg)
    return hexdigest


def read_pins(manifest: Path) -> list[tuple[str, str, str | None, list[str]]]:
    return [parse_requirement(line) for line in logical_lines(manifest.read_text(encoding="utf-8"))]


def metadata_field(dist_info: Path, field: str) -> str:
    prefix = f"{field}: "
    for line in dist_info.joinpath("METADATA").read_text(encoding="utf-8").splitlines():
        if line.startswith(prefix):
            return line[len(prefix) :].strip()
    return ""


def find_dist_info(site_packages: Path, name: str, version: str) -> Path | None:
    """The one dist-info directory for name, or None when it is not installed."""
    stem = name.replace("-", "_")
    found = sorted(site_packages.glob(f"{stem}-*.dist-info"))
    exact = [d for d in found if normalise(metadata_field(d, "Name")) == name]
    if len(exact) == 1 and metadata_field(exact[0], "Version") == version:
        return exact[0]
    return None


def package_license(dist_info: Path) -> str | None:
    """The SPDX expression, or None when METADATA carries no usable license."""
    expression = metadata_field(dist_info, "License-Expression")
    if expression:
        return expression
    # Older metadata puts a full license text in License, which belongs in a
    # NOTICE file rather than in one field of an inventory.
    raw = metadata_field(dist_info, "License")
    if raw and "\n" not in raw and len(raw) <= 64:
        return raw
    return classifier_license(dist_info)


def classifier_license(dist_info: Path) -> str | None:
    """The SPDX id behind the first OSI trove classifier, when it has one."""
    text = dist_info.joinpath("METADATA").read_text(encoding="utf-8")
    for line in text.splitlines():
        if line.startswith(CLASSIFIER_PREFIX):
            return CLASSIFIER_LICENSES.get(line[len(CLASSIFIER_PREFIX) :].strip())
    return None


def component(
    name: str, version: str, marker: str | None, hashes: list[str], site_packages: Path
) -> dict[str, object]:
    purl = f"pkg:pypi/{name}@{version}"
    dist_info = find_dist_info(site_packages, name, version)
    props: list[dict[str, str]] = []
    if marker is not None:
        props.append({"name": "hordeforge:pip:marker", "value": marker})
    if dist_info is None:
        props.append(
            {
                "name": "hordeforge:pip:installed",
                "value": f"not installed at this interpreter: {name}=={version}",
            }
        )
    entry: dict[str, object] = {
        "type": "library",
        "bom-ref": purl,
        "name": name,
        "version": version,
        "purl": purl,
        "scope": "required",
        "hashes": [{"alg": "SHA-256", "content": h} for h in hashes],
    }
    license_id = package_license(dist_info) if dist_info is not None else None
    if license_id is not None:
        entry["licenses"] = [{"license": {"id": license_id}}]
    if props:
        entry["properties"] = props
    return entry


def build(root: Path, site_packages: Path) -> dict[str, object]:
    manifest = root / "requirements-lint.txt"
    pins = read_pins(manifest)
    version = (root / "VERSION").read_text(encoding="utf-8").strip()
    if not version:
        msg = "VERSION is empty"
        raise ManifestError(msg)
    if not pins:
        msg = f"{manifest} names no packages"
        raise ManifestError(msg)
    components = [component(n, v, m, h, site_packages) for n, v, m, h in pins]
    components.sort(key=lambda c: str(c["name"]))
    serial = uuid.uuid5(SERIAL_NAMESPACE, manifest.read_text(encoding="utf-8"))
    return {
        "bomFormat": BOM_FORMAT,
        "specVersion": SPEC_VERSION,
        "serialNumber": f"urn:uuid:{serial}",
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "bom-ref": f"pkg:generic/{PROJECT_NAME}@{version}",
                "name": PROJECT_NAME,
                "version": version,
                "licenses": [{"license": {"id": PROJECT_LICENSE}}],
                "externalReferences": [
                    {"type": "vcs", "url": PROJECT_SOURCE},
                    {"type": "distribution", "url": PROJECT_SOURCE},
                ],
            },
            "properties": [
                {
                    "name": "hordeforge:dependency-surface",
                    "value": (
                        "requirements-lint.txt: the hash-pinned analyzer toolchain installed "
                        "into the git-ignored .venv by the Makefile. None of these components "
                        "is copied into the container image, so none of them reaches a "
                        "downstream consumer of the image."
                    ),
                }
            ],
        },
        "components": components,
    }


def render(root: Path, site_packages: Path) -> str:
    return json.dumps(build(root, site_packages), indent=2, ensure_ascii=False) + "\n"


def main(argv: list[str]) -> int:
    if any(a in ("-h", "--help") for a in argv[1:]):
        print(__doc__.strip())
        return 0
    if len(argv) > 2:
        print(f"usage: {argv[0]} [OUTPUT.json]", file=sys.stderr)
        return 2
    try:
        root = find_root(Path(__file__).resolve().parent)
        site_packages = sorted((root / ".venv" / "lib").glob("python*/site-packages"))
        text = render(root, site_packages[0] if site_packages else root / ".venv")
    except (OSError, ManifestError, UnicodeError, ValueError) as exc:
        print(f"{argv[0]}: cannot build the SBOM: {exc}", file=sys.stderr)
        return 1
    if len(argv) == 2:
        Path(argv[1]).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
