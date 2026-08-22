# 7dtd-server

A 7 Days to Die dedicated server (V3.1.0 line) in a rootless podman container
on the LAN host `server.lan` (192.168.0.100). Stock Navezgane map, stock
default difficulty and settings, with the workspace perf and APM mods loaded:
**EfficientServer** (`7dtd-optimizer`) and **7dtd-apm-bridge** (`7dtd-apm`).
EAC is off (required for C# mods).

Everything runtime lives on the host under `data/`; the container is stateless
and disposable.

## Layout

| Path | What it is |
|---|---|
| `Containerfile` | Image: official `steamcmd/steamcmd` base + game runtime libs + entrypoint |
| `entrypoint.sh` | steamcmd install/validate, config render, admin seed, mod sync, run |
| `config/serverconfig.tmpl.xml` | Stock V3.1.0 template, Navezgane, EAC off, dashboard on |
| `config/serveradmin_seed.xml` | Dashboard admin (level 0) + webuser `admin`/`admin` seed |
| `scripts/stage_mods.sh` | Copy built mods from sibling `dist/` into `mods-available/`, recreate the enabled copies |
| `scripts/deploy.sh` | Stage mods + rsync this project to the server host (`--restart` also restarts the container) |
| `scripts/update_mods.sh` | Server-side: restage enabled mods + restart container (no image rebuild) |
| `scripts/run.sh` | Container lifecycle on the server host (build/start/logs/stop/...) |
| `start.sh` / `stop.sh` | Top-level daily shortcuts: start / graceful stop (wrap `run.sh`) |
| `systemd/7dtd-server.container` | Quadlet for a durable rootless user service |
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

## Ports

| Port | Use |
|---|---|
| 26900 | Game: client "Connect to IP" (LiteNetLib) |
| 26902 | LiteNetLib data port (loadgen bots connect here) |
| 8080 | Web dashboard + APM bridge panel (`admin`/`admin`) |
| 8087 | Telnet console (`TELNET_PORT`) |

Networking is host mode: the server binds directly on the host, no NAT.

## Loading mods

The enabled set is `EfficientServer` and `7dtd-apm-bridge`. To load another
mod (the FPS bot mod, for example):

```bash
cd ~/7dtd-server
cp -a mods-available/BotMod mods/BotMod     # enable (or copy a new mod dir here)
./scripts/run.sh restart
```

`mods-available/` is refreshed from the sibling repo builds:

```bash
# on the workstation: rebuild the mod, then redeploy
cd 7dtd-optimizer && make build              # EfficientServer
cd 7dtd-apm && make bridge-build             # 7dtd-apm-bridge
cd 7dtd-clanker && make build                # BotMod
cd ../7dtd-server && ./scripts/deploy.sh
```

Dropping a mod into `mods/` and restarting is all it takes. Removing it from
`mods/` and restarting disables it (the entrypoint keeps only the stock
`0_TFP_Harmony` from the depot).

**Updating a mod never requires rebuilding the Docker image.** The image is
static; mods are bind-mounted from `mods/` and re-synced by the entrypoint on
every container start. Rebuild the mod in its sibling repo, then one command
from the workstation:

```bash
cd 7dtd-optimizer && make build            # rebuild the mod you changed
cd ../7dtd-server && ./scripts/deploy.sh --restart
```

This stages the new build, rsyncs it to the server, and restarts the
container (which re-copies `mods/` into the game's `Mods/`). On the server
itself, `./scripts/update_mods.sh` does the restage + restart step.

## Configuration

Defaults are the stock serverconfig with minimal changes:

- `GameWorld` Navezgane, `GameName` Navezgane, `GameMode` Survival
- `EACEnabled` false, `ServerAllowCrossplay` false
- `WebDashboardEnabled` true (APM panel), telnet on
- All difficulty/rule properties untouched (stock defaults)

Overrides (all optional):

```bash
export TELNET_PASSWORD=change-me            # telnet console password (default retest)
export TELNET_PORT=8087                     # telnet port (default 8087)
export STEAMCMD_UPDATE=0                    # skip steamcmd validate on next start
```

Or keep them in a git-ignored `.env` file in this directory. The telnet
password is rendered into `serverconfig.xml` at every start.

Add players to the admin list via telnet after joining, e.g.
`admin add <name-if-online> 0` or `admin add Steam <steamid64> 0`.

## Updates and saves

- Every start runs `steamcmd +app_update 294420 validate`, so the game updates
  itself. Set `STEAMCMD_UPDATE=0` for offline/fast restarts.
- Saves live in `data/userdata/Saves/` on the host, never inside the
  container. Delete and recreate the container freely.
- The server also updates configs/`serverconfig.xml` (rendered copy) and the
  game files under `data/game/` on the host, so backups are a plain copy of
  the `data/` directory.

## Durable service (optional)

```bash
podman build -t localhost/7dtd-server:latest .
cp systemd/7dtd-server.container ~/.config/containers/systemd/
systemctl --user daemon-reload
systemctl --user enable --now 7dtd-server
loginctl enable-linger maci
```

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
