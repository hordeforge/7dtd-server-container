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

- **A scheduled readability check on the save archives.** A backup that exited
  0 is a claim about the file it wrote that day, not proof the file is still
  good; a truncated off-host copy, a dropped tail or an archive nobody pruned
  in was invisible until a restore needed it. `./scripts/run.sh verify-backup`
  runs the same preflight `restore` applies (readable gzip/tar, a `Saves/`
  payload, no entry outside the archive root) without restoring anything or
  stopping the server, prints each archive's size and age, and exits nonzero
  when an archive is unreadable or the newest is older than three days (the
  backup schedule not running). `systemd/7dtd-backup-verify.{service,timer}`
  runs it weekly, so a bad archive leaves the unit failed where the backup
  timer's failure already does.
- **A discoverable local loop.** `make` prints the task list, `make test-one
  SUITE=<name>` runs a single suite instead of all twelve, and `make check`
  runs lint and test in CI's order. A missing `uv` or `shellcheck` now fails
  with the install hint instead of a `command not found` buried in gate
  output. The contributor path is documented in the README "Development"
  section and [`CONTRIBUTING.md`](CONTRIBUTING.md).
- **The release gate checks the changelog, not just `VERSION`.** A `vX.Y.Z` tag
  whose version matched the file could still be pushed with its notes left
  under `Unreleased`, so the release shipped without a changelog section.
  `.github/workflows/release.yml` now also requires a dated
  `## [X.Y.Z] - <date>` heading for the tag.
- **`scripts/test_fuzz_xml.py`, a seeded fuzz harness for the XML config
  parsers**, run by `make test`. It assembles structure-aware XML cases
  (elements, attributes, CDATA, comments, PIs, DTD and entity fragments,
  encoding declarations, truncation, NUL, control bytes, overlong UTF-8) seeded
  from the two committed config templates, and drives `check-config-xml.py`
  and `coverage_badge.py` through the same entry points CI uses. The
  assertions pin the invariants, not just the absence of a crash: a verdict
  reaches the documented stream, the CI batch agrees with the single-file
  check, a badge renders identically twice with a percentage that matches its
  own label, and a case that exceeds its time or wall-clock budget fails
  (which is what pins the entity-amplification guard). Fixed seeds and a
  bounded case count keep the gate deterministic; Atheris is not a dependency
  of this repo and the analyzer closure stays hash-pinned.

- **`scripts/test_fuzz_env.sh`, a seeded fuzz harness for the `.env` loader**,
  run by `make test` beside `scripts/test_lib_env.sh`. It assembles `.env`
  cases from line kinds (documented keys, near-miss key spellings, quoted and
  unquoted values, values shaped like command substitution, CRLF, a BOM, a
  NUL, a missing final newline, a duplicated key, a preset environment
  variable, a 4 KB value) and drives `load_env_file`, `check_env_file_keys`,
  `require_command` and the value, port and switch rules through the same
  entry points the ops scripts use. The expectations come from the generator's
  intent, not from a second copy of the parser, and they assert: the intended
  keys and values and nothing else, a variable the environment already carried
  is not overwritten, no warning or refusal carries a value or echoes a line
  back, and each value predicate agrees with an oracle written independently of
  `lib-env.sh`. It found the leak below.
- **A `.env` warning no longer echoes the line it is warning about.** The
  "ignoring line without '='" message printed the whole line, so the typo
  `TELNET_PASSWORD hunter2` (a forgotten `=`) put the password into the log of
  every script that loads the file, and the invalid-key message printed the
  whole key side, which carries the value in `TELNET_PASSWORD hunter2=x`. Both
  now name the file and the line number, and the invalid-key message names the
  key's first word only.


- OCI labels on the image (title, description, source, license, version) so
  `podman inspect` reports what it ships. The version label copies `VERSION`,
  and `scripts/test_containerfile.py` fails the gate on a release bump that
  forgets it.
