# AGENTS.md - 7dtd-server

Deployment harness for a 7 Days to Die dedicated server (V3.1.0 line) in a
rootless podman container on the LAN server host (192.168.0.100). Owns the
container image, server config template, mod staging, and ops scripts. It does
NOT own mod code, measurement, or game RE; those live in the sibling repos.

Workspace root guide: [`../AGENTS.md`](../AGENTS.md) and
[`../MODDING_BEST_PRACTICES.md`](../MODDING_BEST_PRACTICES.md).

## Owns

| Thing | Where |
|---|---|
| Container image (steamcmd base) + entrypoint | `Containerfile`, `entrypoint.sh` |
| Server config template (stock Navezgane defaults, EAC off) | `config/serverconfig.tmpl.xml` |
| Dashboard admin/webuser seed | `config/serveradmin_seed.xml` |
| Mod staging from sibling `dist/` + enabled copies | `scripts/stage_mods.sh`, `mods/`, `mods-available/` |
| Deploy + container lifecycle + ops scripts | `scripts/deploy.sh` (`--restart`), `scripts/update_mods.sh`, `scripts/run.sh`, `scripts/perf.sh`; shared `.env`/telnet lib: `scripts/lib-env.sh` |
| Enabled tweaks + bot options doc | `MODS.md` |
| CI workflow + lib-env tests and helpers | `.github/workflows/ci.yml`, `Makefile`, `scripts/test_lib_env.sh`, `scripts/fake-telnet-server.py`, `scripts/check-config-xml.py`, `scripts/coverage_badge.py` |
| Static analysis config (ruff + ruff format, mypy strict, yamllint) | `pyproject.toml`, `.yamllint.yaml` (enforced via `make lint` locally and in CI, pinned versions) |
| Rootless systemd service unit | `systemd/7dtd-server.container` |

## Does not own

- Mod source and builds (sibling repos: `7dtd-server-optimizer`, `7dtd-server-apm`,
  `7dtd-fps-bots`, etc). Staging only copies their `dist/` output.
- Game RE, measurement, load generation (see workspace root AGENTS.md).

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
   The committed defaults are test-only (same as the workspace lab).
7. **No AI attribution, no em dashes** in shipped text.
8. Version pin: mods are built for V3.1.0. If a newer depot build ships and
   mods fail to load, rebuild mods in the sibling repos, restage, redeploy.

## Operations (on the server host)

```bash
./scripts/run.sh build        # build the image
./scripts/run.sh start        # first start = steamcmd install (large download)
./scripts/run.sh logs         # follow logs
./scripts/run.sh stop         # graceful stop (saves world)
./scripts/run.sh install-only # download/validate game then exit (pre-warm)
./start.sh / ./stop.sh        # daily start/stop shortcuts (wrap run.sh)
```

Durable service: quadlet in `systemd/` (see its header). Load a mod: copy the
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
