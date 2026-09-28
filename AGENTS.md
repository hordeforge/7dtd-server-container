# AGENTS.md - 7dtd-server

Deployment harness for a 7 Days to Die dedicated server (V3.2.0 line) in a
rootless podman container on the LAN server host (192.168.0.100). Owns the
container image, server config template, mod staging, and ops scripts. It does
NOT own mod code, measurement, or game RE; those live in the sibling repos.

Workspace root guide: [`hordeforge/.github` AGENTS.md](https://github.com/hordeforge/.github/blob/main/AGENTS.md) and
[`hordeforge/.github` MODDING_BEST_PRACTICES.md](https://github.com/hordeforge/.github/blob/main/MODDING_BEST_PRACTICES.md).

## Owns

| Thing | Where |
|---|---|
| Container image (steamcmd base) + entrypoint | `Containerfile`, `entrypoint.sh` |
| Server config template (stock Navezgane defaults, EAC off) | `config/serverconfig.tmpl.xml` |
| Dashboard admin/webuser seed | `config/serveradmin_seed.xml` |
| Mod staging from sibling `dist/` + enabled copies | `scripts/stage_mods.sh`, `mods/`, `mods-available/` |
| Deploy + container lifecycle + ops scripts | `scripts/deploy.sh` (`--restart`), `scripts/update_mods.sh`, `scripts/run.sh`, `scripts/perf.sh`; shared `.env`/telnet lib: `scripts/lib-env.sh` |
| Enabled tweaks + bot options doc | `MODS.md` |
| CI workflow + tests and helpers | `.github/workflows/ci.yml`, `.github/dependabot.yml`, `uv.lock`, `Makefile`, `scripts/test_lib_env.sh`, `scripts/fake-telnet-server.py`, `scripts/check-config-xml.py`, `scripts/coverage_badge.py`, `scripts/harness.py` (shared check reporter and sandbox PATH builder for every `test_*.py` suite), `scripts/test_coverage_badge.py`, `scripts/test_check_config_xml.py`, `scripts/test_config_templates.py`, `scripts/test_deploy_sh.py`, `scripts/test_entrypoint_boot.py`, `scripts/test_systemd_unit.py`, `scripts/test_containerfile.py`, `scripts/test_run_sh.py`, `scripts/test_perf_sh.py`, `scripts/test_stage_mods.py`, `scripts/test_makefile.py`, `scripts/test_fuzz_xml.py` (seeded fuzz harness for the XML config parsers; `test_*` so the gate runs it, invariants asserted, not crash-only), `scripts/test_fuzz_env.sh` (the same for the `.env` loader and the value/port/switch rules in `lib-env.sh`; bash, so it is named in `make test` beside `scripts/test_lib_env.sh`), `scripts/check_release_gate.sh` + `scripts/test_release_gate.py` (the release tag gate and the suite that runs the real script) |
| Static analysis config (ruff + ruff format, mypy strict, yamllint) | `pyproject.toml`, `.yamllint.yaml` (enforced via `make lint` locally and in CI, versions pinned in the `dev` group of `pyproject.toml`, locked in `uv.lock`) |
| Dependency inventory (CycloneDX 1.6) of the pinned closure | `scripts/sbom.py` (`make sbom` -> `dist/sbom.cdx.json`, git-ignored and generated, never committed), `scripts/test_sbom.py`; the release workflow records it in the run summary per tag. Pins, markers and sha256 hashes come from `uv.lock`, licenses from the installed venv METADATA, and the document carries no timestamp so the same lock regenerates it byte for byte |
| Contributor path (setup, single-suite loop, PR rules) | `README.md` "Development", `CONTRIBUTING.md` (`make help`, `make check`, `make test-one SUITE=<name>`, `make format`) |
| Threat model (entry points, boundaries, controls, ranked gaps) | `docs/THREAT_MODEL.md` |
| Rootless systemd service unit | `systemd/7dtd-server.container` |
| Daily save-backup schedule | `systemd/7dtd-backup.service`, `systemd/7dtd-backup.timer` (runs `run.sh backup`) |
| Weekly archive readability check | `systemd/7dtd-backup-verify.service`, `systemd/7dtd-backup-verify.timer` (runs `run.sh verify-backup`) |
| Version (canonical home) + changelog + tag gate | `VERSION` (`run.sh version`), `CHANGELOG.md`, `.github/workflows/release.yml` (calls `scripts/check_release_gate.sh`: the tag must match `VERSION`, have a dated `## [X.Y.Z]` section, be newer than every released version in the changelog, and ship as a major bump when its section groups entries under `### Breaking changes`); the image's `org.opencontainers.image.version` label copies it and `scripts/test_containerfile.py` fails the gate when they drift |
| Player-data inventory, host file modes, erasure path | `README.md` "Player data on the host"; `ensure_private_dir` in `scripts/run.sh`, `ensure_private_file` in `scripts/lib-env.sh` and the entrypoint's process-wide `umask 077` are what keep `data/`, `backups/` and `.env` owner-only |

## Does not own

- Mod source and builds (sibling repos: `7dtd-server-optimizer`, `7dtd-server-apm`,
  `7dtd-fps-bots`, etc). Staging only copies their `dist/` output.
- Game RE, measurement, load generation (see workspace root AGENTS.md).
- Playtest orchestration. `7dtd-playtest` may attach to this host for fidelity
  scoring with `--no-server --readonly`; that flag combination forbids wiping,
  mod staging, config rewriting and restarting on its side, and this repo
  grants nothing beyond a telnet login. Production stays alone here. See
  [ADR 0001](https://github.com/hordeforge/.github/blob/main/docs/adr/0001-test-tiers-and-declarative-suites.md).

## Rules

1. **Never commit runtime data.** `data/`, `mods/`, `mods-available/` are
   git-ignored; regen with `scripts/stage_mods.sh` after sibling builds.
2. **Never redistribute game assemblies.** The container pulls the game from
   Steam (app 294420) via steamcmd at first start; no game files are tracked.
3. **EAC must stay off** for C# mods (EfficientServer, APM bridge, BotMod).
4. **Code mods need stock `0_TFP_Harmony`**; the entrypoint keeps the depot
   copy and warns if it is missing.
5. **All runtime data lives on the host under `data/`.** The container is
   disposable; deleting and recreating it must never lose saves or mods.
6. **Secrets via env only** (`.env`, git-ignored): telnet password, webuser.
   `TELNET_PASSWORD` is required; the committed `retest` default is public and
   opt-in only, via `ALLOW_PUBLIC_DEFAULT_TELNET_PASSWORD=1` (same as the
   workspace lab). The webadmin password is minted at first seed when unset.
   Secret values are printable ASCII, enforced by `printable_ascii_check`
   under `LC_ALL=C` (`reject_unsafe_value` turns its answer into the refusal)
   so the host and the container agree whatever locale either runs under.
7. **No AI attribution, no em dashes** in shipped text.
8. Version pin: mods are built for V3.2.0. If a newer depot build ships and
   mods fail to load, rebuild mods in the sibling repos, restage, redeploy.
9. **`uv` is the only Python toolchain.** `make lint` and `make test` build
   `.venv` from the hash-pinned `uv.lock` (`uv sync --locked`); CI installs the `uv`
   binary and runs the same targets. Never `pip`, and never a bare `python3`
   in a gate.
10. **This container keeps its own config renderer.** The lab's shared
    renderer (`7dtd-sandbox/scripts/sbconfig.py`) covers instance
    serverconfigs; the `@TOKEN@` template plus `assert_rendered` here is a
    container boot check with different failure semantics and its own tests.
    Do not merge them.
11. **Threat-model references name files and functions, not line numbers.**
    Line pins in `docs/THREAT_MODEL.md` rotted within five commits; only
    `config/serverconfig.tmpl.xml` (stock TFP content) keeps line numbers.
12. **The container's own output goes through `log`/`warn`/`fatal`.** All
    three stamp `ts=<UTC>`, `boot=<id>` and `level=<severity>`; that stamped
    shape is what `scripts/test_entrypoint_boot.py` parses, so a boot step
    that reports itself with a bare `echo` breaks the one record a failed boot
    leaves. Severity is the field, never a prefix inside the message, and
    `warn` (not `log ... >&2`) is what a diagnostic uses.

## Operations (on the server host)

```bash
./scripts/run.sh build        # build the image
./scripts/run.sh start        # first start = steamcmd install (large download)
./scripts/run.sh logs         # follow logs
./scripts/run.sh stop         # graceful stop (saves world)
./scripts/run.sh install-only # download/validate game then exit (pre-warm; refuses while the server runs)
./scripts/run.sh status       # container state + health probe (telnet connect, no password)
./scripts/run.sh config       # effective config + value source, secrets redacted
./scripts/run.sh backup       # archive data/userdata/{Saves,Logs} into backups/ (keeps the newest 7)
./scripts/run.sh restore      # put an archive back (no arg = newest); archives the replaced saves first
./start.sh / ./stop.sh        # daily start/stop shortcuts (wrap run.sh)
```

Durable service: quadlet in `systemd/` (see its header). The save backup
runs daily from `systemd/7dtd-backup.timer` and is re-read weekly by
`systemd/7dtd-backup-verify.timer`; `backups/` stays on this
host, so copy it off-host if losing the host must not cost the world
(README "Recovering state" states the RPO/RTO). Load a mod: copy the
mod dir into `mods/` (real copies, not symlinks: `mods/` is bind-mounted and
must be self-contained), then restart the container.

## Ports

| Port | Use |
|---|---|
| 26900 | Game (client "Connect to IP", LiteNetLib) |
| 26902 | LiteNetLib data port (loadgen bots) |
| 8080 | Web dashboard (APM bridge panel) |
| 8087 | Telnet console (`TELNET_PORT`; default lab harness port was 8081 but that is occupied on this host) |

## Sibling projects

| Project | Role |
|---|---|
| `../7dtd-server-optimizer` | EfficientServer perf mod (staged, enabled) |
| `../7dtd-server-apm` | APM bridge + host measurement (staged, enabled) |
| `../7dtd-fps-bots` | BotMod FPS bots (staged, enabled by default) |
| `../7dtd-loadgen` | LiteNetLib bots + lab dedicated bring-up scripts (reference behavior) |
| `../7dtd-fastconnect` | Client join-by-IP mod used for join verification |

## Stock-game research -> 7dtd-engine-research

Game internals RE lives in `../7dtd-engine-research/`, never here. This project only
deploys the stock dedicated server and the reviewed sibling mods.