- **`run.sh restore`.** Puts a save backup back into
  `data/userdata/Saves`: no argument restores the newest archive in
  `backups/`, an argument names one. The archive is verified first
  (readable gzip/tar, carries a `Saves/` payload, no entry escaping the
  archive root), a running server is refused, and the saves the restore
  replaces are archived first as a `-prerestore` snapshot, so the operation is
  reversible and a retried bare `restore` re-applies the same backup. A retry
  that finds the live saves already holding that backup ends as a no-op, with
  no second pre-restore snapshot, and the archive is unpacked beside `Saves/`
  and moved into place so a failed extraction leaves the current world intact.
  Recovery
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

- **The ruff rule set covers the groups it had left off.** `TRY`, `ASYNC`,
  `G`, `T10`, `INT` and `FIX` are on, all clean on this tree, so a swallowed
  `except`, a long message built outside the exception class, a blocking call
  in an async def, an f-string in a log call, a leftover `breakpoint`, a
  gettext-avoiding string helper and a stray `TODO` now fail the gate.
  flake8-bandit is on rule by rule rather than as a group: the harness calls
  `subprocess` by contract and starts tools on `PATH`, which are decisions and
  not findings, while the rules that catch real defects (`eval`/`exec`, pickle,
  `yaml.load`, a disabled TLS check, an unvalidated URL, a bind on all
  interfaces, `shell=True`) all run. The five rules still off (S101, S105,
  S311, S314, S324) are named in `pyproject.toml` so the gap is a list, not an
  omission.
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

- **`perf.sh on|off` skips the restart when the flag already holds the
  requested value.** The toggle is the config write; the restart only makes
  the game re-read it. Repeating the same command used to cost a world save,
  a shutdown and a boot for no change.
- **A redeploy that changed no mod no longer rewrites the enabled set.**
  `stage_mods.sh` seeded its staging dir with a copy of every enabled mod, then
  diffed the copy against `mods-available/`, then deleted the live tree and
  renamed the identical copy back in. Every deploy therefore wrote the whole
  enabled set (tens of megabytes) to produce a byte-identical result. An
  enabled mod whose `mods-available/` tree is already equal is now left in
  place and skipped by the swap; a mod whose dist did change is still replaced,
  a hand-enabled mod is still swept, and a run that fails still leaves the
  previous set untouched. On a three-mod, 46 MB set a redeploy that changed
  nothing went from ~2.1 s to ~0.53 s (hyperfine, 8 runs each).
- `run.sh config` reads `.env` once instead of forking a `grep` per reported
  key, and `update_mods.sh` strips a mod's name with parameter expansion rather
  than a `basename` fork per mod.

- **The coverage badge job builds kcov with the runner's own core count.** It
  is compiled from source on every push to main (`--parallel 2` capped a
  four-core runner at half its cores); the cap is gone and cmake sizes the
  build itself.

### Fixed

- **A `BACKUP_KEEP` with a leading zero was read as an octal literal, and an
  absurdly long one was read as a plausible count.** `(( KEEP_BACKUPS < 1 ))`
  reads `08` as an invalid octal number, so a padded retention value silently
  failed the range check, and bash wraps a 64-bit signed integer, so
  `BACKUP_KEEP=99999999999999999999` passed it and reached the prune loop as
  7766279631452241919. The value is now normalized in base 10 where it is
  read, and a value wider than the documented `1` to `999999999` range is
  refused by name before any command acts on it.
- **A host with no MD5 tool rendered an empty dashboard password digest.**
  `webadmin_password_digest` ran `md5_hex` in a command substitution and
  discarded its status, so the "no MD5 digest tool" guard never reached the
  caller and `base64` of an empty hex (the empty string) was written into
  `serveradmin.xml` as a password the dashboard would accept. The status is
  propagated now, and an empty digest is refused with the same loud failure.
- **`deploy.sh` let the shell expand its own rsync exclude pattern.** The
  `--exclude .scratch*` argument was unquoted, so a deploy run from a
  directory that happens to hold a `.scratch*` entry replaced the pattern with
  that filename and stopped excluding the scratch trees the pattern exists for.
  It is quoted now.
