#!/usr/bin/env bash
# Release gate: a vX.Y.Z tag must describe a release this tree can actually
# ship (hordeforge/.github REPOSITORY_STANDARDS.md, section 8). The rules, in
# the order a failure is worth reporting:
#
#   1. the tag is vX.Y.Z and matches the VERSION file, the one canonical home
#      for the version (./scripts/run.sh version). A mistyped or forgotten
#      bump is refused instead of becoming a release nobody can reproduce.
#   2. CHANGELOG.md has a dated "## [X.Y.Z] - <date>" section for it, so a
#      release cannot ship with its notes still under Unreleased.
#   3. it is newer than every other released version in that changelog, so a
#      published version is never re-tagged or re-pointed at new work.
#   4. a section that groups its entries under "### Breaking changes" ships as
#      a major release. SemVer is the operator's only warning before an upgrade
#      refuses a value it used to accept, and a minor or patch tag carrying a
#      breaking change is exactly the release that tells nobody.
#
# The rules read the two files in the tree and nothing else, so the gate has
# no network access and no opinion about the image (which is built on the
# server host, never published from CI). .github/workflows/release.yml calls
# this with the pushed tag; scripts/test_release_gate.py runs it against
# synthetic trees.
#
# Usage: check_release_gate.sh vX.Y.Z [root]
# Exit codes: 0 the tag is releasable, 1 a rule was broken, 2 usage error.

set -euo pipefail

usage() {
  echo "usage: $(basename "$0") vX.Y.Z [root]" >&2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
  exit 2
fi

TAG="$1"
ROOT="${2:-$(cd "$(dirname "$0")/.." && pwd)}"

case "$TAG" in
  v*) ;;
  *)
    echo "ERROR: tag '$TAG' does not start with 'v'" >&2
    exit 1
    ;;
esac

VERSION="${TAG#v}"
case "$VERSION" in
  '' | *[!0-9.]* | *.*.*.*)
    echo "ERROR: tag '$TAG' is not a vX.Y.Z version" >&2
    exit 1
    ;;
esac

VERSION_FILE="$ROOT/VERSION"
CHANGELOG="$ROOT/CHANGELOG.md"
for required in "$VERSION_FILE" "$CHANGELOG"; do
  if [ ! -f "$required" ]; then
    echo "ERROR: $required not found; run this from a 7dtd-server-container tree" >&2
    exit 1
  fi
done

SHIPPED="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [ -z "$SHIPPED" ]; then
  echo "ERROR: $VERSION_FILE is empty" >&2
  exit 1
fi
if [ "$SHIPPED" != "$VERSION" ]; then
  echo "ERROR: tag $TAG but $VERSION_FILE ships $SHIPPED;" >&2
  echo "       make them match before tagging" >&2
  exit 1
fi
echo "ok: tag $TAG matches $VERSION_FILE ($SHIPPED)"

# The tagged section only: the `## [X.Y.Z] - <date>` line that starts it,
# everything under it, and nothing of the next release. The heading is matched
# whole, with its date, so an undated `## [1.1.3]` is not a release, and the
# dots in X.Y.Z are escaped rather than read as regex wildcards.
section="$(awk -v version="$VERSION" '
  BEGIN {
    escaped = version
    gsub(/\./, "\\.", escaped)
    heading = "^## \\[" escaped "\\] - "
  }
  $0 ~ heading { inside = 1 }
  inside { print }
' "$CHANGELOG")"

if [ -z "$section" ]; then
  echo "ERROR: $CHANGELOG has no '## [$VERSION] - <date>' section;" >&2
  echo "       move the Unreleased entries under it and date it before tagging" >&2
  exit 1
fi
echo "ok: $CHANGELOG has a section for $VERSION"

# Every released version the changelog names, this one excluded. The Unreleased
# heading carries no version, so it is not a release and never compares.
released="$(awk -v version="$VERSION" '
  index($0, "## [") == 1 {
    split(substr($0, 5), rest, "]")
    v = rest[1]
    if (v ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ && v != version) print v
  }
' "$CHANGELOG")"

# Print -1, 0 or 1 for a < b, a == b, a > b. Numeric per component, so 1.10.0
# is newer than 1.9.0 (a string compare would call it older).
version_cmp() { # a b
  local a="$1" b="$2" i x y
  local -a as bs
  IFS=. read -r -a as <<< "$a"
  IFS=. read -r -a bs <<< "$b"
  for i in 0 1 2; do
    x="${as[$i]:-0}"
    y="${bs[$i]:-0}"
    if ((10#$x > 10#$y)); then
      echo 1
      return
    fi
    if ((10#$x < 10#$y)); then
      echo -1
      return
    fi
  done
  echo 0
}

newest_major=0
for other in $released; do
  if [ "$(version_cmp "$VERSION" "$other")" -le 0 ]; then
    echo "ERROR: $CHANGELOG already releases $other, which is not older than" >&2
    echo "       $VERSION; a published version is never re-tagged or moved" >&2
    exit 1
  fi
  other_major="${other%%.*}"
  if ((10#$other_major > newest_major)); then
    newest_major=$((10#$other_major))
  fi
done

if grep -q '^### Breaking changes' <<< "$section"; then
  this_major="${VERSION%%.*}"
  if ((10#$this_major <= newest_major)); then
    echo "ERROR: the $VERSION section groups entries under '### Breaking changes'," >&2
    echo "       so it ships as a major release; the newest released major is $newest_major." >&2
    echo "       Move it to $((newest_major + 1)).0.0, or drop the heading if nothing" >&2
    echo "       in the section actually breaks a documented value or a command." >&2
    exit 1
  fi
  echo "ok: the $VERSION section declares a breaking change and ships a major bump"
else
  echo "ok: the $VERSION section declares no breaking change"
fi
