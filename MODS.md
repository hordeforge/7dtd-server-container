# Mods on this server

Shipped values below are what the staged mod configs currently contain. All
mod config lives on the host under `mods/<Mod>/Config/` and is bind-mounted
into the container; changing it never requires an image rebuild, only a
container restart (or a live `bot reload` where noted).

## Enabled by default

### EfficientServer (`7dtd-server-optimizer`) v1.17.0 - perf

Toggle on the server host:

```bash
cd ~/7dtd-server
./scripts/perf.sh status            # current state
./scripts/perf.sh off               # disable + restart container
./scripts/perf.sh on                # re-enable + restart container
./scripts/perf.sh measure           # bridge `apm status` snapshot via telnet
```

Or from the web UI: log into the dashboard (`http://192.168.0.100:8080`,
admin) and use the **Performance mod** card at the top of the APM panel; it
flips the same config and restarts the server.

The toggle flips `Enabled` in `mods/EfficientServer/Config/efficientserver.json`
and restarts the container. To observe the difference, keep the world and
player count fixed, grab a `measure` (or an APM capture) with the mod on and
again with it off, and compare frame times / section timings.

Harmony optimization mod, dedicated-only. Feature groups and shipped values
from `mods/EfficientServer/Config/efficientserver.json`:

| Group | Setting | Value | Effect |
|---|---|---|---|
| AiLod | `FullAiDistSq` | 100 | Full AI simulation within 10 m of a player |
| AiLod | `MediumAiDistSq` | 400 | Medium-cost AI within 20 m (scale 0.2) |
| AiLod | `FarScale` | 0.05 | Far AI runs at 5% cost |
| AiLod | `SkipTasksFarDistSq` | 2500 | Skip AI task stacks beyond 50 m |
| AiLod | `SkipTasksUnlessAlerted` | true | Unalerted entities skip far tasks |
| SkipOnDedicated | 6 systems | true | Music, water splash, env audio, cloth/jiggle, explosion particles, ambient light updates skipped on dedicated |
| DynamicMesh | `OnlyPlayerAreas` | true | Mesh streaming only near players / claims |
| DynamicMesh | `PlayerAreaChunkBuffer` | 2 | Buffer radius around players |
| DynamicMesh | `MaxRegionLoadMsPerFrame` | 2 | Mesh load budget per frame |
| DynamicMesh | `MaxActiveSyncs` | 2 | Concurrent mesh syncs |
| Gc | `SkipForcedCollect` | true | Skip forced Boehm GCs |
| Gc | `SafetyCollectRamFraction` | 0.5 | Safety GC when RAM crosses 50% |
| Pathfinding | `GraphUpdateEveryTicks` | 4 | Nav graph update throttle |
| Network | `FastSingleTargetSend` | true | Faster single-target sends |
| Network | `EntityDistributionEveryTicks` | 1 | Per-tick entity distribution |
| WorldTransfer | `ChunkPackagesPerObserverPerTick` | 3 | Chunk transfer pacing |
| Governor | `OverBudgetMs` 57 / `HealthyMs` 52 | - | TPS governor window (defaults) |

Off by default in the shipped config: `TickGuard`, `AnimatorLod`,
`CrowdCollisionLod`. Full feature description:
`7dtd-server-optimizer/docs/FEATURES.md` (sibling repo).

### 7dtd-server-apm-bridge (`7dtd-server-apm`) v2.0.0 - measurement

Timing-only in-server instrumentation. It plugs a **web panel into the stock
dashboard** at `http://192.168.0.100:8080` (web login `admin` / `admin`, or
Steam). Values from `mods/7dtd-server-apm-bridge/Config/apmbridge.json`:

| Setting | Value | Meaning |
|---|---|---|
| `DeepMode` | false | Shallow timing only (low overhead) |
| `SpikeThresholdMs` | 50 | Log spikes over 50 ms |
| `PeriodicExportSeconds` | 30 | Periodic summary cadence |
| `LogPeriodicSummary` / `LogSpikes` | true | Write to server log |
| `MaxSpikeRecords` | 128 | Ring buffer size |

Host-side capture tooling: `7dtd-server-apm` CLI (run from the workstation against
this server's telnet/process).

## Available but not enabled

### BotMod (`7dtd-fps-bots`) - FPS bots

Real player-model bots (Quake-style) that pathfind, hunt, and shoot. Not
enabled by default because it spawns combat bots immediately.

```bash
cd ~/7dtd-server
cp -a mods-available/BotMod mods/BotMod
./start.sh            # or ./scripts/run.sh restart
```

Key options from `mods/BotMod/Config/botmod.json` (after enabling):

| Option | Default | Meaning |
|---|---|---|
| `TargetBotCount` | 6 | Bots kept alive (auto-respawn) |
| `MaxBots` | 16 | Hard cap |
| `Difficulty` | 4 | 0-4: aim jitter, reaction, vision, headshot |
| `BotWeapon` / `LoadoutPool` | mixed | Random from 6 weapons (pistol to sniper) |
| `BotAmmoCount` / `BotHealth` | 300 / 50 | Loadout and health |
| `VisionRange` / `VisionAngle` | 70 / 190 | Detection cone |
| `LoseTargetRange` / `LoseTargetTimeSec` | 85 / 4.5 | Target loss |
| `AttackRange` / `FireRateSec` | 45 / 0.18 | Engagement range / fire rate |
| `RespawnDelaySec` / `SpawnProtectionSec` | 3 | Respawn cadence |
| `UseNeuralBrain` | GA net | Optional evolved neural controller (`evolved/best.json`) |

Live console (telnet `8087`, password from `TELNET_PASSWORD`):
`bot status`, `bot count <n>`, `bot skill <0-4>`, `bot spawn [n]`,
`bot weapon <gunId>`, `bot reload` (reload config live), `bot neural on/off`,
`bot enable|disable`.

**Web UI:** log into the dashboard (`http://192.168.0.100:8080`, admin) and use
the **Bot** entry (robot icon): enable/disable, spawn/remove, static AI vs GA
brain toggle, and the scoreboard (kills, deaths, score per bot). API:
`GET/POST /api/bot`.

## Tuning without rebuilding the image

1. Edit the JSON under `mods/<Mod>/Config/` on the host (or restage a new
   build with `./scripts/deploy.sh --restart` from the workstation).
2. Restart: `./stop.sh && ./start.sh` (BotMod config can be reloaded live
   with `bot reload`).

The Docker image is static; mods are always the bind-mounted `mods/` dir,
re-copied into the game's `Mods/` by the entrypoint at every container start.