- **The `.env` fuzz harness asserted a predicate the lib no longer has.** The
  printable-ASCII rule moved into `reject_unsafe_value`, which exits instead of
  printing a reason, and the harness kept calling the old name. A bash
  function that does not exist returns nothing, so the assertion only failed
  for the cases that expected a reason: the seeded run went red on the first
  non-ASCII payload, and everything else passed without the check running at
  all. The harness now drives `reject_unsafe_value` itself and asserts the
  oracle's verdict both ways, that a refusal names the setting and carries
  neither the value nor a line of the file. Dropping the non-printable test
  from the lib's charset pattern makes the new assertion fail, which is how
  it was checked.
- **`scripts/test_run_sh.py` required a pre-restore snapshot from a failure
  that no longer discards anything.** Restore extracts into a staging
  directory beside `Saves/` and moves the result into place, so an archive
  that fails mid-extraction leaves the world it was serving untouched. The
  test still asserted the old contract (a snapshot taken, and named in the
  message) and had been failing. It now asserts the current one: the world is
  byte for byte what it was, no retention slot is burned on a snapshot for a
  restore that discarded nothing, no staging tree is left in `data/userdata`,
  and the message names the archive and says `Saves is unchanged`.
- **The `run.sh` suite failed `make lint` on a type error.** A loop variable
  named `padded` reused a name an earlier block had bound to a `list[bytes]`,
  so mypy reported the loop, its `env=` argument and the `int()` on it as
  three errors. The loop variable is now `zero_padded`.
- **The quadlet unit tried to pull an image nobody publishes.** The image is
  built on the server host and is never pushed to a registry, but the unit
  carried no `Pull=`, so quadlet's `missing` default stayed quiet only while
  the image was in the local store: after a `podman rmi` or a prune the
  service would try to pull `localhost/7dtd-server` from a registry that does
  not exist on that host and fail at boot with a network error. The unit now
  pins `Pull=never`, so a missing image is an honest "build it first" error.
- **The daily backup service ran with the default privilege set.** It is a
  shell script that reads `data/`, writes `backups/` and talks to the telnet
  port, and needs no escalation, so `systemd/7dtd-backup.service` now sets
  `NoNewPrivileges=yes`, matching the `no-new-privileges` the container unit
  already passes to podman.
- **The image build left debconf to chance.** Installing `tzdata` asks for a
  time zone, and a build has no terminal to answer on, so the answer came out
  of whatever the build environment happened to export. The `Containerfile`
  now sets `DEBIAN_FRONTEND=noninteractive` as a build `ARG` (not an `ENV`, so
  it does not survive into the runtime image) for that one layer.
- **A `BACKUP_KEEP` with a leading zero passed validation and then broke the
  prune.** `check_backup_keep` read the value with `(( ))`, where bash reads a
  leading-zero literal as octal: `08` is an arithmetic error rather than a
  comparison, so the `(( KEEP_BACKUPS < 1 ))` test failed closed and the value
  was accepted, then `archive_saves` hit the same error inside
  `excess=$(( ${#archives[@]} - KEEP_BACKUPS ))` and left the prune count
  unset, keeping every archive. The value is now normalized to base 10 when it
  is read, so `0007` is seven. The upper bound the docs promised is enforced
  too, and it is tested before any arithmetic: bash reads an integer as 64-bit
  and wraps a longer one silently, so `18446744073709551617` (2^64+1) reached
  the ceiling check as `1` and was accepted as a retention of one archive.
- **An interrupted `deploy.sh` push could leave the server host running a
  half-written script.** The transfer wrote files in place, so a dropped
  connection mid-file left a truncated `scripts/run.sh` behind and the next
  boot ran it. The push now passes `--delay-updates`: rsync stages every
  updated file in the receiver's `.~tmp~` directory and renames it into place
  only once the transfer finished, so the tree there is the old one or the new
  one. Deletions (`--delete`) still apply as they go, which the failure
  message already says.
- **The telnet helpers assumed GNU coreutils on every host that runs the ops
  scripts.** `telnet_session` and `telnet_probe` called `timeout(1)` directly,
  so on a macOS workstation, where that binary is coreutils-only and ships as
  `gtimeout(1)`, the probe failed with `command not found`: `run.sh status`
  reported an unhealthy container and the graceful stop and `backup()` save
  paths skipped the console and fell through to their fallbacks. The bound now
  comes from one shared helper (`run_bounded` in `scripts/lib-env.sh`) that
  probes for either spelling, the same capability probe `deploy.sh` already
  used for its bounded restart, and with neither binary it runs the command
  unsupervised after a single warning instead of failing. Pinned by
  `scripts/test_lib_env.sh` for both the gtimeout-only and the
  neither-binary host.
