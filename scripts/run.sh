#!/usr/bin/env bash
# Manage the 7dtd-server podman container on the server host (rootless,
# host networking). All runtime state lives in ./data on the host; the
# container itself is disposable.
#
# Usage: run.sh {build|start|run|restart|install-only|stop|logs|status|config|backup|restore|version}
# (`run` is an alias of `start`; `backup` archives the world saves and
# `restore [archive]` puts one back, defaulting to the newest.)
# `--help` prints the command list without touching the environment or data/.
# Env overrides: TELNET_PASSWORD, TELNET_PORT, WEBADMIN_PASSWORD,
# STEAMCMD_UPDATE, STEAMCMD_ONLY, BACKUP_KEEP, SEVENDTD_CONTAINER_NAME,
# SEVENDTD_IMAGE. SOURCE_DATE_EPOCH pins the image mtimes for a reproducible
# `build`. A git-ignored .env in this directory fills unset variables;
# variables already present in the environment win over it, defaults come last.
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
usage: run.sh {build|start|run|restart|install-only|stop|logs|status|config|backup|restore|version}

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
  config         print the effective configuration and where each value came
                 from, with the secret values redacted
  backup         archive world saves into backups/ (keeps the newest
                 BACKUP_KEEP archives, default 7)
  restore        replace data/userdata/Saves with a backup archive
                 (no argument = the newest backup in backups/; the
                 -prerestore snapshots it skips are never picked that
                 way, so a repeated bare restore re-applies the same
                 archive); archives the current saves first, so a
                 restore is itself reversible
  version        print the VERSION file (the canonical version home)

Env overrides: TELNET_PASSWORD, TELNET_PORT, WEBADMIN_PASSWORD,
STEAMCMD_UPDATE, STEAMCMD_ONLY, BACKUP_KEEP, SEVENDTD_CONTAINER_NAME,
SEVENDTD_IMAGE. SOURCE_DATE_EPOCH pins the image mtimes for a reproducible
`build`. A git-ignored .env in this directory fills unset variables;
variables already present in the environment win over it, defaults come last.
An unknown key in .env is refused. deploy.sh reads SEVENDTD_SERVER_HOST,
SEVENDTD_SERVER_USER and SEVENDTD_SERVER_DIR from the environment.

