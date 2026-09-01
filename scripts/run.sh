#!/usr/bin/env bash
# Manage the 7dtd-server podman container on the server host (rootless,
# host networking). All runtime state lives in ./data on the host; the
# container itself is disposable.
#
# Usage: run.sh {build|start|run|restart|install-only|stop|logs|status|backup|version}
# (`run` is an alias of `start`; `backup` archives the world saves.)
# `--help` prints the command list without touching the environment or data/.
# Env overrides: TELNET_PASSWORD, TELNET_PORT, WEBADMIN_PASSWORD,
# STEAMCMD_UPDATE, STEAMCMD_ONLY, SEVENDTD_CONTAINER_NAME, SEVENDTD_IMAGE.
# A git-ignored .env in this directory fills unset variables; variables
# already present in the environment win over it, defaults come last.
# Exit codes: 0 success, 2 usage error (unknown command or --help misuse),
# other nonzero failures as reported by the failing step.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
usage: run.sh {build|start|run|restart|install-only|stop|logs|status|backup|version}

Manage the 7dtd-server podman container; all runtime state lives in ./data
(the container itself is disposable).
  build          build the container image
  start, run     recreate and start the container (graceful stop first);
                 run is an alias of start
  restart        alias of start
  install-only   download/validate the game via steamcmd, then exit;
                 refuses while the server is running
  stop           graceful stop: telnet save + shutdown, then force stop
  logs           follow container logs
  status         show container state (default with no command)
  backup         archive world saves into backups/ (keeps the newest 7)

Env overrides: TELNET_PASSWORD, TELNET_PORT, WEBADMIN_PASSWORD,
STEAMCMD_UPDATE, STEAMCMD_ONLY, SEVENDTD_CONTAINER_NAME, SEVENDTD_IMAGE.
A git-ignored .env in this directory fills unset variables; variables
already present in the environment win over it, defaults come last.
EOF
}

case "${1:-}" in
  # Help answers before any setup side effect (no .env load, no value
  # validation, no data dir creation): asking for help must never fail on
  # an unrelated broken env value.
  -h|--help)
    usage
    exit 0
    ;;
esac

# Exactly one command word: a silently ignored second word would make e.g.
# `run.sh backup --keep 3` read as a supported option while backup runs with
# its defaults. Checked here, before value validation, so a typo surfaces as
# a usage error even when the environment itself is broken.
if (( $# > 1 )); then
  echo "FATAL: unexpected argument '$2' ($0 takes exactly one command)" >&2
  usage >&2
  exit 2
fi

# Validate the command word here too, before any setup side effect (.env
# load, value validation, data dir creation): a typo must surface as a
# usage error even when the environment itself is broken, same rule as
# --help above.
COMMAND="${1:-status}"
case "$COMMAND" in
  build|start|run|restart|install-only|stop|logs|status|backup|version) ;;
  *)
    # 2, not 1: a bad invocation must be distinguishable from a failed
    # operation by scripts consuming this CLI (same code the CI helper uses).
    # Name the offender before the usage dump, like every other script here.
    echo "FATAL: unknown command '$1'" >&2
    usage >&2
    exit 2
    ;;
esac

GAME_DIR="$ROOT/data/game"
USERDATA_DIR="$ROOT/data/userdata"
BACKUP_DIR="$ROOT/backups"
KEEP_BACKUPS=7

# Load the git-ignored .env via scripts/lib-env.sh (precedence as documented
# in the header). Values are data, never executed, and an explicit override
# such as `TELNET_PORT=9099 ./scripts/run.sh stop` always takes effect.
source "$ROOT/scripts/lib-env.sh"
if [[ -f "$ROOT/.env" ]]; then
  load_env_file "$ROOT/.env"
fi

NAME="${SEVENDTD_CONTAINER_NAME:-7dtd-server}"
IMAGE="${SEVENDTD_IMAGE:-localhost/7dtd-server:latest}"

# Release every env file this run owns, keyed on the PID embedded in the
# name rather than on the freshly created path: acquisition spans the mktemp
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

# Telnet values come from the environment or .env, get the shared lab defaults
# if still unset, and are validated before any container starts (the password
# is sent by telnet_session in stop() and rendered into serverconfig.xml
# inside the container; rationale and rules: scripts/lib-env.sh).
init_telnet_env

# Same boundary treatment for the steamcmd switches: defaults applied, values
# pinned to {0,1}. A typo like STEAMCMD_UPDATE=true must fail here instead of
# silently disabling the per-boot depot validation (init_steamcmd_env).
init_steamcmd_env

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
  # Owner-only env file carrying TELNET_PASSWORD/WEBADMIN_PASSWORD into the
  # container (removed by the EXIT trap); local to this call, its only reads.
  local secret_env_file
  secret_env_file="$(mktemp "${TMPDIR:-/tmp}/7dtd-container-env.$$.XXXXXX")"
  {
    printf 'TELNET_PASSWORD=%s\n' "$TELNET_PASSWORD"
    printf 'WEBADMIN_PASSWORD=%s\n' "${WEBADMIN_PASSWORD:-}"
  } >"$secret_env_file"
  COMMON=(
    --network host
    --env-file "$secret_env_file"
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
  # Smoke-check the boot: `podman run -d` returns before the entrypoint does
  # anything, so an exec failure or a bad config would otherwise read as the
  # green "started" line. Give the container a few seconds to prove it stays
  # up; if it is gone, surface its own last log lines instead of success.
  local waited=0
  until podman ps --format '{{.Names}}' | grep -Fxq "$NAME"; do
    if (( waited >= 4 )); then
      echo "FATAL: $NAME is not running right after start; last log lines:" >&2
      podman logs --tail 20 "$NAME" >&2 || true
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "started $NAME (game 26900, telnet $TELNET_PORT, dashboard 8080)"
}

