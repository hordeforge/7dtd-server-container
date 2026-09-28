# Changelog

Notable changes to Outpost, the 7 Days to Die dedicated-server deployment
harness. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The version has one canonical home, the `VERSION` file, printed by
`./scripts/run.sh version`. The release workflow refuses a `vX.Y.Z` tag that
disagrees with it (hordeforge/.github `REPOSITORY_STANDARDS.md` §8). Entries
before 1.1.1 are reconstructed from their GitHub release notes; the 1.0.0 and
0.1.0 sections are reconstructed from the tags themselves, because those
releases never got one.

## [Unreleased]

This batch carries a breaking change to a documented config value (the
password character domain, below), so it is a **major** release: 1.1.3 to
2.0.0. `VERSION` and the tag gate are bumped at release time, not here.

### Breaking changes

- **Secret values must be printable ASCII.** Before this release,
  `TELNET_PASSWORD` and `WEBADMIN_PASSWORD` were accepted with any character
  the ambient locale called printable, and the two sides of the container
  boundary disagreed: a `.env` value of `café` passed `reject_unsafe_value` in
  the operator's UTF-8 shell and was rejected inside the image, which runs
  with no `LANG` set, so the container died at boot on a value the host had
  just approved. The accepted domain is now exactly 0x20..0x7E and every
  character test runs under `LC_ALL=C`.

  Before: a non-ASCII password booted from a UTF-8 host session (and failed at
  the container boundary, often after a long depot download).
  After: `scripts/run.sh` exits 1 with `FATAL: <NAME> must be printable ASCII:
  ... or non-ASCII characters` before any container work, on both sides.

  **Upgrade:** if a password you already run contains a non-ASCII character,
  replace it in `.env` (or the quadlet `Environment=` line) with an ASCII one
  before deploying. Nothing else changes: saves, mods and the config schema are
  untouched, and the rule is the same one the pre-existing metacharacter
  exclusions already enforced. The full policy is in README, "Server
  configuration".

### Added

- **The release gate checks the changelog, not just `VERSION`.** A `vX.Y.Z` tag
  whose version matched the file could still be pushed with its notes left
  under `Unreleased`, so the release shipped without a changelog section.
  `.github/workflows/release.yml` now also requires a dated
  `## [X.Y.Z] - <date>` heading for the tag.
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
- `run.sh build` honors `SOURCE_DATE_EPOCH` and passes it to podman as
  `--timestamp`, so exporting it yields an image whose layer mtimes all carry
  that second and a rebuild can be diffed against the original. Unset, the
  build is timestamped at build time as before; a malformed value fails before
  podman runs.
- The image base is the `BASE_IMAGE` build arg (default unchanged,
  `docker.io/steamcmd/steamcmd:latest`), so a build that has to be repeatable
  pins it to a digest with `--build-arg` instead of editing the `Containerfile`.

### Changed

- **The dashboard seed no longer commits an individual's platform ids.**
  `config/serveradmin_seed.xml` shipped two hardcoded `<user>` entries
  (a Steam userid and an EOS id) in `<adminTools><users>`, and the same Steam
  and EOS ids on the `admin` webuser. A platform userid is a stable identifier
  that resolves to a person, so those two values belonged to the machine that
  happened to seed the file first, not to the template. Both are gone, and the
  webuser now authenticates by password alone.

  A host that has already booted has its own
  `data/userdata/Saves/serveradmin.xml` and is unaffected; the entrypoint only
  seeds when that file is missing. A fresh host now gets no Steam-linked admin,
  so add one after the first start: `admin add <platform> <id> 0` on the telnet
  console, or the dashboard. The webuser login (`admin` plus
  `WEBADMIN_PASSWORD`) is unchanged.
- **An unchanged mod tree is no longer deleted and copied back.** The
  container boot and the `mods-available/` staging step used to `rm -rf` and
  re-copy tens of megabytes of mod content on every start, so a
  `--restart unless-stopped` recovery and a redeploy that changed no mod paid
  the full write cost for nothing. `sync_tree` in `scripts/lib-env.sh` now
  compares the two trees (`diff -r -q`) and skips the write when they are
  already equal; where `diff` is missing the copy runs unconditionally, the
  previous behavior. A copy that does happen still lands in a hidden sibling
  and is renamed into place, so an interrupted copy cannot leave a half-written
  mod dir.
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

