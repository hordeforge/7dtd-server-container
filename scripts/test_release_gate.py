#!/usr/bin/env python3
"""Suite pinning the release gate (scripts/check_release_gate.sh), the thing
that stands between a mistyped tag and a published release.

The gate is the whole release contract this repository has: the image is built
on the server host and never published from CI, so a tag that passes here is
the only automated check a release ever gets. The rules pinned here:

  tag shape      a vX.Y.Z tag, and one that matches the VERSION file, which is
                 the single canonical home for the version.
  changelog      a dated "## [X.Y.Z] - <date>" section, so notes cannot ship
                 still under Unreleased.
  monotonicity   never older than or equal to a version the changelog already
                 releases: a published version is not re-tagged or re-pointed.
  semver honesty a section that groups entries under "### Breaking changes"
                 ships as a major release. The 2.0.0 section in this tree
                 does exactly that (the printable-ASCII secret domain), so the
                 two cases below re-date that real section as a minor release
                 and as the next major, instead of a synthetic stand-in.

Every case runs the real script against a synthetic tree; the last two read
the real CHANGELOG.md so the pinned rules cannot drift away from the file they
exist for.
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from harness import ROOT, check, exit_status

GATE = ROOT / "scripts" / "check_release_gate.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
VERSION = ROOT / "VERSION"

# A changelog with two released sections, an Unreleased section, and nothing
# else, so each case states only the one thing it is about.
SECTIONS = """# Changelog

## [Unreleased]

### Added

- a thing

## [1.2.0] - 2026-09-30

### Changed

- the release under test

## [1.1.3] - 2026-09-21

### Changed

- an earlier release

## [1.1.0] - 2026-08-26

Rootless systemd quadlet unit.
"""

# The same file with the 1.2.0 section never dated, as if the release had
# shipped straight out of Unreleased.
RELEASE_HEADING = "## [1.2.0] - 2026-09-30"
STALE = SECTIONS.replace(RELEASE_HEADING, "### Changed\n\n- never dated")

BREAKING_SECTION = """
### Breaking changes