- **The analyzer venv could keep running a stale interpreter.** `make lint`
  and `make test` build `.venv` from `requirements-lint.txt` alone, and left
  the interpreter to whatever `python3` uv found first, so a `.python-version`
  bump neither rebuilt the venv nor changed the Python the gate ran on. The
  rule now takes `.python-version` as a prerequisite and passes its value to
  `uv venv --python`, the same file the CI cache key already keys on.
- **The image build could answer the `tzdata` prompt itself.** The `apt-get`
  step in the `Containerfile` installs `tzdata`, which asks a debconf
  timezone question, with no `DEBIAN_FRONTEND` set. The step now declares
  `DEBIAN_FRONTEND=noninteractive`, so the build neither blocks on a prompt
  nor records whatever answer the build environment happened to give.
- **The CI toolchain floated.** `setup-uv` was pinned to an action commit,
  which fixes the action code but not the `uv` binary it installs: with no
  `version` input each run resolved whatever uv was current, so a change in
  what it resolved with showed up as a gate difference with nothing to trace.
  Both jobs now pin `version: "0.12.14"`.
- **`run.sh backup` spun forever when no archive name could be claimed.** The
  name claim retries with a new suffix, because a backup and a pre-restore
  archive inside the same second would otherwise gzip into one path, but the
  loop had no bound. An unwritable `backups/`, a full disk, or a filesystem
  that refuses the create fails the same way for every suffix, so the run
  appended names until it was killed and the daily timer never came back. The
  claim is now bounded and reports the directory and the create error.
- **A failed `podman ps` was answered as "not running".** The running and
  existing probes returned 1 on a podman failure as well as on an empty set,
  and the callers act on the difference: `stop` skipped the telnet world save
  and forced a stop, `backup` archived without a fresh `saveworld`, and the
  run reported success either way. Both probes now name the probe failure on
  stderr, so the degraded path is visible instead of silent.
- **A failed restore did not name the saves it had already deleted.** The
  pre-restore snapshot is the only copy of the world once the extraction
  starts, and the failure message said only that `Saves` was incomplete. It
  now names the snapshot, and the corrupt-archive preflight keeps tar's own
  diagnostic instead of discarding it.
- **A rename failure in the `stage_mods.sh` swap left a half-enabled
  `mods/`.** The per-entry renames are atomic, but a failure lands between
  entries, after the old trees are gone: the mods not yet moved existed only
  in the staging directory the next run sweeps. The failure now names the
  staging directory and the way out. A failed `stage_mods.sh` also reached
  the operator as a bare `deploy.sh` exit, unlike the rsync and restart
  phases, so it now names its phase and reports that nothing was pushed.

- **A recovery could restore the older of two backups taken in the same
  second, and prune the newer one.** Two backups landing inside one second
  cannot share a name, so the second takes a `-<n>` counter, and both the
  prune and a bare `restore` read the archive list as an age order. That
  order did not hold: the counter was unpadded, so `-10` came out older than
  `-2`, and the list came from a glob, which sorts in the caller's locale, so
  under `en_US.UTF-8` the plain `…-000000.tar.gz` sorted after the
  `…-000000-01.tar.gz` written seconds later. The counter is now zero-padded
  behind a separator that sorts after the extension dot, and the list is read
  through `backup_archives`, which pins `LC_ALL=C` byte order, so age order
  holds on any host. Archives already in `backups/` keep their names.
- **`SOURCE_DATE_EPOCH` in the wrong unit built a timestamped image anyway.**
  The value reached `podman build --timestamp`, which reads seconds, after a
  digits-only check, so a millisecond stamp (`Date.now()`,
  `UnixMilli()`) pinned every layer to a date in the year 55000: a build that
  claims to be reproducible and reproduces nothing. A value too large to be a
  seconds stamp is now refused before podman runs, and a zero-padded one is
  read as decimal rather than as octal.
