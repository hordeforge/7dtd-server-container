#!/usr/bin/env bash
# Manage the 7dtd-server podman container on the server host (rootless,
# host networking). All runtime state lives in ./data on the host; the
# container itself is disposable.
#
# Usage: run.sh {build|start|run|restart|install-only|stop|logs|status|backup|restore|version}
# (`run` is an alias of `start`; `backup` archives the world saves and
# `restore [archive]` puts one back, defaulting to the newest.)
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
# The lib itself is side-effect free (it only defines functions), so it is
# sourced before the argv guards below can call into it; no .env is loaded
# and no data dir is created until after validation.
source "$ROOT/scripts/lib-env.sh"

usage() {
  cat <<'EOF'
usage: run.sh {build|start|run|restart|install-only|stop|logs|status|backup|restore|version}

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
  restore        replace data/userdata/Saves with a backup archive
                 (no argument = the newest in backups/); archives the
                 current saves first, so a restore is itself reversible
  version        print the VERSION file (the canonical version home)

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

# Exactly one command word, validated before any setup side effect (.env
# load, value validation, data dir creation): a typo or stray flag must
# surface as a usage error even when the environment itself is broken
# (guards live in scripts/lib-env.sh, shared with the other ops scripts).
COMMAND="${1:-status}"
require_command "$COMMAND" \
  'build|start|run|restart|install-only|stop|logs|status|backup|restore|version' usage
# restore alone takes an archive path; every other command takes none, so a
# stray second word is still the usage error it was before.
case "$COMMAND" in
  restore) require_optional_arg usage "${@:2}" ;;
  *)       require_argc 0 usage "${2:-}" ;;
esac

# Is $NAME in the running set? podman's output is captured rather than piped
# into `grep -Fxq`: grep -q exits at the first match, and under
# `set -o pipefail` a podman that then takes SIGPIPE turns the whole pipeline
# into a failure. A running container would read as stopped, and stop() would
# take the forced-stop path with no world save. podman's own error text still
# reaches the operator: only stdout is captured.
container_running() {
  local names n
  names="$(podman ps --format '{{.Names}}')" || return 1
  while IFS= read -r n; do
    if [[ "$n" == "$NAME" ]]; then
      return 0
    fi
  done <<< "$names"
  return 1
}

# Same capture for the stopped-but-present set: a false negative there would
# let a failed `podman stop` that left the container in place read as the
# harmless already-gone case.
container_exists() {
  local names n
  names="$(podman ps -a --format '{{.Names}}')" || return 1
  while IFS= read -r n; do
    if [[ "$n" == "$NAME" ]]; then
      return 0
    fi
  done <<< "$names"
  return 1
}

GAME_DIR="$ROOT/data/game"
USERDATA_DIR="$ROOT/data/userdata"
BACKUP_DIR="$ROOT/backups"
KEEP_BACKUPS=7

# Load the git-ignored .env (precedence as documented in the lib header).
# Values are data, never executed, and an explicit override such as
# `TELNET_PORT=9099 ./scripts/run.sh stop` always takes effect.
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
# Secret env files orphaned by a killed previous run (SIGKILL bypasses every
# trap) would accumulate in $TMPDIR forever: mktemp never reuses a name and
# each file carries both secrets. The owning PID therefore rides in the file
# name, and this sweep (plus make_common, before each new file) reclaims
# entries whose owner is gone; a live concurrent run's file (its PID answers
# kill -0) is left alone. A PID recycled to an unrelated process only shields
# one stale file until that process exits.
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

# Reclaim env files stranded by a SIGKILLed previous run. Every command
# sweeps, not just the ones that start a container: these files carry the
# telnet and webadmin passwords, so a run that only stops or backs up must not
# leave one sitting in $TMPDIR for the days before the next start.
# Run the sweep for every command, including the ones that never mint a file.
# Called here, before any command runs, so the sweep outlives the start-path
# ownership in make_common below.
sweep_stale_secret_env_files

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
  # Sweep again right before minting: a long stop() can outlive the sweep
  # above, and the file minted here must be the newest one in $TMPDIR.
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

