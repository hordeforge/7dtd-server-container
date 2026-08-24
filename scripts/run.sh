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

# Owner-only file carrying TELNET_PASSWORD/WEBADMIN_PASSWORD into the
# container (written by make_common, removed at exit). Empty when no
# container was started, e.g. on stop/status.
SECRET_ENV_FILE=""
# Release every env file this run owns, keyed on the PID embedded in the
# name rather than on $SECRET_ENV_FILE: acquisition spans the mktemp
# subprocess and the assignment, and a signal arriving in between must still
# find a working release path (the CI suite races exactly that window).
cleanup_secret_env_file() {
  local f
  for f in "${TMPDIR:-/tmp}"/7dtd-container-env."$$".*; do
    if [[ -f "$f" ]]; then
      rm -f -- "$f" || true
    fi
  done
}
trap cleanup_secret_env_file EXIT
# Bash runs EXIT traps on a normal exit or after a trapped signal only:
# killed by an untrapped SIGINT/SIGTERM/SIGHUP it dies without cleanup, and
# an everyday Ctrl-C during the multi-minute podman run would strand the
# credential-bearing env file. Each handler routes through the EXIT trap and
# exits with the conventional 128+N status. SIGKILL stays uncovered here;
# make_common sweeps what it leaves behind.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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

# Secret env files orphaned by a killed previous run (SIGKILL bypasses every
# trap) would accumulate in $TMPDIR forever: mktemp never reuses a name and
# each file carries both secrets. The owning PID therefore rides in the file
# name, and make_common sweeps entries whose owner is gone; a live concurrent
# run's file (its PID answers kill -0) is left alone. A PID recycled to an
# unrelated process only shields one stale file until that process exits.
sweep_stale_secret_env_files() {
  local f base pid
  for f in "${TMPDIR:-/tmp}"/7dtd-container-env.*.*; do
    [[ -f "$f" ]] || continue
    base="${f##*/7dtd-container-env.}"
    pid="${base%%.*}"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f -- "$f" 2>/dev/null || true
    fi
  done
}

# Shared container env + mounts.
make_common() {
  # Secrets travel through an owner-only env file, never the podman command
  # line: `-e K=V` keeps V world-readable via /proc/<pid>/cmdline for the
  # whole run (minutes during an install-only download) and stores it in the
  # container config; --env-file carries the same bytes with mktemp's 0600
  # mode. The same argv-versus-environment rule telnet_session applies
  # (scripts/lib-env.sh). Values arrive pre-validated by init_telnet_env /
  # check_webadmin_password, whose character rules keep them byte-exact
  # through the env-file format: no backslash/quote/$ metacharacters and no
  # leading or trailing whitespace (which podman's parser would trim).
  sweep_stale_secret_env_files
  SECRET_ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/7dtd-container-env.$$.XXXXXX")"
  {
    printf 'TELNET_PASSWORD=%s\n' "$TELNET_PASSWORD"
    printf 'WEBADMIN_PASSWORD=%s\n' "${WEBADMIN_PASSWORD:-}"
  } >"$SECRET_ENV_FILE"
  COMMON=(
    --network host
    --env-file "$SECRET_ENV_FILE"
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
  # steamcmd rewrites data/game in place; overlapped with a running server it
  # swaps files out from under the live game. Pre-warm is a
  # before-first-start step, so refuse instead of racing the depot (start()
  # is the only sanctioned way to replace a running instance).
  if podman ps --format '{{.Names}}' | grep -Fx "$NAME"; then
    echo "FATAL: $NAME is running; stop it first (install-only must not rewrite data/game under a live server)" >&2
    exit 1
  fi
  # Same stale-name guard start() applies; a crashed prior --rm run can leave
  # the name behind and podman refuses to reuse it.
  podman rm -f "$NAME-install" 2>/dev/null || true
  # Force the pre-warm mode: install-only must download/validate and exit,
  # never boot the game server, even if the environment or .env set
  # STEAMCMD_ONLY=0. The update flag is forced too: with STEAMCMD_UPDATE=0
  # and an already-installed depot the container would skip steamcmd and
  # exit 0 having validated nothing, silently defeating the one job this
  # command documents.
  STEAMCMD_ONLY=1
  STEAMCMD_UPDATE=1
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
  # start() opens with the graceful stop, so restarting needs nothing else.
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
