#!/usr/bin/env bash
# Manage the 7dtd-server podman container on the server host (rootless,
# host networking). All runtime state lives in ./data on the host; the
# container itself is disposable.
#
# Usage: run.sh {build|start|install-only|stop|restart|logs|status}
# Env overrides: TELNET_PASSWORD, TELNET_PORT, WEBADMIN_PASSWORD,
# STEAMCMD_UPDATE, STEAMCMD_ONLY, SEVENDTD_CONTAINER_NAME, SEVENDTD_IMAGE.
# A git-ignored .env in this directory fills unset variables; variables
# already present in the environment win over it, defaults come last.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

GAME_DIR="$ROOT/data/game"
USERDATA_DIR="$ROOT/data/userdata"

# Load the git-ignored .env via scripts/lib-env.sh (precedence as documented
# in the header). Values are data, never executed, and an explicit override
# such as `TELNET_PORT=9099 ./scripts/run.sh stop` always takes effect.
source "$ROOT/scripts/lib-env.sh"
if [[ -f "$ROOT/.env" ]]; then
  load_env_file "$ROOT/.env"
fi

NAME="${SEVENDTD_CONTAINER_NAME:-7dtd-server}"
IMAGE="${SEVENDTD_IMAGE:-localhost/7dtd-server:latest}"

STEAMCMD_UPDATE="${STEAMCMD_UPDATE:-1}"
STEAMCMD_ONLY="${STEAMCMD_ONLY:-0}"

# Telnet values come from the environment or .env, get the shared lab defaults
# if still unset, and are validated before any container starts (the password
# is sent by telnet_session in stop() and rendered into serverconfig.xml
# inside the container; rationale and rules: scripts/lib-env.sh).
init_telnet_env

# Optional dashboard webuser password: when provided it is validated here so a
# bad value fails on the host instead of mid-boot in the container. When
# unset, the entrypoint mints a random one at seed time (see seed_admin_file);
# the empty pass-through below keeps that behavior.
if [[ -n "${WEBADMIN_PASSWORD:-}" ]]; then
  check_webadmin_password
fi

mkdir -p "$GAME_DIR" "$USERDATA_DIR" "$ROOT/mods" "$ROOT/config"

# Shared container env + mounts.
make_common() {
  COMMON=(
    --network host
    -e TELNET_PASSWORD="$TELNET_PASSWORD"
    -e TELNET_PORT="$TELNET_PORT"
    -e WEBADMIN_PASSWORD="${WEBADMIN_PASSWORD:-}"
    -e STEAMCMD_UPDATE="$STEAMCMD_UPDATE"
    -e STEAMCMD_ONLY="$STEAMCMD_ONLY"
    # :Z relabels the sources to container_file_t (SELinux enforcing RHEL host).
    # mods is rw: the /api/perf toggle writes the EfficientServer config there
    # (the game itself never touches /mods; the entrypoint copies it to the game
    # Mods at every start, so a flipped config applies on the next boot).
    -v "$GAME_DIR:/root/7dtd:Z"
    -v "$USERDATA_DIR:/root/.local/share/7DaysToDie:Z"
    -v "$ROOT/mods:/mods:Z"
    -v "$ROOT/config:/config:ro,Z"
  )
}

build() {
  podman build -t "$IMAGE" "$ROOT"
}

start() {
  # Recreating over a live container must go through the graceful stop first:
  # podman rm -f on a running game kills it with no world save, the exact loss
  # stop() exists to prevent. stop() no-ops fast when nothing is running; a
  # wedged container falls through to its forced-stop path (~2 min worst case).
  stop
  podman rm -f "$NAME" 2>/dev/null || true
  make_common
  # --init: catatonit takes PID 1 and reaps orphans/zombies for the game's
  # whole uptime; without it, children the server forks but never waits on
  # accumulate as zombies until the container restarts.
  podman run -d --name "$NAME" --restart unless-stopped --init "${COMMON[@]}" "$IMAGE"
  echo "started $NAME (game 26900, telnet $TELNET_PORT, dashboard 8080)"
}

