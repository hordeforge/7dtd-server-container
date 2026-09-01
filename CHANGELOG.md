# Changelog

Notable changes to Outpost, the 7 Days to Die dedicated-server deployment
harness. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The version has one canonical home, the `VERSION` file, printed by
`./scripts/run.sh version`. The release workflow refuses a `vX.Y.Z` tag that
disagrees with it (hordeforge/.github `REPOSITORY_STANDARDS.md` §8). Entries
before 1.1.1 are reconstructed from their GitHub release notes.

## [Unreleased]

## [1.1.1] - 2026-09-01

### Added

- `VERSION`, the canonical version home this repository did not have: its
  earlier releases claimed a version nothing in the tree stated.
  `./scripts/run.sh version` prints it, and
  `.github/workflows/release.yml` refuses a tag that disagrees. The image is
  still built on the server host by `scripts/run.sh build`; nothing is pushed
  from CI, because a hosted runner would publish an artifact nobody deploys.

### Changed

- Documented the attach-only surface `7dtd-playtest` gets: it reaches this
  host with `--no-server --readonly`, which forbids wiping, staging mods,
  rewriting config and restarting on its side. The old `--target live`
  spelling no longer exists. See
  [ADR 0001](https://github.com/hordeforge/.github/blob/main/docs/adr/0001-test-tiers-and-declarative-suites.md).
- Recorded that this repository keeps its own `@TOKEN@` config renderer rather
  than the lab's shared `7dtd-sandbox/scripts/sbconfig.py`: a container boot
  assert with different failure semantics and its own tests. They are not to
  be merged.

### Deliberately not done

- The image tag is still `localhost/7dtd-server:latest`. Wiring `VERSION` into
  it changes what the systemd quadlet resolves and needs a live check on the
  server host, not a release-time edit.

## [1.1.0] - 2026-08-26

Rootless systemd quadlet unit, perf tooling, and the threat model.

## [0.1.1] - 2026-08-23

Container image, entrypoint, config templates, mod staging and ops scripts.

[Unreleased]: https://github.com/hordeforge/7dtd-server-container/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/hordeforge/7dtd-server-container/releases/tag/v1.1.1
[1.1.0]: https://github.com/hordeforge/7dtd-server-container/releases/tag/v1.1.0
[0.1.1]: https://github.com/hordeforge/7dtd-server-container/releases/tag/v0.1.1