# Health probe command, the same string the quadlet unit carries: it sources
# the lib the image ships and calls health_check, so the port it probes is the
# one init_telnet_env owns rather than a second hardcoded number. podman runs
# the command through sh, hence the single-quoted inner script.
HEALTH_CMD="bash -c 'source /usr/local/lib/7dtd-lib-env.sh && health_check'"
# Start period covers the boot the probe cannot judge: a first start
# steamcmd-installs a multi-GB depot and the game only opens the telnet port
# once the world is loaded. Three missed probes afterwards mark the container
# unhealthy in `podman ps` / `systemctl --user status`, which is the signal
# that a server process is alive but no longer serving. podman never restarts
# or kills on a health status, so a red status cannot take the server down.
HEALTH_FLAGS=(
  --health-cmd "$HEALTH_CMD"
  --health-interval 60s
  --health-retries 3
  --health-start-period 30m
)

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
  podman run -d --name "$NAME" --restart unless-stopped --init \
    "${COMMON[@]}" "${HEALTH_FLAGS[@]}" "$IMAGE"
  # Smoke-check the boot: `podman run -d` returns before the entrypoint does
  # anything, so an exec failure or a bad config would otherwise read as the
  # green "started" line. Give the container a few seconds to prove it stays
  # up; if it is gone, surface its own last log lines instead of success.
  local waited=0
  until container_running; do
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
  if container_running; then
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
  if container_running; then
    echo "requesting save + shutdown via telnet ..."
    # Declared before the branches that fill it: the forced-stop path below
    # dumps the reply whether or not the request ran, and set -u would abort
    # on an undeclared variable there.
    local reply=""
    # A failed shutdown request (rejected password, dropped connection) must
    # name its cause here: swallowing it would surface only as the 90s wait
    # timeout below, and the resulting forced stop skips the world save --
    # the exact loss this function exists to prevent. (request_telnet lives
    # in scripts/lib-env.sh, shared with backup()'s saveworld request.)
    if request_telnet reply 'shutdown' 10; then
      :
    elif (( $? == 2 )); then
      echo "WARN: telnet shutdown request failed; forcing stop without a world save" >&2
      printf '%s\n' "${reply:-<no output>}" | tail -n 3 >&2
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
    if container_exists; then
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