Exit codes: 0 success, 2 usage error (unknown command or a stray argument),
1 a failed operation or a rejected configuration value.
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
  'build|start|run|restart|install-only|stop|logs|status|config|backup|restore|version' usage
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
#
# A failed probe is not the same answer as an empty set, and the callers act on
# the difference: stop() skips the telnet save and forces a stop, backup()
# archives without a fresh saveworld. So the failure is named on stderr rather
# than answered as a plain "not running"; podman's own diagnostic follows.
container_running() {
  local names n
  if ! names="$(podman ps --format '{{.Names}}')"; then
    echo "WARN: 'podman ps' failed; $NAME treated as not running (stop skips the world save, backup skips saveworld). podman's own error is on the line above." >&2
    return 1
  fi
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
  if ! names="$(podman ps -a --format '{{.Names}}')"; then
    echo "WARN: 'podman ps -a' failed; $NAME treated as absent, so a failed 'podman stop' cannot be told apart from the already-gone case. podman's own error is on the line above." >&2
    return 1
  fi
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
# Name marker for the snapshot restore() takes of the saves it is about to
# replace. It keeps that snapshot out of the newest-by-default restore target:
# a bare `restore` run twice would otherwise pick its own pre-restore snapshot
# the second time and silently undo the first, which is the one result a
# repeated recovery must never produce. Undoing a restore stays possible by
# naming the archive explicitly.
PRERESTORE_SUFFIX=prerestore
# How many suffixes archive_saves tries while claiming a free archive name.
# A collision costs one name per second, so this is many orders of magnitude
# past a real race; anything that still cannot be claimed is a create failure
# no further suffix will fix, and the retry must end rather than spin.
ARCHIVE_CLAIM_TRIES=100
# The archive archive_saves last wrote, left for its callers: restore() names
# it when a later extraction fails, so the operator is handed the path of the
# saves the failed restore replaced instead of having to look for it.
ARCHIVE_PATH=""

# The keys `config` reports, and which of them were already in the
# environment before the .env load below. The snapshot has to happen here:
# init_telnet_env / init_steamcmd_env / the :- defaults further down fill the
# unset ones, after which every value reads as "set" and provenance is lost.
CONFIG_KEYS="TELNET_PASSWORD WEBADMIN_PASSWORD TELNET_PORT STEAMCMD_UPDATE \
STEAMCMD_ONLY BACKUP_KEEP=KEEP_BACKUPS SEVENDTD_CONTAINER_NAME=NAME \
SEVENDTD_IMAGE=IMAGE"
declare -A CONFIG_SOURCE
for config_key in $CONFIG_KEYS; do
  config_key="${config_key%%=*}"
  [[ -n "${!config_key+x}" ]] && CONFIG_SOURCE["$config_key"]='environment'
done

# Load the git-ignored .env (precedence as documented in the lib header).
# Values are data, never executed, and an explicit override such as
# `TELNET_PORT=9099 ./scripts/run.sh stop` always takes effect. The key check
# runs first: an unknown key is refused before any of its file's values are
# applied, so a typo'd line cannot half-configure the run.
if [[ -f "$ROOT/.env" ]]; then
  check_env_file_keys "$ROOT/.env"
  load_env_file "$ROOT/.env"
fi

# Backup retention varies per host (disk size, how far back an operator wants
# to reach), so it is a validated config value with a committed default rather
# than a constant. Same boundary treatment as the steamcmd switches: a
# non-numeric or below-minimum value is refused instead of reaching the
# arithmetic in archive_saves, where "abc" compares as 0 (prune every archive)
# and a 0 would delete the archive just written. The rule itself lives in
# check_backup_keep, called from check_env_values, so the `config` report
# survives a rejected value the way it does for every other key it reports.
KEEP_BACKUPS="${BACKUP_KEEP:-7}"

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
# leave one sitting in $TMPDIR for the days before the next start. The
# definition sits above this call because bash resolves a function at call
# time, so a call placed before its definition dies with
# `command not found`.
sweep_stale_secret_env_files

# Telnet values come from the environment or .env and get the shared lab
# defaults if still unset (the password is sent by telnet_session in stop() and
# rendered into serverconfig.xml inside the container; rationale and rules:
# scripts/lib-env.sh). The defaults are applied in every case, including the
# config report, so it shows what the next start would actually run.
apply_telnet_defaults
apply_steamcmd_defaults

# The value rules, before any command acts on them: a typo like
# STEAMCMD_UPDATE=true must fail here instead of silently disabling the per-boot
# depot validation, and an unsafe or missing password must fail on the host,
# before a container starts.
check_backup_keep() {
  case "$KEEP_BACKUPS" in
    ''|*[!0-9]*)
      echo "FATAL: BACKUP_KEEP must be numeric (got '$KEEP_BACKUPS')" >&2
      exit 1
      ;;
  esac
  if (( KEEP_BACKUPS < 1 )); then
    echo "FATAL: BACKUP_KEEP must be at least 1 (got '$KEEP_BACKUPS')" >&2
    exit 1
  fi
}

check_env_values() {
  check_telnet_env
  check_steamcmd_env
  check_backup_keep
  # Optional dashboard webuser password: when provided it is validated here so
  # a bad value fails on the host instead of mid-boot in the container. When
  # unset, the entrypoint mints a random one at seed time (see
  # seed_admin_file); the empty pass-through below keeps that behavior.
  if [[ -n "${WEBADMIN_PASSWORD:-}" ]]; then
    check_webadmin_password
  fi
}