- **Secret values must be printable ASCII.** Before: accepted; after: refused.
"""


def gate(tag: str, root: Path) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["bash", str(GATE), tag, str(root)],
        capture_output=True,
        check=False,
        timeout=30,
    )


def make_tree(directory: Path, version: str, changelog: str = SECTIONS) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "VERSION").write_text(f"{version}\n", encoding="utf-8")
    (directory / "CHANGELOG.md").write_text(changelog, encoding="utf-8")
    return directory


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)

        clean = make_tree(root / "clean", "1.2.0")
        proc = gate("v1.2.0", clean)
        check("a matching tag with a dated section is releasable", proc.returncode == 0)
        check(
            "the pass names all three verdicts",
            all(
                line in proc.stdout.decode()
                for line in ("matches", "has a section for 1.2.0", "no breaking change")
            ),
        )

        proc = gate("1.2.0", clean)
        check(
            "a tag without the v prefix is refused",
            proc.returncode == 1 and b"does not start with 'v'" in proc.stderr,
        )

        proc = gate("v1.3.0", clean)
        check(
            "a tag that disagrees with VERSION is refused",
            proc.returncode == 1 and b"but" in proc.stderr and b"ships 1.2.0" in proc.stderr,
        )

        stale = make_tree(root / "stale", "1.2.0", STALE)
        proc = gate("v1.2.0", stale)
        check(
            "notes still under Unreleased are refused",
            proc.returncode == 1 and b"no '## [1.2.0] - <date>' section" in proc.stderr,
        )

        undated = make_tree(
            root / "undated",
            "1.1.3",
            STALE.replace("## [1.1.3] - 2026-09-21", "## [1.1.3]"),
        )
        proc = gate("v1.1.3", undated)
        check(
            "an undated released section is refused",
            proc.returncode == 1 and b"no '## [1.1.3] - <date>' section" in proc.stderr,
        )

        retag = make_tree(root / "retag", "1.1.0")
        proc = gate("v1.1.0", retag)
        check(
            "re-tagging an older version is refused",
            proc.returncode == 1 and b"already releases 1.2.0" in proc.stderr,
        )

        breaking_minor = make_tree(
            root / "breaking_minor",
            "1.2.0",
            SECTIONS.replace(RELEASE_HEADING, RELEASE_HEADING + BREAKING_SECTION),
        )
        proc = gate("v1.2.0", breaking_minor)
        check(
            "a breaking section tagged as a minor is refused",
            proc.returncode == 1
            and b"ships as a major release" in proc.stderr
            and b"2.0.0" in proc.stderr,
        )

        breaking_major = make_tree(
            root / "breaking_major",
            "2.0.0",
            SECTIONS.replace(RELEASE_HEADING, "## [2.0.0] - 2026-09-30" + BREAKING_SECTION),
        )
        proc = gate("v2.0.0", breaking_major)
        check(
            "the same breaking section tagged 2.0.0 is releasable",
            proc.returncode == 0 and b"ships a major bump" in proc.stdout,
        )

        proc = subprocess.run(["bash", str(GATE)], capture_output=True, check=False, timeout=30)
        check("no tag is a usage error", proc.returncode == 2)

        # A newer release sits above an older one that declares a breaking
        # change. The extraction must stop at the next release heading, or the
        # older section's heading is read as part of the newer one and a plain
        # minor release is refused as a major.
        newest_above_breaking = (
            "# Changelog\n\n"
            "## [2.1.0] - 2026-10-05\n\n### Changed\n\n- the newest release\n\n"
            "## [2.0.0] - 2026-09-30" + BREAKING_SECTION
        )
        proc = gate(
            "v2.1.0",
            make_tree(root / "above_breaking", "2.1.0", newest_above_breaking),
        )
        check(
            "an older breaking section does not leak into a newer release",
            proc.returncode == 0 and b"declares no breaking change" in proc.stdout,
        )

        proc = subprocess.run(
            ["bash", str(GATE), "v1.2.0", str(root / "nowhere")],
            capture_output=True,
            check=False,
            timeout=30,
        )
        check(
            "a root that is not a repository is refused",
            proc.returncode == 1 and b"not found" in proc.stderr,
        )

        # The real 2.0.0 section declares a breaking change. Re-dating that same
        # section as the next minor is the case that would ship as a minor if
        # the gate only compared the tag to VERSION, which is what it did
        # before. Both targets sit above the current VERSION, so the
        # monotonicity rule cannot hide the semver rule under test.
        current = VERSION.read_text(encoding="utf-8").strip()
        major, minor = (int(part) for part in current.split(".")[:2])
        minor_target = f"{major}.{minor + 1}.0"
        major_target = f"{major + 1}.0.0"
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        section_heading = "## [2.0.0] - 2026-10-25"
        check(
            "the real breaking section is still in CHANGELOG.md",
            section_heading in changelog,
        )

        def retitled_as(version: str) -> str:
            return changelog.replace(section_heading, f"## [{version}] - 2026-09-30")

        proc = gate(
            f"v{minor_target}",
            make_tree(root / "real_minor", minor_target, retitled_as(minor_target)),
        )
        check(
            f"this tree's own breaking section is refused as {minor_target}",
            proc.returncode == 1 and b"ships as a major release" in proc.stderr,
        )
        proc = gate(
            f"v{major_target}",
            make_tree(root / "real_major", major_target, retitled_as(major_target)),
        )
        check(
            f"the same section is releasable as {major_target}",
            proc.returncode == 0 and b"ships a major bump" in proc.stdout,
        )

    workflow = WORKFLOW.read_text(encoding="utf-8")
    check(
        "the release workflow runs the same gate the suite pins",
        "check_release_gate.sh" in workflow,
    )
    check(
        "the workflow no longer carries its own copy of the rules",
        "## \\[$VERSION\\]" not in workflow,
    )

    exit_status()


main()