install_only() {
  # Same stale-name guard start() applies; a crashed prior --rm run can leave
  # the name behind and podman refuses to reuse it.
  podman rm -f "$NAME-install" 2>/dev/null || true
  # Force the pre-warm mode: install-only must download/validate and exit,
  # never boot the game server, even if the environment or .env set
  # STEAMCMD_ONLY=0.
  STEAMCMD_ONLY=1
  make_common
  # --init: same reaper as start(); steamcmd forks a bootstrap that must not
  # linger if it outlives its parent mid-download.
  podman run --rm --name "$NAME-install" --init "${COMMON[@]}" "$IMAGE"
}

stop() {
  # The 7dtd server does not shut down on SIGTERM (observed: no save, hung
  # until the stop timeout). Ask it to save + exit via the telnet `shutdown`
  # command, wait for the container to exit, then force-stop as a fallback.
  # A readiness pre-check avoids a stale /dev/tcp session racing a container
  # that was just (re)started and answering telnet on the same host port.
  if podman ps --format '{{.Names}}' | grep -Fx "$NAME"; then
    echo "requesting save + shutdown via telnet ..."
    if telnet_probe "$TELNET_PORT" 3 >/dev/null 2>&1; then
      # A failed shutdown request (rejected password, dropped connection) must
      # name its cause here: swallowing it would surface only as the 90s wait
      # timeout below, and the resulting forced stop skips the world save --
      # the exact loss this function exists to prevent.
      local reply
      if reply="$(telnet_session "$TELNET_PORT" "$TELNET_PASSWORD" 'shutdown' 10 2>&1)"; then
        :
      else
        echo "WARN: telnet shutdown request failed; forcing stop without a world save" >&2
        printf '%s\n' "${reply:-<no output>}" | tail -n 3 >&2
      fi
    else
      echo "telnet not reachable on $TELNET_PORT; falling back to forced stop"
    fi
    # Event-driven exit wait: one blocking `podman wait` instead of spawning
    # a rootless `podman inspect` on an interval. timeout(1) exits 124 only
    # when the 90s budget runs out with the container still up, which is the
    # force-stop signal; any other failure (e.g. container already gone)
    # falls through silently to the idempotent stop below.
    local wait_rc=0
    timeout 90 podman wait "$NAME" >/dev/null 2>&1 || wait_rc=$?
    if [[ "$wait_rc" == 124 ]]; then
      echo "container still running after telnet shutdown; forcing stop"
    fi
  fi
  # Idempotent final stop. Failure means either an already-gone container
  # (the normal no-op) or real trouble; a real failure must not read as
  # success, because the world save may never have happened.
  if ! podman stop -t 30 "$NAME" >/dev/null 2>&1; then
    if podman ps -a --format '{{.Names}}' 2>/dev/null | grep -Fx "$NAME"; then
      echo "FATAL: podman stop failed but $NAME still exists; check podman logs/events" >&2
      exit 1
    fi
    if ! podman info >/dev/null 2>&1; then
      echo "FATAL: podman stop failed and podman is unreachable; container state unknown" >&2
      exit 1
    fi
    # Daemon reachable and the container is gone: the idempotent no-op case.
  fi
}

restart() {
  stop
  start
}

logs() { podman logs -f "$NAME"; }
# Anchor the name filter: podman treats it as a regex, and unanchored it would
# also list the $NAME-install pre-warm container.
status() { podman ps -a --filter "name=^${NAME}$"; }

case "${1:-status}" in
  build)        build ;;
  start|run)    start ;;
  install-only) install_only ;;
  stop)         stop ;;
  restart)      restart ;;
  logs)         logs ;;
  status)       status ;;
  *)
    echo "usage: $0 {build|start|install-only|stop|restart|logs|status}" >&2
    exit 1
    ;;
esac
