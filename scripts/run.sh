#!/usr/bin/env bash
# Manage the 7dtd-server podman container on the server host (rootless,
# host networking). All runtime state lives in ./data on the host; the
# container itself is disposable.
#
# Usage: run.sh {build|start|install-only|stop|restart|logs|status}
# Env overrides: TELNET_PASSWORD, TELNET_PORT, STEAMCMD_UPDATE,
# STEAMCMD_ONLY, SEVENDTD_CONTAINER_NAME, SEVENDTD_IMAGE.
# A git-ignored .env in this directory is sourced and wins over defaults.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NAME="${SEVENDTD_CONTAINER_NAME:-7dtd-server}"
IMAGE="${SEVENDTD_IMAGE:-localhost/7dtd-server:latest}"
GAME_DIR="$ROOT/data/game"
USERDATA_DIR="$ROOT/data/userdata"

TELNET_PASSWORD="${TELNET_PASSWORD:-retest}"
TELNET_PORT="${TELNET_PORT:-8087}"
STEAMCMD_UPDATE="${STEAMCMD_UPDATE:-1}"
STEAMCMD_ONLY="${STEAMCMD_ONLY:-0}"
if [[ -f "$ROOT/.env" ]]; then
  set -a; source "$ROOT/.env"; set +a
fi

mkdir -p "$GAME_DIR" "$USERDATA_DIR" "$ROOT/mods" "$ROOT/config"

COMMON=(
  --network host
  -e TELNET_PASSWORD="$TELNET_PASSWORD"
  -e TELNET_PORT="$TELNET_PORT"
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

build() {
  podman build -t "$IMAGE" "$ROOT"
}

start() {
  podman rm -f "$NAME" 2>/dev/null || true
  podman run -d --name "$NAME" --restart unless-stopped "${COMMON[@]}" "$IMAGE"
  echo "started $NAME (game 26900, telnet $TELNET_PORT, dashboard 8080)"
}

install_only() {
  podman run --rm --name "$NAME-install" "${COMMON[@]}" "$IMAGE"
}

stop() {
  # The 7dtd server does not shut down on SIGTERM (observed: no save, hung
  # until the stop timeout). Ask it to save + exit via the telnet `shutdown`
  # command, wait for the container to exit, then force-stop as a fallback.
  # A readiness pre-check avoids a stale /dev/tcp session racing a container
  # that was just (re)started and answering telnet on the same host port.
  if podman ps --format '{{.Names}}' | grep -qx "$NAME"; then
    if timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${TELNET_PORT}" >/dev/null 2>&1; then
      timeout 10 bash -c "exec 3<>/dev/tcp/127.0.0.1/${TELNET_PORT}; printf '${TELNET_PASSWORD}\nshutdown\n' >&3; cat <&3" \
        >/dev/null 2>&1 || true
    fi
    for _ in $(seq 1 45); do
      podman ps --format '{{.Status}}' --filter "name=$NAME" | grep -q "Exited" && break
      sleep 2
    done
  fi
  podman stop -t 30 "$NAME" 2>/dev/null || true
}

restart() {
  stop
  start
}

logs()  { podman logs -f "$NAME"; }
status(){ podman ps -a --filter "name=$NAME"; }

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
