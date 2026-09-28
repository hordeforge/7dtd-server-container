# Threat Model: 7dtd-server-container

Living document. It models the attack surface of this repository only: the
deployment harness (image, entrypoint, ops scripts, configs) that runs a stock
7 Days to Die dedicated server in rootless podman on LAN host 192.168.0.100.
Game engine internals and mod source live in sibling repos and are modeled
here only at the boundaries this harness creates. Point vulnerabilities go to
sec-review with the references below; this document aims those passes.

Last reviewed: 2026-09-28 against VERSION 1.1.3 (previous pass 2026-08-26).
Re-run this review whenever the surface changes: new listener, new mount, new
script, new env variable. Owner and review cadence are organizational
decisions, noted here as open items, not invented.

References into the shell scripts name the file and the function
(`scripts/run.sh` `stop`), not a line number: an earlier revision pinned line
numbers and they pointed at the wrong code five commits later. Line numbers
survive only for `config/serverconfig.tmpl.xml`, which is stock TFP content
that does not shift.

## Risk-ranked summary

| # | Risk | Why it matters | Where |
|---|---|---|---|
| R1 | Telnet console reachable by any LAN peer, ships with a public default password | Full server control: shutdown, config changes, self-elevation to level-0 admin | `scripts/lib-env.sh` `init_telnet_env`, `config/serverconfig.tmpl.xml:35`, `scripts/run.sh` `make_common` |
| R2 | Web dashboard (8080) on all interfaces behind MD5-digest webuser auth | Authenticated panel can flip perf config and restart the server mid-game; MD5 resists little offline cracking | `config/serverconfig.tmpl.xml:28-29`, `scripts/lib-env.sh` `webadmin_password_digest`, `MODS.md` perf card |
| R3 | Every listener binds the host network namespace with no firewall or ACL anywhere in the repo; game joins need no password and the server is publicly listed | The "LAN only" assumption is enforced by nothing in this tree | `scripts/run.sh` `make_common`, `systemd/7dtd-server.container` `Network=host`, `config/serverconfig.tmpl.xml:9,16` |
| R4 | Supply chain: the default `steamcmd/steamcmd:latest` base tag is floating; unsigned C# mods copied wholesale into the game process | Whoever controls the base tag, a sibling `dist/`, or host-side `mods/` gets code execution in the user session at next boot | `Containerfile` `FROM`/`ARG BASE_IMAGE`, `entrypoint.sh` `sync_mods`, `scripts/stage_mods.sh` |
| R5 | Secrets lifecycle gaps: `.env` (both passwords) rsynced to the server host each deploy; minted webadmin password stored plaintext beside the admin file; telnet password crosses the wire in cleartext; no rotation procedure | Credential disclosure outlives a single compromise | `scripts/deploy.sh` `rsync` call, `entrypoint.sh` `seed_admin_file`, `scripts/lib-env.sh` `telnet_session` |
| R6 | Save archives under `backups/` are credential-bearing: each carries `serveradmin.xml` (dashboard digest, admin permissions) and `.webadmin-password`; retention keeps 7 unencrypted copies, and `restore` reinstates whatever those files contain | Restoring a tampered or stale archive silently rewrites who holds admin on the dashboard and which webuser password works; losing the host loses the world | `scripts/run.sh` `archive_saves`, `restore`, `systemd/7dtd-backup.service`, `entrypoint.sh` `seed_admin_file` |

R1 through R3 compound: the same exposed host carries the console, the
dashboard, and the joinable game.

## Entry points

All listeners exist because the container uses host networking
(`scripts/run.sh` `make_common` `--network host`, `systemd/7dtd-server.container` `Network=host`);
each binds every interface on 192.168.0.100.