install_only() {
  # steamcmd rewrites data/game in place; overlapped with a running server it
  # swaps files out from under the live game. Pre-warm is a
  # before-first-start step, so refuse instead of racing the depot (start()
  # is the only sanctioned way to replace a running instance).
  if podman ps --format '{{.Names}}' | grep -Fxq "$NAME"; then
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
  if podman ps --format '{{.Names}}' | grep -Fxq "$NAME"; then
    echo "requesting save + shutdown via telnet ..."
    # Declared before the branches that fill it: the forced-stop path below
    # dumps the reply whether or not the probe/session branches ran, and set
    # -u would abort on an undeclared variable there.
    local reply=""
    if telnet_probe "$TELNET_PORT" 3 >/dev/null 2>&1; then
      # A failed shutdown request (rejected password, dropped connection) must
      # name its cause here: swallowing it would surface only as the 90s wait
      # timeout below, and the resulting forced stop skips the world save --
      # the exact loss this function exists to prevent.
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
      # The server accepted the session but did not shut down (rejected
      # password, refused command are the usual causes): its own last output
      # names that cause, so surface the tail instead of leaving the operator
      # to guess why the save path was skipped.
      if [[ -n "$reply" ]]; then
        printf '%s\n' "$reply" | tail -n 3 >&2
      fi
    fi
  fi
  # Idempotent final stop. Failure means either an already-gone container
  # (the normal no-op) or real trouble; a real failure must not read as
  # success, because the world save may never have happened.
  if ! podman stop -t 30 "$NAME" >/dev/null 2>&1; then
    if podman ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$NAME"; then
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

backup() {
  # Archive the world saves (data/userdata/Saves) into backups/. The saves
  # are the only state that cannot be regenerated (the game depot re-downloads,
  # configs re-render from the templates), so they are what backup owns.
  if [[ ! -d "$USERDATA_DIR/Saves" ]]; then
    echo "FATAL: nothing to back up ($USERDATA_DIR/Saves is missing; has the server ever started?)" >&2
    exit 1
  fi
  if podman ps --format '{{.Names}}' | grep -Fxq "$NAME"; then
    # Best-effort live save: a fresh saveworld makes the archive useful even
    # taken mid-session. A failed request must not block the archive (an
    # inconsistent-but-present backup beats none), so every failure here only
    # warns -- same shape as stop()'s fallback, minus the forced stop.
    echo "requesting world save via telnet ..."
    local reply=""
    if telnet_probe "$TELNET_PORT" 3 >/dev/null 2>&1; then
      if reply="$(telnet_session "$TELNET_PORT" "$TELNET_PASSWORD" 'saveworld' 15 2>&1)"; then
        # The save completes server-side after the reply; give the region
        # writes a moment to settle before tar reads them.
        sleep 5
      else
        echo "WARN: telnet saveworld failed; archiving without a fresh save" >&2
        printf '%s\n' "${reply:-<no output>}" | tail -n 3 >&2
      fi
    else
      echo "WARN: telnet not reachable on $TELNET_PORT; archiving without a fresh save" >&2
    fi
  fi
  mkdir -p "$BACKUP_DIR"
  # The archive carries serveradmin.xml and the .webadmin-password record from
  # Saves/, so it gets the entrypoint's credential-file treatment: owner-only.
  umask 077
  local stamp archive tar_rc=0
  stamp="$(date +%Y%m%d-%H%M%S)"
  archive="$BACKUP_DIR/7dtd-saves-$stamp.tar.gz"
  # GNU tar exits 1 for warnings alone (a file changed as it was read, which
  # happens when the game writes during a live backup): keep that archive and
  # say why. Only >= 2 means tar could not produce something usable.
  tar -czf "$archive" -C "$USERDATA_DIR" Saves || tar_rc=$?
  if (( tar_rc >= 2 )); then
    rm -f "$archive"
    echo "FATAL: backup failed (tar exit $tar_rc); removed the partial $archive" >&2
    exit 1
  fi
  if (( tar_rc == 1 )); then
    echo "WARN: files changed while archiving (server running?); the archive may mix save states" >&2
  fi
  # Timestamps sort lexicographically, so glob order is age order: prune the
  # oldest beyond KEEP_BACKUPS so a scheduled backup cannot fill the disk.
  local archives=() excess i
  shopt -s nullglob
  archives=("$BACKUP_DIR"/7dtd-saves-*.tar.gz)
  shopt -u nullglob
  excess=$(( ${#archives[@]} - KEEP_BACKUPS ))
  for (( i = 0; i < excess; i++ )); do
    rm -f -- "${archives[$i]}"
  done
  echo "backup written: $archive (keeping the newest $KEEP_BACKUPS in $BACKUP_DIR)"
}

case "$COMMAND" in
  build)        podman build -t "$IMAGE" "$ROOT" ;;
  # The one canonical version home (REPOSITORY_STANDARDS.md section 8); the
  # release workflow refuses a tag that disagrees with it.
  version)      cat "$ROOT/VERSION" ;;
  # start() opens with the graceful stop, so restarting needs nothing else.
  start|run|restart)
                start ;;
  install-only) install_only ;;
  stop)         stop ;;
  backup)       backup ;;
  logs)         podman logs -f "$NAME" ;;
  # Anchor the name filter: podman treats it as a regex, and unanchored it
  # would also list the $NAME-install pre-warm container.
  status)       podman ps -a --filter "name=^${NAME}$" ;;
esac