show_config() { # verdict
  # The effective configuration of this run, with the source of each value
  # (environment, .env, or the committed default) and no secret value. This is
  # how an operator answers "which telnet port is this host actually using,
  # and where did it come from" without reading three files, and how a
  # misconfiguration gets a name instead of a guess.
  local entry key var value source
  for entry in $CONFIG_KEYS; do
    # Each entry is the config key, plus the variable holding its effective
    # value when that differs from the key itself (BACKUP_KEEP is validated
    # into KEEP_BACKUPS, and the container name/image into NAME/IMAGE).
    key="${entry%%=*}"
    var="${entry#*=}"
    case "$key" in
      *PASSWORD*)
        if [[ -z "${!key+x}" ]]; then
          # An unset WEBADMIN_PASSWORD is not a missing value: the entrypoint
          # mints one at first seed. Say which, or the operator reads a
          # required-looking key as broken.
          if [[ "$key" == WEBADMIN_PASSWORD ]]; then
            value='(unset: minted at first seed)'
          else
            value='(unset)'
          fi
        else
          value='(set, redacted)'
        fi
        ;;
      *) value="${!var}" ;;
    esac
    source="${CONFIG_SOURCE[$key]:-}"
    if [[ -z "$source" ]]; then
      # Not in the environment: the .env filled it, or a default did. The
      # committed defaults are exactly the values a .env line would carry for
      # these keys, so a key absent from the file is the default. The file was
      # already read (and key-checked) above when it exists.
      if [[ -f "$ROOT/.env" ]] && grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$ROOT/.env"; then
        source='.env'
      else
        source='default'
      fi
    fi
    printf '%-28s %-32s (%s)\n' "$key" "$value" "$source"
  done
  printf '\n%s\n' "$1"
  echo "Secret values are never printed: read a minted WEBADMIN_PASSWORD from"
  echo "data/userdata/Saves/.webadmin-password on the server host."
}

if [[ "$COMMAND" == config ]]; then
  # A diagnostic has to survive the misconfiguration it diagnoses, so the value
  # rules run in a subshell and their verdict becomes a line of the report
  # instead of the end of it. Every other command still refuses to run on a
  # rejected value.
  config_verdict='values rejected: none'
  if ! verdict="$(check_env_values 2>&1)"; then
    config_verdict="values rejected: ${verdict}"
  fi
  show_config "$config_verdict"
  exit 0
fi