| Entry point | Defined | Authn | Notes |
|---|---|---|---|
| Game protocol 26900 + LiteNetLib data 26902 (UDP/TCP) | `config/serverconfig.tmpl.xml:15-18` | None: `ServerPassword` empty (line 9), no whitelist (`serveradmin_seed.xml` `<whitelist>`), `ServerVisibility=2` public listing (line 16) | EAC deliberately off (rule 3, AGENTS.md; line 47); modified clients accepted surface |
| Web dashboard 8080 (stock dashboard + APM panel + BotMod API) | `config/serverconfig.tmpl.xml:28-31`; modules per `MODS.md` | Webuser login; digest rendered from `WEBADMIN_PASSWORD` or a minted random value (`entrypoint.sh` `render_config`, `seed_admin_file`, `scripts/lib-env.sh` `webadmin_password_digest`) | Documented panel actions: perf toggle + restart, `GET/POST /api/bot` (`MODS.md` perf card and Bot section) |
| Telnet console `TELNET_PORT` (default 8087) | `config/serverconfig.tmpl.xml:33-37`; port default `scripts/lib-env.sh` `init_telnet_env` | Password (`TELNET_PASSWORD`); failed-login throttle 10 wrong / 10 s block (lines 36-37) | With a password set the game listens on all interfaces (line 35 semantics, `scripts/lib-env.sh` `init_telnet_env`); unset falls back to the public lab default, not loopback-only |
| Ops CLIs on the server host | `scripts/run.sh`, `scripts/perf.sh`, `scripts/update_mods.sh`, `start.sh`, `stop.sh` | Local file access to the checkout and `.env` | Subcommands and flags are the CLI surface; values validated by `init_telnet_env`/`init_steamcmd_env`. `run.sh` also takes an operator-supplied file operand: `restore [archive]` (`scripts/run.sh` `require_optional_arg`, `restore`) |
| Deploy path workstation to server host | `scripts/deploy.sh` | SSH keys of `maci@192.168.0.100` | rsync of the whole checkout including `.env` (excludes `data/`, `backups/`, caches); optional remote restart via bounded ssh |
| Environment and `.env` inputs | `TELNET_PASSWORD`, `TELNET_PORT`, `WEBADMIN_PASSWORD`, `STEAMCMD_UPDATE`, `STEAMCMD_ONLY`, `ALLOW_PUBLIC_DEFAULT_TELNET_PASSWORD`, `BACKUP_KEEP`, `SEVENDTD_CONTAINER_NAME`, `SEVENDTD_IMAGE` (`scripts/lib-env.sh` `ENV_FILE_KEYS`, `init_telnet_env`/`init_steamcmd_env`); `SEVENDTD_SERVER_HOST`/`_USER`/`_DIR`, `SOURCE_DATE_EPOCH` (`scripts/deploy.sh` header, `scripts/run.sh` `build_image`) | n/a | Loaded by the no-eval parser `load_env_file` (`scripts/lib-env.sh` `load_env_file`); a key outside `ENV_FILE_KEYS` is refused before any value applies (`check_env_file_keys`); password values are restricted to printable ASCII by `reject_unsafe_value`, whose character tests run under `LC_ALL=C` so the host and the container reach the same verdict |
| Health probe (unauthenticated, in-container) | `HealthCmd` in `systemd/7dtd-server.container`; `scripts/run.sh` `HEALTH_CMD`/`health_check` | None, and it authenticates nothing by design | A bare TCP connect to the telnet port (`scripts/lib-env.sh` `telnet_probe`), run every 60 s by podman. It never sends the password, and a health status never restarts or kills the container, so the probe cannot become an unauthenticated command channel or an availability lever |
| Scheduled job: daily save backup | `systemd/7dtd-backup.timer` (04:17 host local time, `Persistent=true`, `RandomizedDelaySec=600`) running `systemd/7dtd-backup.service` -> `scripts/run.sh` `backup` | Runs with the host user's own privileges; no authn of its own | Writes a credential-bearing archive into `backups/` and prunes to `BACKUP_KEEP` (default 7). Failure is visible as a failed unit state and journal entries, not a silent skip |
| Image build and CI | `Containerfile` (apt + two COPYs); `.github/workflows/ci.yml`, `.github/workflows/release.yml` | n/a | Actions SHA-pinned in both workflows; analyzer deps hash-pinned with `--require-hashes` in `requirements-lint.txt`. The `ci.yml` badge job alone holds `contents: write` and builds kcov from a pinned upstream commit, so it is the one job where third-party source runs under a write token (`.github/workflows/ci.yml` badge job) |
| Per-boot Steam fetch | `entrypoint.sh` `install_or_update`, `sync_mods` | Steam anonymous login | Skippable with `STEAMCMD_UPDATE=0` |

