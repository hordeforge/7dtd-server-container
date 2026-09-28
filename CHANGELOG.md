# Changelog

Notable changes to Outpost, the 7 Days to Die dedicated-server deployment
harness. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The version has one canonical home, the `VERSION` file, printed by
`./scripts/run.sh version`. The release workflow refuses a `vX.Y.Z` tag that
disagrees with it (hordeforge/.github `REPOSITORY_STANDARDS.md` §8). Entries
before 1.1.1 are reconstructed from their GitHub release notes.

## [Unreleased]

### Added

- OCI labels on the image (title, description, source, license, version) so
  `podman inspect` reports what it ships. The version label copies `VERSION`,
  and `scripts/test_containerfile.py` fails the gate on a release bump that
  forgets it.
- **`run.sh restore`.** Puts a save backup back into
  `data/userdata/Saves`: no argument restores the newest archive in
  `backups/`, an argument names one. The archive is verified first
  (readable gzip/tar, carries a `Saves/` payload, no entry escaping the
  archive root), a running server is refused, and the saves the restore
  replaces are archived first, so the operation is reversible. Recovery
  steps, RPO and RTO are in the README's "Recovering state" section.
- **Daily save backup (`systemd/7dtd-backup.{service,timer}`).** A user
  timer runs `run.sh backup` once a day (04:17, up to 10 minutes of jitter)
  and catches up a missed day at the next boot, so the RPO is bounded instead
  of "however long since anyone remembered". A failed run exits nonzero and
  leaves the unit failed where systemd can see it. Install it next to the
  quadlet (commands in the README).
- **Container health probe.** `run.sh start` and the quadlet unit pass
  `--health-cmd`, so `run.sh status` and `systemctl --user status` report
  `unhealthy` for a server process that is up but no longer answering on the
  telnet console. The probe opens a TCP connect only (no password), and a
  30 minute start period exempts the first boot's depot download. A red
  status is reported, never acted on.

### Changed

- The quadlet starts the container with `--security-opt=no-new-privileges`.
  Container root stays (rootless podman maps it to the host user), but nothing
  in the image needs a setuid escalation.
- **Container secrets travel in an owner-only env file.** `run.sh` hands
  `TELNET_PASSWORD` and `WEBADMIN_PASSWORD` to podman through a `0600`
  mktemp file instead of `-e KEY=VALUE`, which kept the values
  world-readable in `/proc/<pid>/cmdline` for the whole run. The file is
  removed on every exit path, and a run that only stops or backs up reclaims
  files stranded by an earlier SIGKILL.

### Fixed

- **`run.sh` runs every command again.** The stale-secret sweep was called
  before its definition, so each invocation died with
  `sweep_stale_secret_env_files: command not found` (exit 127).

- **Backup archive stamps are UTC.** `run.sh backup` named archives with the
  host wall clock while the prune read that name as the age order, so a
  fall-back DST transition could repeat a stamp (one archive overwriting the
  other) and a host timezone change or deploy to another region could prune a
  newer save as the oldest. Existing archives keep their names.
- The `Containerfile` header claimed the V3.1.0 game line; the server and its
  mods target V3.2.0.
- **Password value checks no longer depend on the locale.** The character
  rules in `scripts/lib-env.sh` matched with `[[:print:]]` and `[[:space:]]`,
  which are locale-sensitive, and the same lib runs on both sides of the
  container boundary: in the operator's UTF-8 session and inside the image
  with no `LANG` set. A password with an accented character was accepted on
  the host and rejected at boot in the container. Both tests now run under
  `LC_ALL=C`, which makes the accepted domain printable ASCII in every
  locale, and the rejection message names non-ASCII instead of speaking only
  about control characters.
- **The 8-character minimum for `WEBADMIN_PASSWORD` counts characters, not
  bytes.** bash counts characters in a multibyte locale and bytes in C, so a
  7-character multibyte password passed the rule on a C-locale host. The
  count goes through `ascii_length` now, which fixes the unit explicitly.
- Explicit `encoding=` on every `read_text`/`write_text` in the Python
  helpers and suites. `Path.write_text` without it uses the locale's
  preferred encoding, which is ASCII under `LANG=C`.
- The stalled-steamcmd case in `scripts/test_entrypoint_boot.py` used a
  1-second per-attempt bound, short enough that a loaded machine could land
  the kill before the stub recorded its attempt and make the test report a
  missing retry. The bound is 3s now, still far below the real one.

## [1.1.3] - 2026-09-21

### Changed

- **Shared argv guards.** The copy-pasted argument/usage boilerplate in
  `run.sh`, `perf.sh`, `update_mods.sh`, `deploy.sh`, and `stage_mods.sh` is
  unified into `require_argc` / `require_command` in `scripts/lib-env.sh`.
  Same exit codes (2) and same error wording; nothing to do.
- **Shared telnet request helper.** The duplicated telnet save-request block
  in `run.sh stop()` and `backup()` is unified into `request_telnet` in
  `scripts/lib-env.sh`. Same wire behavior and failure warnings.

### Removed

- The stale `mods-available/7dtd-apm-bridge` staging directory (superseded
  by `7dtd-server-apm-bridge`). It was never tracked; local-only removal.

## [1.1.2] - 2026-09-20

### Changed

- Lint tooling upkeep only: ruff 0.16.4 to 0.16.6 and ast-serialize 0.8.0 to
  0.9.0 in the hash-pinned `requirements-lint.txt`, both via dependabot. No
  image, entrypoint, config, or script behavior changes. Patch bump: the
  release has no user-facing surface.

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

[Unreleased]: https://github.com/hordeforge/7dtd-server-container/compare/v1.1.2...HEAD
[1.1.2]: https://github.com/hordeforge/7dtd-server-container/releases/tag/v1.1.2
[1.1.1]: https://github.com/hordeforge/7dtd-server-container/releases/tag/v1.1.1
[1.1.0]: https://github.com/hordeforge/7dtd-server-container/releases/tag/v1.1.0
[0.1.1]: https://github.com/hordeforge/7dtd-server-container/releases/tag/v0.1.1
