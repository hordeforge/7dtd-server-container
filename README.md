# 🏰 Outpost (7DTD Server Container)

> **Part of [HordeForge](https://github.com/hordeforge)**: High-Performance Systems Engineering for 7 Days to Die.

![CI](https://github.com/hordeforge/7dtd-server-container/actions/workflows/ci.yml/badge.svg)
![coverage](https://raw.githubusercontent.com/hordeforge/7dtd-server-container/badges/coverage.svg)
![release](https://img.shields.io/github/v/release/hordeforge/7dtd-server-container)
![license](https://img.shields.io/github/license/hordeforge/7dtd-server-container)

A 7 Days to Die dedicated server (V3.2.0 line) in a rootless podman container on the LAN host `server.lan` (192.168.0.100). Stock Navezgane map, stock default difficulty and settings, with the workspace perf, APM and FPS-bot mods loaded: **Crucible** (`7dtd-server-optimizer`), **Geiger** (`7dtd-server-apm`) and **BotMod** (`7dtd-fps-bots`). EAC is off (required for C# mods).

Everything runtime lives on the host under `data/`; the container is stateless
and disposable.

## Status

Running in production on the LAN host. Working: image build, steamcmd
install/validate with bounded retries, config render and admin seed, mod
staging and per-boot sync, graceful stop that saves the world first, save
backups with retention and a verified restore path, and the quadlet service.
`make lint` and `make test` gate every push.

Partial: coverage is measured for `scripts/lib-env.sh` only, so the badge
covers the shared library rather than the whole tree. Rollback of code or mods
is manual (redeploy an older sibling build).

Deliberately not built: no firewall or ACL in front of the listeners, no
signature check on the staged mods, no credential rotation procedure, no
off-host copy of the save archives (the recovery section below states what
losing the host costs), and no `SECURITY.md`. Each is a ranked gap with its
reasoning in [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md); read that before
exposing this host beyond a trusted LAN.

## Layout

| Path | What it is |
|---|---|
| `Containerfile` | Image: official `steamcmd/steamcmd` base + game runtime libs + entrypoint |
| `entrypoint.sh` | steamcmd install/validate, config render, admin seed, mod sync, run |
| `config/serverconfig.tmpl.xml` | Stock V3.2.0 template, Navezgane, EAC off, dashboard on |
| `config/serveradmin_seed.xml` | Dashboard admin (level 0) + webuser seed (password from `WEBADMIN_PASSWORD`, random at first seed) |
| `scripts/stage_mods.sh` | Copy built mods from sibling `dist/` into `mods-available/`, recreate the enabled copies |
| `scripts/deploy.sh` | Stage mods + rsync this project to the server host (`--restart` also restarts the container) |
| `scripts/update_mods.sh` | Server-side: restage enabled mods + restart container (no image rebuild) |
| `scripts/run.sh` | Container lifecycle on the server host (build/start/install-only/logs/stop/backup/restore/status/version; `--help` lists them) |
| `scripts/perf.sh` | EfficientServer toggle (`on`/`off`/`status`) + telnet `apm status` snapshot (`measure`) |
| `scripts/lib-env.sh` | Shared `.env` loader, telnet value validation, telnet session helper (sourced by the ops scripts) |
| `start.sh` / `stop.sh` | Top-level daily shortcuts: start / graceful stop (wrap `run.sh`) |
| `Makefile` | `make test`, `make lint` (bash -n + shellcheck + reference check over every shell script; ruff rules/format, mypy strict, yamllint over Python and CI YAML; Containerfile structure check). Needs [`uv`](https://docs.astral.sh/uv/) on PATH: both targets build `.venv` from `requirements-lint.txt` themselves |
| `pyproject.toml`, `.yamllint.yaml`, `requirements-lint.txt` | Static analysis config (ruff rules + 100-col format, mypy strict, yamllint) and the hash-pinned analyzer closure; enforced by `make lint` locally and in CI from the same recipe |
| `.github/workflows/ci.yml` | CI: lint, tests, Containerfile and config-template validation; publishes the coverage badge on main |
| `scripts/test_lib_env.sh`, `scripts/test_coverage_badge.py`, `scripts/test_check_config_xml.py`, `scripts/test_config_templates.py`, `scripts/test_deploy_sh.py`, `scripts/test_entrypoint_boot.py`, `scripts/test_systemd_unit.py`, `scripts/test_containerfile.py`, `scripts/test_run_sh.py`, `scripts/test_perf_sh.py`, `scripts/test_stage_mods.py` | Tests behind `make test`; `fake-telnet-server.py` is their fake telnet endpoint fixture |
| `scripts/check-config-xml.py`, `scripts/coverage_badge.py`, `scripts/harness.py` | CI helpers: config XML well-formedness check, coverage badge renderer, shared check reporter for the suites above |
| `systemd/7dtd-server.container` | Quadlet for a durable rootless user service |
| `docs/THREAT_MODEL.md` | Attack surface of this harness: entry points, trust boundaries, existing controls, ranked gaps |
| `mods/` (runtime) | Enabled mods, bind-mounted into the container |
| `mods-available/` (runtime) | All staged mod builds |
| `data/` (runtime) | `game/` (steamcmd install), `userdata/` (saves, logs, serveradmin.xml) |

`mods/`, `mods-available/`, `data/` and `.env` are git-ignored: mods are
rebuilt in their sibling repos, data is host state.

**Mods on this server (enabled tweaks, APM panel, bot options): see
[`MODS.md`](MODS.md).**

## Quick start

```bash
# from a machine with SSH access to the server host:
./scripts/deploy.sh                          # stage mods + rsync to 192.168.0.100

# on the server host (ssh maci@192.168.0.100):
cd ~/7dtd-server
./scripts/run.sh build                       # build image (pulls steamcmd base)
./scripts/run.sh start                       # first start downloads the game (~GBs)
./scripts/run.sh logs                        # watch boot; wait for "StartGame done"
# daily use: ./start.sh and ./stop.sh are the shortcuts
```

### Reproducible image builds

`run.sh build` passes `SOURCE_DATE_EPOCH` to podman as `--timestamp`, so an
exported value gives every layer the same fixed mtime and a second build of one
tree can be diffed against the first instead of trusted:

```bash
SOURCE_DATE_EPOCH=1700000000 ./scripts/run.sh build
```

The base image is a build arg, so a build that must be repeatable from
upstream's side pins it to a digest without editing the `Containerfile`:

```bash
podman build -t localhost/7dtd-server:latest \
  --build-arg BASE_IMAGE=docker.io/steamcmd/steamcmd@sha256:<digest> .
```

The apt packages the image installs on top of the base are still resolved at
build time, so a byte-identical image needs both: the digest and the same
`SOURCE_DATE_EPOCH`.

## Ports

| Port | Use |
|---|---|
| 26900 | Game: client "Connect to IP" (LiteNetLib) |
| 26902 | LiteNetLib data port (loadgen bots connect here) |
| 8080 | Web dashboard + APM bridge panel (webuser `admin`, password: `WEBADMIN_PASSWORD` or the minted-record file `data/userdata/Saves/.webadmin-password`) |
| 8087 | Telnet console (`TELNET_PORT`) |

Networking is host mode: the server binds directly on the host, no NAT.

`./scripts/run.sh status` shows the podman health status next to the container
state: the probe opens a TCP connection to the telnet console and sends no
password, so a server that is running but no longer serving reads `unhealthy`
(the first 30 minutes after a start are exempt, since a first boot downloads
the depot before the game opens the port). A health status is reported, never
acted on: podman does not restart or kill on it.

## Loading mods

The enabled set is `EfficientServer`, `7dtd-server-apm-bridge` and `BotMod`
(see [`MODS.md`](MODS.md)). To unload a mod, remove its dir from `mods/`; to
load another one, copy it in:

```bash
cd ~/7dtd-server
rm -rf mods/BotMod                          # example: disable the FPS bots
./scripts/run.sh restart
```

`mods-available/` is refreshed from the sibling repo builds:

```bash
# on the workstation: rebuild the mod, then redeploy
cd 7dtd-server-optimizer && make build              # EfficientServer
cd ../7dtd-server-apm && make bridge-build          # 7dtd-server-apm-bridge
cd ../7dtd-fps-bots && make build                   # BotMod
cd ../7dtd-server-container && ./scripts/deploy.sh
```

Dropping a mod into `mods/` and restarting is all it takes. Removing it from
`mods/` and restarting disables it (the entrypoint keeps only the stock
`0_TFP_Harmony` from the depot). `scripts/stage_mods.sh` owns the enabled set
and wipes everything else out of `mods/` on every successful `deploy.sh`
staging run, so removing a staged mod only holds until the next deploy; drop
its name from `NAMES` in `stage_mods.sh` to keep it out. A staging run that
fails part way leaves `mods/` exactly as it found it.

**Updating a mod never requires rebuilding the container image.** The image is
static; mods are bind-mounted from `mods/` and re-synced by the entrypoint on
every container start. Rebuild the mod in its sibling repo, then one command
from the workstation:

```bash
cd 7dtd-server-optimizer && make build            # rebuild the mod you changed
cd ../7dtd-server-container && ./scripts/deploy.sh --restart
```

This stages the new build, rsyncs it to the server, and restarts the
container (which syncs `mods/` into the game's `Mods/`). On the server
itself, `./scripts/update_mods.sh` does the restage + restart step.

## Configuration

Defaults are the stock serverconfig with minimal changes:

- `GameWorld` Navezgane, `GameName` Navezgane, `GameMode` Survival
- `EACEnabled` false, `ServerAllowCrossplay` false
- `WebDashboardEnabled` true (APM panel), telnet on
- All difficulty/rule properties untouched (stock defaults)

Overrides:

```bash
export TELNET_PASSWORD=change-me            # telnet console password; required,
                                            # there is no default (see below)
export TELNET_PORT=8087                     # telnet port (default 8087)
export WEBADMIN_PASSWORD=change-me          # dashboard webuser password; if unset a
                                            # random one is minted at first seed and
                                            # written to data/userdata/Saves/.webadmin-password
export STEAMCMD_UPDATE=0                    # skip steamcmd validate on next start
```

`TELNET_PASSWORD` is required. The committed lab default (`retest`) is public
and a set telnet password makes the game listen on every interface, so a boot
without one stops with a `FATAL` instead of falling back. To run the lab on the
public default, opt in explicitly:

```bash
export ALLOW_PUBLIC_DEFAULT_TELNET_PASSWORD=1
```

The telnet console is full server control (`shutdown`, `admin add`,
`setgamepref`); on a LAN-reachable listener the public default is a takeover
waiting to happen.

The dashboard webuser password is never stored in the repo: at first seed the
entrypoint takes `WEBADMIN_PASSWORD` (min 8 chars) or generates a random value,
writes only its MD5 digest into `data/userdata/Saves/serveradmin.xml`, and
records a minted plaintext once in the owner-only file
`data/userdata/Saves/.webadmin-password` (never in the container log, which
journald retains indefinitely). For the quadlet path, add
`Environment=WEBADMIN_PASSWORD=...` to `systemd/7dtd-server.container` before
installing it.

Or keep them in a git-ignored `.env` file in this directory; copy
[`.env.example`](.env.example) as the starting point. Values are taken
literally (no shell expansion); one matching pair of surrounding quotes is
stripped. The telnet password is rendered into `serverconfig.xml` at every
start, so it must be printable ASCII: no backslash, pipe, ampersand,
single/double quotes, dollar, backtick, angle brackets, control characters, or
non-ASCII characters; the port must be in 1..65535. Both are checked before the
container starts, by the same code on the host and inside the container, and
the check does not depend on the locale either side happens to run under.

Add players to the admin list via telnet after joining, e.g.
`admin add <name-if-online> 0` or `admin add Steam <steamid64> 0`.

## Updates and saves

- Every start runs `steamcmd +app_update 294420 validate`, so the game updates
  itself. Set `STEAMCMD_UPDATE=0` for offline/fast restarts.
- Saves live in `data/userdata/Saves/` on the host, never inside the
  container. Delete and recreate the container freely.
- Runtime state beyond saves lives on the host too: the rendered
  `serverconfig.xml` (`data/game/serverconfig.xml`) and the game install
  under `data/game/`.
- Back up the saves with `./scripts/run.sh backup`: it asks the running
  server to `saveworld` via telnet first (best effort; a skipped save only
  warns), archives `data/userdata/Saves/` to `backups/7dtd-saves-<UTC stamp>
  .tar.gz` (owner-only, it carries `serveradmin.xml` and the webadmin record),
  and keeps the newest 7 archives by that stamp, which is UTC so the order
  survives a DST transition or a host timezone change. `deploy.sh` never
  touches `backups/`. Rollback of code or mods is not automated: redeploy an
  older sibling build; saves are unaffected by deploys.

## Recovering state

`backups/` sits on the same host as the saves it protects, so it survives a
bad deploy, a bad config and a deleted world, but not the loss of the host
itself. Copy archives off the host if that loss matters (rsync them to
another machine or an off-host store on whatever schedule you run backups);
nothing in this repo does it for you.

Restoring:

```bash
./stop.sh                      # or ./scripts/run.sh stop
./scripts/run.sh restore       # newest archive in backups/
./scripts/run.sh restore backups/7dtd-saves-20260901-120000.tar.gz
./start.sh
```

`restore` verifies the archive (readable gzip/tar, carries a `Saves/`
payload, no entry escaping the archive root) before it touches anything, and
refuses while the server runs, because the game would write over the restored
files. The saves it replaces are archived first into `backups/` as
`7dtd-saves-<UTC stamp>-prerestore.tar.gz`, so a restore is reversible: run
`restore` against that pre-restore archive by name to go back. The
no-argument form never picks a `-prerestore` archive, so a retried bare
`restore` re-applies the same backup instead of undoing the first one. The
restored files keep the owner-only mode the archives use
(`serveradmin.xml` and the webadmin record are credentials).

- **RPO:** the time since the last backup. With `7dtd-backup.timer` enabled
  that is under a day, plus whatever ran last before the host was off; with
  only the ad-hoc command, it is however long since anyone remembered.
- **RTO:** stop (up to about 2 min worst case, the telnet save plus forced
  stop) plus the extract of the archive, which is minutes for a world of
  normal size. Start the server and the world loads.
- Configs, the game install and the admin seed are not backed up: they
  re-render from `config/` or re-download from Steam on the next start. The
  `.webadmin-password` record and `serveradmin.xml` are inside the archives,
  so the dashboard credentials come back with the saves.

## Durable service (optional)

```bash
podman build -t localhost/7dtd-server:latest .
cp systemd/7dtd-server.container ~/.config/containers/systemd/
cp systemd/7dtd-backup.{service,timer} ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user enable --now 7dtd-server
systemctl --user enable --now 7dtd-backup.timer
loginctl enable-linger maci
```

`7dtd-backup.timer` runs `./scripts/run.sh backup` daily (04:17, with up to
10 minutes of jitter, and a missed day runs at the next boot). Without it
nothing bounds the RPO: the world is only as safe as the last time you
remembered. A failed run leaves the unit failed, visible in
`systemctl --user status 7dtd-backup.service` and the journal.

Stops and restarts of the service go through the same graceful path as
`./stop.sh` (telnet save + shutdown before the container is killed), via the
unit's `ExecStop`. The unit pins no `TELNET_PASSWORD`/`TELNET_PORT`: those
defaults live in `scripts/lib-env.sh`, shared with the ops scripts. If you
override them (or `WEBADMIN_PASSWORD`) via `Environment=` lines in the unit,
mirror the telnet values in `.env` on the server host so the graceful-stop
login still matches.

## Troubleshooting

- **Game downloads on first start only.** `podman logs 7dtd-server` shows
  steamcmd progress; a few GB take a while on a slow link.
- **Client kicks / chunk stream errors:** client and server must be the same
  game version and both vanilla-terrain (no RealEarth on either side).
- **Mods not loading:** check `data/userdata/Logs/output.log` for
  `0_TFP_Harmony` presence and per-mod `InitMod` lines. If a newer depot
  build shipped, rebuild the mods for it (see AGENTS.md version pin).
- **SELinux (RHEL host):** all mounts carry `:Z`, which relabels the sources
  to `container_file_t` on each start. If new mods or data appear unwritable,
  they were copied in after the last start; restart the container.
- **Telnet blocked:** a password is set, so the telnet interface listens on
  all interfaces; confirm nothing else uses `TELNET_PORT`.
- **`(unhealthy)` in `run.sh status`:** the container is up but the telnet
  console stopped answering, so the game is wedged rather than gone. Read
  `podman logs --tail 50 7dtd-server` and the game log under
  `data/userdata/Logs/`, then `./scripts/run.sh restart`.