Every row above was verified against the tree at the review date.

## Trust boundaries and data flow

1. **Network client to listeners.** Four unauthenticated-or-password-only
   surfaces terminate directly in the host network namespace. There is no
   reverse proxy, no firewall rule, and no network policy anywhere in this
   repo; the only access decision is made by the game itself after connect.
2. **Workstation to server host.** `scripts/deploy.sh` pushes code and
   `.env` over SSH and triggers a remote restart. The remote command string
   is constant; `DEST_DIR` travels as stdin so no environment value can shape
   it (`scripts/deploy.sh` `REMOTE_CMD`). Runtime `data/` is excluded from the sync,
   so a deploy cannot clobber server-side saves.
3. **Host filesystem to container.** Bind mounts: `data/game` rw,
   `data/userdata` rw, `mods/` rw, `config/` ro, all `:Z` relabeled
   (`scripts/run.sh` `make_common`, `systemd/7dtd-server.container` `Volume=` lines). Under
   rootless podman, container root maps to the host user
   (`Containerfile` `ENTRYPOINT` note), so any write inside the mounts is a write as that
   host user.
4. **Secrets flow.** `.env` or environment -> `load_env_file` (literal parse,
   never eval'd) -> owner-only `mktemp` env file -> `podman --env-file`
   (`scripts/run.sh` `make_common`) -> entrypoint environment -> `sed` render into
   `data/game/serverconfig.xml` and `data/userdata/Saves/serveradmin.xml`
   under `umask 077` with atomic rename and temp-file sweep
   (`entrypoint.sh` `render_config`, `seed_admin_file`). The same two files
   then ride into every save archive `scripts/run.sh` `archive_saves` writes
   (owner-only there too, `umask 077`), so a credential also exists as
   `BACKUP_KEEP` (default 7) unencrypted copies under `backups/`; `deploy.sh`
   excludes `backups` from the rsync, so those copies stay on the server host.
   Rotation point: none automated; the
   webadmin seed is skipped while `serveradmin.xml` exists, so changing that
   password requires deleting the file first (`entrypoint.sh` `seed_admin_file`).
   A restore is a third rotation path: it reinstates whatever `serveradmin.xml`
   and `.webadmin-password` the archive carries.
5. **Build to runtime.** Sibling repo `dist/` outputs -> `stage_mods.sh`
   stages real copies into `mods-available/` and `mods/` -> entrypoint
   `sync_mods` syncs each `/mods` entry into the depot `Mods/` dir
   (`entrypoint.sh` `sync_mods`, `scripts/lib-env.sh` `sync_tree`) -> .NET
   assemblies loaded in-process by the game
   with full trust. No signature or pin check exists at any hop.
6. **Steam CDN and base registry to depot.** `FROM ...steamcmd:latest`
   (`Containerfile` `ARG BASE_IMAGE`/`FROM`, default is the floating tag) plus
   per-boot `app_update validate`: content integrity rests on Steam and on
   whatever the mutable base tag serves. A release cut can pin a digest
   through the `BASE_IMAGE` build arg without editing the file, and
   `SOURCE_DATE_EPOCH` makes a rebuild of a reported digest comparable
   (`scripts/run.sh` `build_image`); the day-to-day default uses neither.
7. **Save archive to live saves (restore path).** `scripts/run.sh` `restore`
   extracts an operator-named `.tar.gz` over `data/userdata/Saves` after a
   listing preflight. The archive is a file operand chosen by whoever runs the
   command, not a file this repo produced, and nothing binds it to the host it
   came from. Extracted content is trusted state: `serveradmin.xml` inside it
   decides dashboard and admin permissions on the next boot
   (`entrypoint.sh` `seed_admin_file` skips seeding when that file exists).

## Assets

- **World saves and player data**, `data/userdata/Saves/`: weeks of play;
  integrity and availability are the primary loss concerns (the graceful-stop
  machinery exists solely to protect them, `scripts/run.sh` `stop`).
- **`TELNET_PASSWORD`**: equivalent to full server control (console includes
  `shutdown`, `admin add`, world and config commands; self-elevation flow
  documented at `README.md` Configuration).
- **`WEBADMIN_PASSWORD`**, its MD5 digest in `serveradmin.xml`, and the
  plaintext minted-record file `data/userdata/Saves/.webadmin-password`.
- **`serveradmin.xml` permission entries**: whoever holds a level-0 admin
  entry (Steam/EOS ID or the `admin` webuser) has durable dashboard and console
  authority. The committed seed ships no individual identities: `<users>` and
  `<whitelist>` are empty and carry a comment saying so
  (`config/serveradmin_seed.xml` `<users>`), so the durable principals are
  created at runtime by `admin add` on the telnet console (README
  Configuration) or the dashboard, and the file's contents are worth tampering
  with. The seed does grant a fixed command-permission table
  (`config/serveradmin_seed.xml` `<commands>`, everything else at level 0), and
  `<apitokens>` is empty but would carry bearer secrets if an operator adds
  entries.
- **Save archives in `backups/`**: the only off-`Saves/` copy of the world
  (retention `BACKUP_KEEP`, default 7) and, as noted above, of the dashboard
  credentials. Unencrypted, same host, no off-host copy shipped here
  (`scripts/run.sh` `archive_saves`, `systemd/7dtd-backup.service`).
- **Compute of the host user session** (rootless, but unconfined within that
  user): CPU/RAM/disk for cryptomining or exhaustion; the host's LAN position
  as a pivot.
- **`.env`** carrying both secrets, at rest on two hosts.

Concrete blast radius for R1/R2: an attacker with telnet or dashboard access
can destroy unsaved progress via forced shutdown, persist level-0 admin for
arbitrary Steam IDs, alter the world and its rules, and use the host as a
LAN-internal foothold. Not "data breach": specific, repeatable takeover of
this game service and its user account context.

## Threats per boundary

### Boundary 1: network clients to listeners (the internet-facing boundary)

- **Spoofing/information disclosure:** the telnet protocol sends the password
  in cleartext (`telnet_session` shows the plain wire exchange,
  `scripts/lib-env.sh` `telnet_session`); any passive LAN observer between operator
  and server learns a full-control credential. Dashboard auth is MD5-digest
  based (`scripts/lib-env.sh` `webadmin_password_digest`), crackable offline if the digest file
  leaks. Game joins authenticate nothing beyond protocol-level identity.
- **Tampering/elevation of privilege:** with EAC off (deliberate, rule 3),
  modified clients can cheat state freely; in-game impact is bounded to the
  world. Real elevation needs a second factor: telnet password or dashboard
  login. Both grant persistence (`admin add` writes `serveradmin.xml`;
  webuser digest sits in the same file).
- **Denial of service:** four listeners with no rate limit or quota upstream
  of the game; `TelnetFailedLoginLimit` throttles only wrong passwords after
  connect (`config/serverconfig.tmpl.xml:36-37`). Join slots cap at 8
  (line 21), per-player map growth is capped (line 50), view distance capped
  (line 78), but `SaveDataLimit=-1` (line 53) leaves save disk usage uncapped
  at the config level. Connection floods and slot squatting are unmitigated
  here.
- **Repudiation:** partially mitigated: command execution is logged
  (`HideCommandExecutionLog=0`, `config/serverconfig.tmpl.xml:49`) and the
  game writes `data/userdata/Logs/output.log`; nothing in this repo retains,
  forwards, or reviews those logs.

### Boundary 2: workstation to server host (deploy path)

- Spoofing/tampering reduce to SSH key compromise of `maci@192.168.0.100`,
  which yields deploy control and `.env` exfiltration in one step. Existing
  mitigations are transport hygiene only: connect and transfer timeouts, a
  time-bounded remote restart, stdin-passed argument
  (`scripts/deploy.sh` argument guard and `rsync` call).
- Repudiation: none. Deploys leave no audit trail beyond shell history.

### Boundary 3: host filesystem to container

- Tampering/elevation: anything able to write `mods/` on the host executes
  code inside the game process at next restart (`entrypoint.sh` `sync_mods`
  copies `/mods/.` wholesale); conversely a compromised container can write
  back into `data/` and `mods/` as the host user. `config/` being ro blocks
  in-container template tampering. SELinux `:Z` labels constrain cross-user
  access, not this user's own writes.
- The container runs as root in the rootless mapping with no `--cap-drop` or
  read-only rootfs, and no privilege drop (`scripts/run.sh` `make_common`, systemd unit);
  hardening relies entirely on the rootless boundary. The quadlet unit adds
  `PodmanArgs=--security-opt=no-new-privileges`
  (`systemd/7dtd-server.container` `PodmanArgs=`), which
  `scripts/run.sh` `start` does not: a container started by hand from the same
  image runs without it. Setuid escalation is what that bit blocks, and nothing
  in this image is setuid today, so the difference is a defense-in-depth gap
  (G9) rather than a live exploit.

### Boundary 4: secrets to code

- Disclosure paths that exist today: plaintext `.env` on two hosts (rsynced
  by design, `scripts/deploy.sh` `rsync` call); the minted-password record file
  (owner-only mode, documented tradeoff, `entrypoint.sh` `seed_admin_file`);
  every save archive, which carries `serveradmin.xml` and
  `.webadmin-password` and is retained unencrypted on the same host
  (`scripts/run.sh` `archive_saves`); cleartext telnet wire; journald/podman
  logs are kept secret-free by
  construction (values never in argv, `scripts/run.sh` `cleanup_secret_env_file`,
  `scripts/lib-env.sh` `telnet_session`; minted password never logged,
  `entrypoint.sh` `seed_admin_file`).
- Rotation: no procedure for either password anywhere in the tree; see
  secrets flow above for the manual escape hatch.

### Boundary 5: build to runtime (mod supply chain)

- Elevation of privilege: unsigned, unpinned DLLs from three sibling repos
  are staged and executed with the game's own authority. Compromise of any
  sibling build host, the git checkouts, or host-side `mods/` lands as code
  execution here. `stage_mods.sh` wipes unrecognized dirs from `mods/` on
  each staging run (`scripts/stage_mods.sh` `mods/` wipe), which limits hand-planted
  mods to one staging interval but does not authenticate the owned set.
- The enabled-set ownership also means a hostile change to `NAMES`/
  `SRCS` in `scripts/stage_mods.sh` `NAMES`/`SRCS` redirects what runs in production.

### Boundary 6: registry/CDN to depot

- Tampering: the default base tag is mutable (`Containerfile` `ARG BASE_IMAGE`/
  `FROM`) and Steam-delivered
  depot updates can change executed code on the next boot; `validate` checks
  Steam's own manifests, not a pin. The version-pin rule (AGENTS.md rule 8)
  accepts this for gameplay, and the same exposure applies to security.

### Boundary 7: save archive to live saves (restore)

- **Tampering/elevation of privilege:** the archive is a file operand with no
  provenance binding. Whoever can place a `.tar.gz` where the operator runs
  `restore <path>` controls the extracted `Saves/`, including
  `serveradmin.xml`: the entrypoint skips seeding whenever that file exists
  (`entrypoint.sh` `seed_admin_file`), so a restored file with a different
  `admin` webuser digest, an added `<apitokens>` entry, or a level-0
  `<user>` grants exactly that identity dashboard and console authority
  (the same persistence `admin add` gives, R1) without a password change or a
  visible event beyond a restore in shell history. The listing preflight
  (`scripts/run.sh` `restore`) rejects path escapes, absolute entries, and an
  archive with no `Saves/` payload, and `--no-same-owner` blocks a foreign uid
  in the archive; it checks the archive's shape, not the trustworthiness of its
  XML. Recorded as a threat for sec-review, not fixed here.
- **Denial of service / resource exhaustion:** no size, entry-count, or
  expansion bound is applied before extraction. `tar -tzf` on a small
  compression bomb still succeeds, and `restore` then `rm -rf`s the live
  `Saves/` and extracts whatever it produces into `data/userdata`; a failed
  extraction leaves `Saves/` incomplete (the script says so and exits 1).
  `BACKUP_KEEP` bounds how many archives accumulate, not how large one is
  (`scripts/run.sh` `KEEP_BACKUPS` validation, `archive_saves` prune).
  Retention only runs on a backup run, so a restore that fills the disk is not
  cleaned up until the next one.
- **Repudiation:** the restore path is an operator command; the only record is
  the pre-restore snapshot it leaves in `backups/`, whose name records the time
  and the `prerestore` marker but not who ran it.

## Mitigations that exist (mapped)

| Control | Covers | Reference |
|---|---|---|
| Shared validation of secret/port/flag values (character class, port range, `{0,1}` domain), enforced identically on host and in container | Injection of secret values through sed/XML rendering and shell quoting; silent fallback to defaults | `scripts/lib-env.sh` `reject_unsafe_value` through `init_steamcmd_env`, baked copy `Containerfile` `COPY scripts/lib-env.sh`, sourced `entrypoint.sh` boot preamble |
| No-eval `.env` parser with malformed-line warnings, plus refusal of unknown keys before any value applies | Env file as code injection; typo'd keys silently ignored (the loader warning case) and typo'd keys silently *accepted but unused* (the unknown-key case) | `scripts/lib-env.sh` `load_env_file`, `check_env_file_keys`, `ENV_FILE_KEYS` |
| `run.sh config` prints every effective value with its source and never a secret value | A wrong telnet port or a rejected value discovered only as a boot failure; credential leakage into a shared terminal | `scripts/run.sh` `show_config` |
| Restore preflight: readable gzip/tar, must carry a `Saves/` payload, no absolute or escaping entry, refused while the server runs, `--no-same-owner`, `umask 077`, pre-restore snapshot | Path-escape or uid-carrying archive writing outside `data/userdata`; a live game overwriting the restored saves; a restore that is itself unrecoverable | `scripts/run.sh` `restore` |
| Owner-only archives, UTC stamps, exclusive create (`noclobber`) for the name, `tar` exit >= 2 deletes the partial, prune to `KEEP_BACKUPS` | Two concurrent backups interleaving gzip into one corrupt archive; a partial archive kept as if valid; unbounded disk growth from a scheduled backup | `scripts/run.sh` `archive_saves` |
| Digest-buildable base (`ARG BASE_IMAGE`) and reproducible builds (`SOURCE_DATE_EPOCH` -> `podman build --timestamp`) | Untraceable executed base and unreproducible images; a rebuild of a reported digest that cannot be diffed against the original. Only for a caller that opts in; the default build uses neither | `Containerfile` `ARG BASE_IMAGE`, `scripts/run.sh` `build_image` |
| `no-new-privileges` on the quadlet path | Setuid escalation inside the container (nothing in this image is setuid today) | `systemd/7dtd-server.container` `PodmanArgs=` |
| Health probe never sends a password and never acts on a health status | Turning the probe into an unauthenticated command channel or an availability lever; a red status taking the server down | `scripts/lib-env.sh` `health_check`, `telnet_probe`, `scripts/run.sh` `HEALTH_FLAGS` |
| Telnet shutdown/saveworld requests bound by a readiness probe and a timeout | A stale session racing a restarting container and sending the password into the wrong listener; an unbounded wait | `scripts/lib-env.sh` `request_telnet`, `telnet_probe`, `scripts/run.sh` `stop`, `backup` |
| Secrets never in argv; 0600 mktemp env file; EXIT/signal traps; PID-keyed sweep of orphaned secret files | Local disclosure via `/proc/*/cmdline`, stranded credential files | `scripts/run.sh` signal traps, `cleanup_secret_env_file`, `sweep_stale_secret_env_files`, `make_common`, `scripts/lib-env.sh` `telnet_session` |
| `umask 077` + temp-file + atomic rename + SIGKILL-stranded-temp sweep for credential-bearing renders | Partial/truncated credential files left readable or corrupt on disk | `entrypoint.sh` `render_config`, `seed_admin_file` |
| Minted webadmin password kept out of logs | Credential leakage into retained journald data | `entrypoint.sh` `seed_admin_file` |
| Telnet failed-login throttle | Online password guessing rate | `config/serverconfig.tmpl.xml:36-37` (game-enforced) |
| Graceful stop: telnet save+shutdown, bounded wait, force fallback; wired into systemd `ExecStop` | World-save loss on stop/restart (availability/integrity of the top asset) | `scripts/run.sh` `stop`, `systemd/7dtd-server.container` `ExecStop` |
| `install-only` refuses while the server runs | Depot rewrite racing a live game | `scripts/run.sh` `install_only` |
| Rootless podman, disposable container, runtime state on host, `:Z` SELinux labels | Blast radius of container compromise; cross-user file access | `Containerfile` `ENTRYPOINT` note, `scripts/run.sh` `make_common`, `systemd/7dtd-server.container` `Volume=` lines |
| Deploy-path hardening: timeouts, bounded remote exec, stdin-arg passing, `data/` excluded from rsync | Remote command shaping; accidental destruction of server-side saves | `scripts/deploy.sh` argument guard and `rsync` call |
| CI least privilege (`contents: read` on `ci.yml` check and `release.yml`), SHA-pinned actions, analyzer closure installed with `uv pip install --require-hashes` | Build-system supply chain | `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `Makefile`, `requirements-lint.txt` |
| Badge job isolated: one job, `contents: write`, main pushes only, third-party source (kcov) fetched by commit SHA, build tree under `RUNNER_TEMP` | A compromised analyzer dependency pushing to the repository, and third-party build code running under a write token | `.github/workflows/ci.yml` badge job |
| Deploy target values shape-checked (`reject_deploy_target`) before they reach `ssh`/`rsync` argv | A host or user of `-oProxyCommand=...` becoming an option that executes on the deploy workstation | `scripts/deploy.sh` `reject_deploy_target` |
| Command execution echo logging kept on | Post-hoc attribution of console actions | `config/serverconfig.tmpl.xml:49` |

No documentation claim in `README.md` or `AGENTS.md` contradicts the code as
of this review; the claims spot-checked (secret handling, telnet binding
behavior, seed behavior, backup/restore verification and retention, the
`no-new-privileges` and health settings, and the "not built" list that names
this document) all match their referenced implementations.

## Gaps, ranked by exploitability and impact

1. **G1 (=R1):** no access control upstream of telnet; public default
   password; all-interface binding once set. Cheapest real fix is
   infrastructure-level (firewall/ACL or loopback binding), which is a
   sec-review/ops decision, recorded here as the top gap.
2. **G2 (=R2/R3):** dashboard and game listeners equally unfiltered; join
   requires nothing; MD5 digests are the only dashboard credential barrier.
3. **G3 (=R4):** no authenticity check on the mod supply chain; the default
   base tag is floating (a digest is possible through `BASE_IMAGE`, not the
   default).
4. **G4 (=R5):** no rotation procedure; cleartext telnet wire (protocol-
   inherent); `.env` duplication across hosts.
5. **G5:** no `SECURITY.md` and therefore no documented reporting-to-fix path
   (response readiness note below).
6. **G6:** audit evidence exists but is uncollected: no retention, shipping,
   or review guidance for journald/game logs.
7. **G7 (=R6):** the restore path trusts the contents of an operator-named
   archive with no provenance check and no size bound: a restored
   `serveradmin.xml` silently changes who holds admin, and a compression bomb
   is extracted over the live saves. Cheap partial mitigations exist
   (quarantine the archive, diff its `serveradmin.xml` against the live one
   before extracting, bound the extracted size); handing the code fix to
   sec-review.
8. **G8:** save archives are unencrypted credential copies on the same host as
   the credentials they contain, with no off-host copy. Losing the host loses
   the world and its backups together; the README states this, and it is a
   deliberate cost, not a defect.
9. **G9:** `no-new-privileges` is applied on the quadlet path only, so a
   container started by `scripts/run.sh` runs without it.

## Abuse cases (authenticated-hostile-user scenarios)

- **Anonymous player, hostile client (EAC off):** joins without credentials
  (public listing, no password, 8 slots). Can grief the shared world and
  pressure performance; per-player map growth and view distance caps bound
  disk/memory abuse (`config/serverconfig.tmpl.xml:50,78`). Accepted by rule
  3; recorded because it defines the baseline trust a joiner gets for free.
- **Hostile dashboard webuser:** documented panel actions flip the perf-mod
  config and restart the server, and drive the BotMod API
  (`GET/POST /api/bot`, spawn/remove bots, `MODS.md` perf card and Bot section). A
  malicious webuser can loop restarts for continuous availability denial and
  spawn the 16-bot cap (`MODS.md` Bot section) to degrade frame times. Enforcement is
  entirely server-side post-auth; there is no secondary approval.
- **Hostile telnet user:** the console is single-factor root for the game:
  `shutdown` loops, `admin add` self-persistence to level 0
  (`README.md` Configuration), config mutation via `setgamepref`
  (`config/serverconfig.tmpl.xml:107`). This is why R1 ranks first.
- **Host-local writer of `mods/`:** drops a DLL, waits for the next restart;
  `sync_mods` syncs it into the game (`entrypoint.sh` `sync_mods`). Survives
  until the next staging run wipes non-owned names (`scripts/stage_mods.sh` `mods/` wipe).
  A write into the depot `Mods/` dir itself does not outlive a boot either:
  `sync_mods` sweeps every entry `/mods` does not stage, and `sync_tree`
  replaces any staged entry that differs from `/mods` rather than leaving the
  local edit in place.
- **Anyone who can place an archive where an operator restores from**
  (a shared `backups/`, an archive copied from another host, an operator
  handed a `.tar.gz` to "try"): the restore preflight passes as long as the
  member names are in shape, and the extracted `serveradmin.xml` then decides
  dashboard identity and permissions on the next boot
  (`scripts/run.sh` `restore`, `entrypoint.sh` `seed_admin_file`). The operator
  sees "restored ... (start the server to load it)" and no credential event.
  The same archive is the cheapest way to roll a stolen dashboard password back
  to a value the owner has since rotated, which makes it a repudiation tool as
  well as a privilege one.
- **Hostile operator on a shared workstation** is out of scope: `deploy.sh`
  already runs with that person's SSH key and checkout.

None of these were demonstrated against a live system; each is derived from
the named code path.

## Response readiness (notes only)

- Evidence that exists: journald/podman logs (boot, steamcmd, game stdout),
  `data/userdata/Logs/output.log`, command-execution echo
  (`HideCommandExecutionLog=0`), ops-script failure tails
  (`scripts/run.sh` `stop`, `scripts/perf.sh` `measure`). Nothing ships them
  anywhere or reviews them; o11y-review owns log structure.
- No documented path from "vulnerability reported" to "fix shipped":
  `SECURITY.md` does not exist. Creating one requires an org-level contact
  and process decision, noted here rather than invented.

## Model status

- Created 2026-08-26 from a full read of the tree; re-verified 2026-09-28
  against VERSION 1.1.3 after the backup/restore, health-probe, reproducible
  build, and env-key-check changes. Every entry point, boundary, and control
  above carries a file and function reference for the next pass to re-verify.
- Corrected in the 2026-09-28 pass: the seed ships no hardcoded level-0
  admins (`config/serveradmin_seed.xml` `<users>` is empty), the CI badge job
  holds `contents: write` rather than the workflow default, and the backup
  archives, health probe, scheduled timer, and restore path were added as
  surface they are.
- Open organizational items (not invented here): named security owner, review
  cadence, disclosure contact/process (`SECURITY.md`).