check_env_values

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
  # The one argument names the kind: a pre-restore snapshot carries the
  # PRERESTORE_SUFFIX marker so restore()'s newest-by-default pick can skip it.
  mkdir -p "$BACKUP_DIR"
  # The archive carries serveradmin.xml and the .webadmin-password record from
  # Saves/, so it gets the entrypoint's credential-file treatment: owner-only.
  umask 077
  local stamp stem archive tar_rc=0 n=0
  # UTC, because the prune below reads the stamp as the age sort key. A local
  # stamp repeats across a fall-back transition (two archives, one name, the
  # second overwriting the first) and reorders after a host TZ change, so a
  # newer save can be pruned as the oldest.
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  stem="7dtd-saves-$stamp"
  if [[ "${1:-}" == "prerestore" ]]; then
    stem="$stem-$PRERESTORE_SUFFIX"
  fi
  archive="$BACKUP_DIR/$stem.tar.gz"
  # One stamp per second, so a backup immediately followed by a pre-restore
  # archive would otherwise overwrite the first with the state the operator
  # is about to discard. The name is claimed with an exclusive create, not
  # tested for: `[[ -e ]]` then `tar -czf` is a check-then-act, and two runs
  # inside one second (the daily timer and an operator backup, or a backup and
  # restore's pre-restore archive) both passed the test and then gzipped into
  # the same path, interleaving two gzip streams into one corrupt archive that
  # each run then pruned as if it were its own. noclobber opens with O_EXCL, so
  # exactly one run wins a name and the loser moves on to the next. tar
  # truncates the reserved inode; the umask 077 above already gave it 0600.
  #
  # Bounded: a name that cannot be claimed at all (BACKUP_DIR unwritable, disk
  # full, a filesystem that refuses the create) fails the same way for every
  # suffix, so an open-ended loop spins forever appending names, a hang
  # standing in for the failure the claim exists to report. ARCHIVE_CLAIM_TRIES
  # suffixes is far past any real collision (a name per second) and turns the
  # one cause the retry cannot fix into a named failure.
  local claim_err=""
  while :; do
    if claim_err="$( set -o noclobber; : > "$archive" ) 2>&1"; then
      break
    fi
    if (( n >= ARCHIVE_CLAIM_TRIES )); then
      echo "FATAL: cannot create a backup archive in $BACKUP_DIR after $n name(s); nothing was archived: ${claim_err:-<no error text>}" >&2
      exit 1
    fi
    n=$(( n + 1 ))
    archive="$BACKUP_DIR/$stem-$n.tar.gz"
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
  ARCHIVE_PATH="$archive"
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
    local candidates=() c
    shopt -s nullglob
    for c in "$BACKUP_DIR"/7dtd-saves-*.tar.gz; do
      # A pre-restore snapshot holds the state a restore discarded, never a
      # recovery target for a bare restore: picking it (it is the newest
      # archive the first restore left behind) makes a second `restore` revert
      # the first. The prune still counts these, so they age out with the rest.
      case "${c##*/}" in
        *-"$PRERESTORE_SUFFIX".tar.gz|*-"$PRERESTORE_SUFFIX"-*.tar.gz) continue ;;
      esac
      candidates+=("$c")
    done
    shopt -u nullglob
    if (( ${#candidates[@]} == 0 )); then
      echo "FATAL: no backup archive in $BACKUP_DIR to restore (a pre-restore snapshot is not a target; name one explicitly to undo a restore)" >&2
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
  # tar's own diagnostic is left on stderr rather than discarded: a corrupt
  # archive fails here for many reasons (short read, bad gzip trailer, an
  # unreadable file) and "truncated or corrupt" alone leaves the operator to
  # guess which one they are holding. It is not merged into $listing, because
  # the loop below treats every line of that as an archive entry and a warning
  # line would then read as a path outside the archive root.
  if ! listing="$(tar -tzf "$archive")"; then
    echo "FATAL: $archive is not a readable tar.gz (truncated or corrupt); nothing was changed. tar's own diagnostic is on the line above." >&2
    exit 1
  fi
  while IFS= read -r entry; do
    # Escape first, payload second. A case takes the first pattern that
    # matches, and every escaping path under the payload root also matches
    # Saves/*: with the order reversed, `Saves/../../escape` and `Saves/..`
    # were counted as payload and never reached the rejection, so an archive
    # whose only Saves/ entries climb out of the tree was accepted and
    # extracted.
    case "$entry" in
      /*|../*|*/../*|*/..)
        echo "FATAL: $archive holds an entry outside the archive root ('$entry'); refusing to extract" >&2
        exit 1
        ;;
      Saves|Saves/*) has_saves=1 ;;
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
  local prerestore_archive=""
  if [[ -d "$USERDATA_DIR/Saves" ]]; then
    # Pre-restore snapshot: the state the restore is about to discard must
    # itself be recoverable, and it lands in the same owner-only archives the
    # retention keeps. It is marked so the bare restore above never selects it,
    # which is what makes a repeated bare restore re-apply the same archive
    # instead of undoing itself.
    echo "archiving the current saves before overwriting them ..."
    archive_saves prerestore
    prerestore_archive="$ARCHIVE_PATH"
  fi
  # Owner-only extraction (umask 077 applies to the restored files too, so
  # serveradmin.xml and the webadmin record stay ungroup-readable), and
  # --no-same-owner so an archive carrying a foreign uid cannot chown the
  # restored tree.
  umask 077
  rm -rf "$USERDATA_DIR/Saves"
  if ! tar -xzf "$archive" --no-same-owner -C "$USERDATA_DIR"; then
    # The replacement is already gone by this point, so the failure message
    # carries the way back: the snapshot taken a line ago holds exactly the
    # saves the rm removed, and naming it is the difference between a named
    # recovery and an operator guessing which archive in backups/ it was.
    if [[ -n "$prerestore_archive" ]]; then
      echo "FATAL: extraction of $archive failed; $USERDATA_DIR/Saves is incomplete -- the saves it replaced are in $prerestore_archive" >&2
    else
      echo "FATAL: extraction of $archive failed; $USERDATA_DIR/Saves is incomplete" >&2
    fi
    exit 1
  fi
  echo "restored $archive into $USERDATA_DIR/Saves (start the server to load it)"
}

# podman stamps image layers and config with the wall-clock build time unless
# --timestamp overrides it, so two builds of one tree never share a digest.
# SOURCE_DATE_EPOCH is the reproducible-builds.org stamp: a caller that
# exports it (a release cut, a rebuild of a reported digest) gets an image
# whose mtimes all carry that second, so a rebuild can be diffed against the
# original instead of trusted. Unset, the build keeps its current behavior.
build_image() {
  if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
    podman build -t "$IMAGE" "$ROOT"
    return
  fi
  if [[ ! "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]]; then
    echo "FATAL: SOURCE_DATE_EPOCH must be whole seconds since the epoch, got '$SOURCE_DATE_EPOCH'" >&2
    exit 1
  fi
  podman build --timestamp "$SOURCE_DATE_EPOCH" -t "$IMAGE" "$ROOT"
}

case "$COMMAND" in
  build)        build_image ;;
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