- **Every `run.sh` command died before doing anything.** The stale-secret
  sweep ran above its own definition, so bash reported
  `sweep_stale_secret_env_files: command not found` and `set -e` ended the run
  at once. The definition now precedes the call.
- **A failed staging run no longer wipes the enabled mods.** `stage_mods.sh`
  pruned `mods/` down to the owned set before the replacement set was built,
  so a run that then failed (no sibling dist staged, or a failed enable copy)
  left the previously enabled mods deleted, contradicting the "left
  unchanged" message it printed. The new set is now built entirely in the
  staging dir and the swap is what drops a mod the set no longer names.
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
- **The ops scripts run on the macOS workstations the README claims.** Two
  GNU-only spellings were live on a BSD host: `perf.sh` used `sed -i -E`, which
  BSD sed reads as `-i` with a mandatory backup suffix, so it wrote a
  `efficientserver.json-E` litter file, ran the expression in BRE mode where the
  alternation does not match, and the verify step then reported a format drift
  that never happened; and `webadmin_password_digest` called `md5sum(1)`, which
  macOS does not ship. `perf.sh` now probes for GNU sed via `--version` rather
  than the OS name, and the digest goes through `md5_hex`, which uses `md5sum`
  or `md5 -q`. With neither present the digest fails loudly instead of
  rendering an empty password the dashboard would accept.
- **The `shellcheck` step in `make lint` no longer passes on findings.** The
  loop ended on the last file's status under `set -e`, and a failing left side
  of an `&&` list is exempt from `set -e`, so a shellcheck error printed and the
  gate went green.
- **A failed `stage_mods.sh` run no longer wipes the enabled set.** The
  in-place `sync_tree` rewrite of `mods/<name>` started before the whole new
  set existed, so a copy that failed two mods in left the mods it had already
  rewritten holding new content and the rest holding old content, and a run
  that staged none of the owned mods swept every hand-enabled mod out of
  `mods/` before it reached its "nothing staged" failure. `deploy.sh` pushes
  whatever `mods/` holds, so both cases shipped a mod-less or half-updated
  tree after a run that reported the failure. Nothing writes into `mods/`
  until the new set is complete, and the swap is what drops whatever it does
  not name.
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

## [1.0.0] - 2026-08-23

First stable tag. The 1.0 line adds no code over 0.1.1: `v0.1.1` and `v1.0.0`
point at the same commit, and the delta that commit carries over 0.1.0 is the
branding, path, and documentation pass listed under 0.1.1 below. Read that
section for the changes; treat the 0.x to 1.0 jump as the numbering, not as
new behavior.

## [0.1.1] - 2026-08-23

HordeForge branding, path updates, and documentation alignment over 0.1.0. No
behavior change: the image, entrypoint, config templates, mod staging, and ops
scripts are the ones from 0.1.0.

## [0.1.0] - 2026-08-22

First tagged tree: container image, entrypoint, config templates, mod staging
and ops scripts, plus the self-contained checks (shell syntax, Containerfile
shape, config XML).

[Unreleased]: https://github.com/hordeforge/7dtd-server-container/compare/v1.1.3...HEAD
[1.1.3]: https://github.com/hordeforge/7dtd-server-container/releases/tag/v1.1.3
[1.1.2]: https://github.com/hordeforge/7dtd-server-container/releases/tag/v1.1.2
[1.1.1]: https://github.com/hordeforge/7dtd-server-container/releases/tag/v1.1.1
[1.1.0]: https://github.com/hordeforge/7dtd-server-container/releases/tag/v1.1.0
[1.0.0]: https://github.com/hordeforge/7dtd-server-container/releases/tag/v1.0.0
[0.1.1]: https://github.com/hordeforge/7dtd-server-container/releases/tag/v0.1.1
[0.1.0]: https://github.com/hordeforge/7dtd-server-container/releases/tag/v0.1.0