archive_saves() {
  # Tar data/userdata/Saves into a fresh owner-only archive and prune the
  # oldest beyond KEEP_BACKUPS. Shared by backup() (the operator's own
  # snapshot) and restore() (the pre-restore snapshot, so a restore is
  # reversible), which is why the live-save telnet request lives in backup().
  mkdir -p "$BACKUP_DIR"
  # The archive carries serveradmin.xml and the .webadmin-password record from
  # Saves/, so it gets the entrypoint's credential-file treatment: owner-only.
  umask 077
  local stamp archive tar_rc=0 n=0
  # UTC, because the prune below reads the stamp as the age sort key. A local
  # stamp repeats across a fall-back transition (two archives, one name, the
  # second overwriting the first) and reorders after a host TZ change, so a
  # newer save can be pruned as the oldest.
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  archive="$BACKUP_DIR/7dtd-saves-$stamp.tar.gz"
  # One stamp per second, so a backup immediately followed by a pre-restore
  # archive would otherwise overwrite the first with the state the operator
  # is about to discard.
  while [[ -e "$archive" ]]; do
    n=$(( n + 1 ))
    archive="$BACKUP_DIR/7dtd-saves-$stamp-$n.tar.gz"
  done
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
  # UTC stamps sort lexicographically, so glob order is age order: prune the
  # oldest beyond KEEP_BACKUPS so a scheduled backup cannot fill the disk.
  local archives=() excess i
  shopt -s nullglob
  archives=("$BACKUP_DIR"/7dtd-saves-*.tar.gz)
  shopt -u nullglob
  excess=$(( ${#archives[@]} - KEEP_BACKUPS ))
  for (( i = 0; i < excess; i++ )); do
    # Pruning is housekeeping, not the backup: a failed removal must not abort
    # the run before the archive just written is reported, nor hide that the
    # directory now keeps more than KEEP_BACKUPS.
    if ! rm -f -- "${archives[$i]}"; then
      echo "WARN: could not remove old backup ${archives[$i]}" >&2
    fi
  done
  echo "archive written: $archive (keeping the newest $KEEP_BACKUPS in $BACKUP_DIR)"
}

backup() {
  # Archive the world saves (data/userdata/Saves) into backups/. The saves
  # are the only state that cannot be regenerated (the game depot re-downloads,
  # configs re-render from the templates), so they are what backup owns.
  if [[ ! -d "$USERDATA_DIR/Saves" ]]; then
    echo "FATAL: nothing to back up ($USERDATA_DIR/Saves is missing; has the server ever started?)" >&2
    exit 1
  fi
  if container_running; then
    # Best-effort live save: a fresh saveworld makes the archive useful even
    # taken mid-session. A failed request must not block the archive (an
    # inconsistent-but-present backup beats none), so every failure here only
    # warns -- same shape as stop()'s fallback, minus the forced stop.
    # (request_telnet lives in scripts/lib-env.sh, shared with stop().)
    echo "requesting world save via telnet ..."
    local reply=""
    if request_telnet reply 'saveworld' 15; then
      # The save completes server-side after the reply; give the region
      # writes a moment to settle before tar reads them.
      sleep 5
    elif (( $? == 2 )); then
      echo "WARN: telnet saveworld failed; archiving without a fresh save" >&2
      printf '%s\n' "${reply:-<no output>}" | tail -n 3 >&2
    else
      echo "WARN: telnet not reachable on $TELNET_PORT; archiving without a fresh save" >&2
    fi
  fi
  archive_saves
}

restore() {
  # Put a backup archive back into data/userdata/Saves. This is the other
  # half of backup(): without it a backup is a hypothesis nobody has tested.
  # Refuses a running server (the game would write over the restored files)
  # and preserves the current saves first, so a restore is reversible.
  local archive="${1:-}"
  if [[ -z "$archive" ]]; then
    local candidates=()
    shopt -s nullglob
    candidates=("$BACKUP_DIR"/7dtd-saves-*.tar.gz)
    shopt -u nullglob
    if (( ${#candidates[@]} == 0 )); then
      echo "FATAL: no backup archive in $BACKUP_DIR to restore" >&2
      exit 1
    fi
    # UTC stamps sort lexicographically, so glob order is age order: the last
    # entry is the newest, matching the prune's key in archive_saves().
    archive="${candidates[${#candidates[@]} - 1]}"
  fi
  if [[ ! -f "$archive" ]]; then
    echo "FATAL: no such backup archive: $archive" >&2
    exit 1
  fi
  # Preflight before touching data/userdata: a truncated or corrupt archive
  # must fail here, not halfway through a half-replaced Saves/. Listing it
  # also rejects an archive that would write outside the tree.
  local listing entry has_saves=0
  if ! listing="$(tar -tzf "$archive" 2>/dev/null)"; then
    echo "FATAL: $archive is not a readable tar.gz (truncated or corrupt); nothing was changed" >&2
    exit 1
  fi
  while IFS= read -r entry; do
    case "$entry" in
      Saves|Saves/*) has_saves=1 ;;
      /*|../*|*/../*|*/..)
        echo "FATAL: $archive holds an entry outside the archive root ('$entry'); refusing to extract" >&2
        exit 1
        ;;
    esac
  done <<<"$listing"
  if (( has_saves == 0 )); then
    echo "FATAL: $archive contains no Saves/ payload; refusing to restore it" >&2
    exit 1
  fi
  # container_running, not a `podman ps | grep -Fxq` pipeline: grep -q exits at
  # the first match, so under pipefail a podman that then takes SIGPIPE fails
  # the whole pipeline and the running-server guard below is skipped.
  if container_running; then
    echo "FATAL: $NAME is running; stop it first (./scripts/run.sh stop) so the game cannot write over the restored saves" >&2
    exit 1
  fi
  if [[ -d "$USERDATA_DIR/Saves" ]]; then
    # Pre-restore snapshot: the state the restore is about to discard must
    # itself be recoverable, and it lands in the same owner-only archives the
    # retention keeps.
    echo "archiving the current saves before overwriting them ..."
    archive_saves
  fi
  # Owner-only extraction (umask 077 applies to the restored files too, so
  # serveradmin.xml and the webadmin record stay ungroup-readable), and
  # --no-same-owner so an archive carrying a foreign uid cannot chown the
  # restored tree.
  umask 077
  rm -rf "$USERDATA_DIR/Saves"
  if ! tar -xzf "$archive" --no-same-owner -C "$USERDATA_DIR"; then
    echo "FATAL: extraction of $archive failed; $USERDATA_DIR/Saves is incomplete" >&2
    exit 1
  fi
  echo "restored $archive into $USERDATA_DIR/Saves (start the server to load it)"
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
  restore)      restore "${2:-}" ;;
  logs)         podman logs -f "$NAME" ;;
  # Anchor the name filter: podman treats it as a regex, and unanchored it
  # would also list the $NAME-install pre-warm container.
  status)       podman ps -a --filter "name=^${NAME}$" ;;
esac
