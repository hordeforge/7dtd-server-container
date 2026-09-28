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
                 ships as a major release. The Unreleased batch in this tree
                 does exactly that (the printable-ASCII secret domain), so the
                 refusal case below is run against the real CHANGELOG.md
                 promoted to 1.1.4, not a synthetic stand-in.

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

        # The real Unreleased batch declares itself a breaking 2.0.0. Promoting
        # it verbatim is the case that would ship 1.1.4 if the gate only
        # compared the tag to VERSION, which is what it did before.
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        released, body = changelog.split("## [Unreleased]", 1)

        def promoted_as(version: str) -> str:
            return f"{released}## [{version}] - 2026-09-30{body}"

        proc = gate("v1.1.4", make_tree(root / "real_minor", "1.1.4", promoted_as("1.1.4")))
        check(
            "this tree's own breaking batch is refused as 1.1.4",
            proc.returncode == 1 and b"ships as a major release" in proc.stderr,
        )
        check(
            "the same batch is releasable as 2.0.0",
            gate("v2.0.0", make_tree(root / "real_major", "2.0.0", promoted_as("2.0.0"))).returncode
            == 0,
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