- **A `--exclude .scratch*` glob reached rsync pre-expanded.** The pattern was
  unquoted, so the shell expanded it against the caller's working directory
  before rsync saw it: a deploy run from a directory that happens to contain
  `.scratch` passed a narrower exclude than the one the script documents, and
  one run from an empty directory passed the literal pattern. The pattern is
  quoted now. `scripts/test_deploy_sh.py` already pinned the full rsync argv
  and caught this once such a directory existed.

- **A config file with an unusable encoding declaration crashed the XML
  parsers.** `encoding='x-mac-roman'` (an editor that wrote a Mac Roman
  declaration) or `encoding='utf-7'` fails outside `ParseError`: an unknown
  codec name raises `LookupError`, a multi-byte encoding expat refuses raises
  `ValueError`. `check-config-xml.py` and `coverage_badge.py` let both out as a
  traceback instead of a verdict, so the CI gate died on the one input it
  exists to report. Both now take the same clean failure path as a syntax
  error, with the offending file named.
- **`check-config-xml.py` batch test pinned the opposite of the batch
  contract.** One case asserted the batch stops at the first bad file, which
  the script's own comment, the other two batch cases, and the shipped
  behavior all contradict: every file in a batch is checked so one run
  surfaces every breakage. The stale assertion now pins the real contract.
- **A failed staging run no longer wipes the enabled mods.** `stage_mods.sh`
  pruned `mods/` down to the owned set before the replacement set was built,
  so a run that then failed (no sibling dist staged, or a failed enable copy)
  left the previously enabled mods deleted, contradicting the "left
  unchanged" message it printed. The new set is now built entirely in the
  staging dir and the swap is what drops a mod the set no longer names.
- **A repeated bare `run.sh restore` no longer undoes itself.** The pre-restore
  snapshot it writes is the newest archive, so the second run of a retried
  restore picked it and reverted the recovery. Those snapshots are now named
  `7dtd-saves-<UTC stamp>-prerestore.tar.gz` and skipped by the no-argument
  form, which re-applies the same backup; undoing a restore is still an
  explicit `restore <archive>` naming that snapshot. The snapshots stay in the
  same archive set, so the retention and prune cover them as before.
- **A retried `run.sh restore` no longer spends a retention slot.** The
  second run of a retried restore re-applied an archive the live saves
  already held and still wrote a pre-restore snapshot of that identical
  world, so seven retries of a recovery evicted the operator's real backups
  from `backups/` at `BACKUP_KEEP=7`. The restore now compares the extracted
  archive against `Saves/` (`diff -r -q`, the same content comparison
  `sync_tree` skips on) and ends with "nothing to restore" when they match.
- **A failed restore no longer leaves the world half-replaced.** The archive
  was extracted straight onto `data/userdata` after `rm -rf Saves`, so a
  truncated archive left an incomplete `Saves/` behind. It is now unpacked
  into a PID-named staging dir beside `Saves/` and moved into place, and
  stranded staging dirs from a killed run are swept by the next restore.
- **A boot killed mid-sync left a half-copied mod in the game's `Mods/`.**
  `entrypoint.sh` swept the temp files its own renders strand but not the
  staging siblings `sync_tree` creates, and the removal loop above them walks
  `Mods/*/` without `dotglob`, so a `.EfficientServer.tmp.<pid>` from an
  OOM-killed boot stayed in host `data/game` forever, where the game scans it
  for mods on every start. `sync_mods` now sweeps those entries by owning PID
  before reading the directory, the same rule the host staging scripts use.
- **The container health probe reported every server unhealthy.** It ran
  `init_telnet_env`, which exits 1 on an unset `TELNET_PASSWORD`; the quadlet
  unit pins none and the probe runs in its own environment, so the probe
  always failed. It now applies the same default port and the same port check
  without the password gate, which the probe never needed (it only opens a
  TCP connect).
- **Every `run.sh` command died before doing anything.** The stale-secret
  sweep ran above its own definition, so bash reported
  `sweep_stale_secret_env_files: command not found` (exit 127) and `set -e`
  ended the run at once. The definition now precedes the call.
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
