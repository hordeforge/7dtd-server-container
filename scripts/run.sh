#!/usr/bin/env bash
# Manage the 7dtd-server podman container on the server host (rootless,
# host networking). All runtime state lives in ./data on the host; the
# container itself is disposable.
#
# Usage: run.sh {build|start|run|restart|install-only|stop|logs|status|config|backup|restore|verify-backup|version}
# (`run` is an alias of `start`; `backup` archives the world saves,
# `restore [archive]` puts one back, defaulting to the newest, and
# `verify-backup [archive]` checks the archives are still restorable.)
# `--help` prints the command list without touching the environment or data/.
# Env overrides: TELNET_PASSWORD, TELNET_PORT, WEBADMIN_PASSWORD,
# STEAMCMD_UPDATE, STEAMCMD_ONLY, BACKUP_KEEP, SEVENDTD_CONTAINER_NAME,
# SEVENDTD_IMAGE. SOURCE_DATE_EPOCH pins the image mtimes for a reproducible
# `build`. A git-ignored .env in this directory fills unset variables;
# variables already present in the environment win over it, defaults come last.
# Exit codes: 0 success (including -h/--help, which wins over any extra
# word), 2 usage error (unknown command or a stray argument), 1 a failed
# operation or a rejected configuration value.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# The lib itself is side-effect free (it only defines functions), so it is
# sourced before the argv guards below can call into it; no .env is loaded
# and no data dir is created until after validation.
source "$ROOT/scripts/lib-env.sh"

usage() {
  cat <<'EOF'
usage: run.sh {build|start|run|restart|install-only|stop|logs|status|config|backup|restore|verify-backup|version}

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
                 archive, and one that already holds it is a no-op);
                 archives the current saves first, so a
                 restore is itself reversible
  verify-backup  check that the archives in backups/ are still readable
                 and restorable, without restoring one (no argument =
                 every archive, otherwise just the named one), and fail
                 when the newest is older than the daily schedule allows;
                 one 'OK:' line per verified archive on stdout, every
                 refusal on stderr
  version        print the VERSION file (the canonical version home); answers
                 without loading .env or validating any value, like --help

Env overrides: TELNET_PASSWORD, TELNET_PORT, WEBADMIN_PASSWORD,
STEAMCMD_UPDATE, STEAMCMD_ONLY, BACKUP_KEEP, SEVENDTD_CONTAINER_NAME,
SEVENDTD_IMAGE. SOURCE_DATE_EPOCH pins the image mtimes for a reproducible
`build`. A git-ignored .env in this directory fills unset variables;
variables already present in the environment win over it, defaults come last.
An unknown key in .env is refused. deploy.sh reads SEVENDTD_SERVER_HOST,
SEVENDTD_SERVER_USER and SEVENDTD_SERVER_DIR from the environment.

Every command that writes data/, backups/ or the container (start, run,
restart, install-only, stop, backup, restore) takes one exclusive lock on
data/.ops.lock first, so the daily backup timer, a systemd-driven stop and an
operator command cannot interleave. A command that finds the lock held waits
up to 120s and then fails without touching anything.

Exit codes: 0 success (including -h/--help, which wins over any extra word),
2 usage error (unknown command or a stray argument), 1 a failed operation or
a rejected configuration value.
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
  'build|start|run|restart|install-only|stop|logs|status|config|backup|restore|verify-backup|version' usage
# restore and verify-backup alone take an archive path; every other command
# takes none, so a stray second word is still the usage error it was before.
case "$COMMAND" in
  restore|verify-backup) require_optional_arg usage "${@:2}" ;;
  *)       require_argc 0 usage "${2:-}" ;;
esac

# `version` cats one committed file and does nothing else, so it answers in the
# same place --help does: before the .env load, the value rules and the data
# dir. An operator asking a host which build it runs must not be answered with
# a FATAL about a telnet password that has nothing to do with the question,
# and `run.sh version` is how the release tag and the image label are compared.
# The one canonical version home (REPOSITORY_STANDARDS.md section 8); the
# release workflow refuses a tag that disagrees with it.
case "$COMMAND" in
  version) cat "$ROOT/VERSION"; exit 0 ;;
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
# How old the newest archive may be before verify-backup calls the backup
# schedule broken. Two daily runs plus a day of slack: past this, the timer
# is not running, not merely late, and the RPO is whatever the oldest
# surviving archive says.
BACKUP_STALE_SECS=259200
# The archive archive_saves last wrote, left for its callers: restore() names
# it when a later extraction fails, so the operator is handed the path of the
# saves the failed restore replaced instead of having to look for it.
ARCHIVE_PATH=""
# Separator for the counter archive_saves appends when several backups land in
# one second. backup_archives reads the names as an age order, and the counter
# was the part of the name that did not fit that order: a '-' sorts before the
# '.', so '…-000000-01.tar.gz' came out older than the '…-000000.tar.gz' it
# was written after, and one digit short '-10' came out older than '-2'.
# '~' is the last printable ASCII byte, so it sorts after the '.' that opens
# the extension, and the counter is zero-padded: byte order is creation order.
ARCHIVE_COLLIDE_SEP='~'

# The keys `config` reports, and which of them were already in the
# environment before the .env load below. The snapshot has to happen here:
# init_telnet_env / init_steamcmd_env / the :- defaults further down fill the
# unset ones, after which every value reads as "set" and provenance is lost.
# ALLOW_PUBLIC_DEFAULT_TELNET_PASSWORD is reported like every other key it
# governs: it is the one switch that authorizes booting on the committed public
# telnet password, and a report that omitted it could not answer "is this host
# opted in to the public password" without reading the environment by hand.
CONFIG_KEYS="TELNET_PASSWORD WEBADMIN_PASSWORD TELNET_PORT STEAMCMD_UPDATE \
STEAMCMD_ONLY ALLOW_PUBLIC_DEFAULT_TELNET_PASSWORD=ALLOW_PUBLIC_DEFAULT \
BACKUP_KEEP=KEEP_BACKUPS SEVENDTD_CONTAINER_NAME=NAME SEVENDTD_IMAGE=IMAGE"
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

# The retention domain, as named constants rather than literals inside the
# rules. The ceiling is far past any real archive count (a daily timer at that
# value keeps more archives than the host has days of disk), and bounding it is
# what keeps the value inside 64-bit arithmetic, which bash wraps silently.
BACKUP_KEEP_MIN=1
BACKUP_KEEP_MAX=999999999

# Shape of the two podman-facing values, as named patterns rather than
# literals inside the rule below. A container name is what podman itself
# accepts for --name, and the leading-alnum requirement is what keeps a value
# starting with '-' from being read as an option instead of an argument. An
# image reference is registry/name:tag, so '/', ':' and '@' belong to the set
# too. scripts/deploy.sh shape-checks its three SEVENDTD_* values for the same
# reason.
CONTAINER_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
IMAGE_RE='^[A-Za-z0-9][A-Za-z0-9._:/@-]*$'

# Backup retention varies per host (disk size, how far back an operator wants
# to reach), so it is a validated config value with a committed default rather
# than a constant. Same boundary treatment as the steamcmd switches: a
# non-numeric, below-minimum, or out-of-range value is refused instead of
# reaching the arithmetic in archive_saves, where "abc" compares as 0 (prune
# every archive) and a 0 would delete the archive just written. The rule
# itself lives in check_backup_keep, called from check_env_values, so the
# `config` report survives a rejected value the way it does for every other key
# it reports.
#
# The leading zeros go here, once, because bash arithmetic reads a zero-padded
# literal as octal: 08 is not a number to (( )), it is a parse error whose
# return status a following `if` reads as "the test passed", so a padded count
# would slip past the range check and reach the prune with stderr noise as the
# only sign. Stripping here (rather than 10# at each use) also keeps one
# spelling for the config report, the validator, and the prune.
KEEP_BACKUPS="${BACKUP_KEEP:-7}"
while [[ ${#KEEP_BACKUPS} -gt 1 && "$KEEP_BACKUPS" == 0* ]]; do
  KEEP_BACKUPS="${KEEP_BACKUPS#0}"
done

NAME="${SEVENDTD_CONTAINER_NAME:-7dtd-server}"
IMAGE="${SEVENDTD_IMAGE:-localhost/7dtd-server:latest}"
# The same default check_telnet_env reads, filled here so the config report
# can print a value for a key that is usually unset. It is a local report
# variable, not an export: nothing outside run.sh consumes it, and
# check_telnet_env keeps reading the environment variable itself.
# shellcheck disable=SC2034  # read back through show_config's ${!var}, so the reference is indirect
ALLOW_PUBLIC_DEFAULT="${ALLOW_PUBLIC_DEFAULT_TELNET_PASSWORD:-0}"

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
  # The value is compared as the stripped digit string it is, never as an
  # arithmetic operand: leading zeros are already gone, so "0" is the only
  # below-minimum value left, and the width test below is the one that keeps a
  # number too wide for (( )) from ever reaching the prune.
  case "$KEEP_BACKUPS" in
    ''|*[!0-9]*)
      echo "FATAL: BACKUP_KEEP must be numeric (got '$KEEP_BACKUPS')" >&2
      exit 1
      ;;
  esac
  # Bound the digits before any arithmetic. bash reads an integer as 64-bit
  # and wraps a longer one silently, so 18446744073709551617 is 1 there: a
  # 20-digit value would reach the comparison as a small one and pass a
  # ceiling no count could justify. The width test also keeps `(( ))` from
  # aborting the whole run on the overflow error a value past the machine word
  # ("99999999999999999999") raises, which reads as a failed backup rather
  # than a rejected value. Equal-or-fewer digits than the ceiling itself means
  # both sides fit a machine word.
  if (( 10#$KEEP_BACKUPS < BACKUP_KEEP_MIN )); then
    echo "FATAL: BACKUP_KEEP must be at least $BACKUP_KEEP_MIN (got '$KEEP_BACKUPS')" >&2
    exit 1
  fi
  if (( ${#KEEP_BACKUPS} > ${#BACKUP_KEEP_MAX} )); then
    echo "FATAL: BACKUP_KEEP must be at most $BACKUP_KEEP_MAX (got '$KEEP_BACKUPS')" >&2
    exit 1
  fi
}

# NAME and IMAGE reach podman argv, and NAME additionally is the body of the
# anchored `podman ps --filter name=^${NAME}$` regex: podman reads a leading
# '-' as an option, a metacharacter in the name changes what `status` matches
# (a name that starts a container that exists while `status` reports none, or
# vice versa), and stop()/backup() then act on that wrong answer. A bad value
# is refused here, before any command uses it, on the same boundary the other
# keys get.
check_podman_values() {
  if [[ ! "$NAME" =~ $CONTAINER_NAME_RE ]]; then
    echo "FATAL: SEVENDTD_CONTAINER_NAME must match $CONTAINER_NAME_RE (got '$NAME')" >&2
    exit 1
  fi
  if [[ ! "$IMAGE" =~ $IMAGE_RE ]]; then
    echo "FATAL: SEVENDTD_IMAGE must match $IMAGE_RE (got '$IMAGE')" >&2
    exit 1
  fi
}

check_env_values() {
  check_telnet_env
  check_steamcmd_env
  check_backup_keep
  check_podman_values
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
  # Which keys the .env file actually sets, collected in one pass over the
  # file: env_file_keys is the loader's own line walk, so this report cannot
  # credit a line the loader skipped, and one pass answers the same question
  # for every key below instead of re-reading .env (and forking) per key.
  local -A in_env=()
  local ekey
  if [[ -f "$ROOT/.env" ]]; then
    while IFS= read -r ekey; do
      in_env["$ekey"]=1
    done < <(env_file_keys "$ROOT/.env")
  fi
  for entry in $CONFIG_KEYS; do
    # Each entry is the config key, plus the variable holding its effective
    # value when that differs from the key itself (BACKUP_KEEP is validated
    # into KEEP_BACKUPS, and the container name/image into NAME/IMAGE).
    key="${entry%%=*}"
    var="${entry#*=}"
    case "$key" in
      # The two secret keys, named rather than matched as *PASSWORD*: that
      # substring also matches ALLOW_PUBLIC_DEFAULT_TELNET_PASSWORD, which is
      # a {0,1} switch, not a secret. Reporting the opt-in as "(set, redacted)"
      # hid the one value that says whether this host runs on the committed
      # public telnet password, which is exactly what the report exists for.
      TELNET_PASSWORD|WEBADMIN_PASSWORD)
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
      # already read (and key-checked) above when it exists, and the key set
      # was collected from it once at the top of this function. The collected
      # set replays the loader's own line walk, so a line the loader skipped
      # (leading whitespace before the key, say) is not credited to the file.
      # A grep with a looser pattern reports the committed default as coming
      # from .env, which is the one answer this report must never get wrong.
      if [[ -n "${in_env[$key]:-}" ]]; then
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

# data/userdata holds the players' own records: the Saves/ world (names,
# positions, inventories), serveradmin.xml (platform userids, ban list) and the
# game log's join and leave lines with client addresses. data/game is the depot
# beside it, mounted and written by the same container. Podman maps the
# container's root to this host user, so a directory left at the default 0755 is
# readable by every other account on the host. backups/ gets the same treatment
# for the archives that copy that data. An existing tree is tightened in place,
# so upgrading run.sh closes a tree an earlier run opened.
ensure_private_dir() { # dir
  local dir="$1"
  mkdir -p "$dir" || {
    echo "FATAL: cannot create $dir" >&2
    exit 1
  }
  chmod 700 "$dir" || {
    echo "FATAL: cannot keep $dir owner-only (it holds player names, platform ids, world saves and join logs); fix its mode by hand" >&2
    exit 1
  }
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

ensure_private_dir "$GAME_DIR"
ensure_private_dir "$USERDATA_DIR"
mkdir -p "$ROOT/mods" "$ROOT/config"

# One exclusive lock over the commands that mutate host state (data/,
# backups/, the container). These commands are not mutually excluded by
# anything else: the daily backup timer fires on its own schedule, the quadlet
# unit calls `run.sh stop` from systemd, and an operator types `run.sh
# restore` whenever. Two of those at once is a real interleaving, and each
# one's guard is a check-then-act that its own next line invalidates.
#
# The worst pairing is the daily timer and an operator recovery: backup() tars
# data/userdata/Saves while restore() runs `rm -rf Saves` and extracts over it,
# so the archive lands holding a half-deleted, half-extracted tree (tar exits
# 0 or 1, and the prune keeps it), and the operator's recovery path now points
# at a corrupt archive. install-only and start share the same hazard over
# data/game, where steamcmd rewrites the depot in place.
#
# flock(1) on one file descriptor, so the kernel releases it when the process
# exits for any reason, including a signal the traps above do not catch: no
# stale lock file to reclaim, no PID keying, and no way for a killed run to
# strand the next one. Fixed descriptor 9 rather than `exec {fd}>` because the
# ops scripts still run on the bash 3.2 that ships with macOS. The lock lives
# in data/ (git-ignored, created just above) and not in data/game/, so it is
# not visible through a bind mount inside a container: a container booted by
# the quadlet unit can never contend for a lock a host command is holding.
#
# Nested calls are free: start() calls stop(), and restore() takes a
# pre-restore archive, so both re-enter commands that lock. OPS_LOCK_HELD makes
# the second acquisition a no-op, which a second flock on a fresh descriptor
# for the same file would not be (that is this process blocking on itself).
#
# 120s is under every bound that can kill a waiting caller anyway: the backup
# service's TimeoutStartSec=300 and the quadlet's TimeoutStopSec=180. Past it
# the holder is an install-only mid-download or a wedged podman, and failing
# loud beats hanging a command whose supervisor has already given up on it.
LOCK_FILE="$ROOT/data/.ops.lock"
LOCK_WAIT_SECS=120
OPS_LOCK_HELD=0
acquire_ops_lock() {
  if (( OPS_LOCK_HELD )); then
    return 0
  fi
  # No flock(1) (the macOS workstations; util-linux does not ship it there).
  # Say so rather than run unguarded in silence: the server host is Linux and
  # has it, so the guard there is the container_running check alone.
  if ! command -v flock >/dev/null 2>&1; then
    echo "WARN: flock(1) not found; concurrent run.sh commands are not serialized on this host" >&2
    OPS_LOCK_HELD=1
    return 0
  fi
  exec 9>"$LOCK_FILE"
  # Non-blocking probe first so the "waiting" line names only the runs that
  # actually queued behind another one.
  if ! flock -n 9; then
    echo "waiting: another run.sh command is mutating data/ or backups/ (up to ${LOCK_WAIT_SECS}s)" >&2
    if ! flock -w "$LOCK_WAIT_SECS" 9; then
      exec 9>&-
      echo "FATAL: another run.sh command has held $LOCK_FILE for ${LOCK_WAIT_SECS}s; not touching data/ or backups/ (a long install-only download is the usual holder)" >&2
      exit 1
    fi
  fi
  OPS_LOCK_HELD=1
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
    # The game, steamcmd and the entrypoint all run as container root (see
    # the Containerfile), so root here is the design, not a grant the mod set
    # needs. no-new-privileges keeps it that way: nothing in this image uses a
    # setuid binary, so the flag costs the container nothing and denies a
    # hostile mod or a game process that turns on the one escalation route a
    # root process still has. The quadlet unit passes the same flag for the
    # same reason, so both lifecycles of the same container agree.
    --security-opt no-new-privileges
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
# Named because start()'s closing lines report it: an operator told "started"
# has to know how long a boot stays unjudged.
HEALTH_START_PERIOD=30m
HEALTH_FLAGS=(
  --health-cmd "$HEALTH_CMD"
  --health-interval 60s
  --health-retries 3
  --health-start-period "$HEALTH_START_PERIOD"
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
      # Timestamped for the same reason run.sh logs is: the lines below are the
      # only record of how far the boot got, and without a clock on them the
      # gap between them is the question an operator is asking.
      podman logs --tail 20 --timestamps "$NAME" >&2 || true
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  # "Up" is all the smoke check can prove, and a boot spends the next minutes
  # on the depot and the world load before anything answers. Reporting that as
  # a start leaves the operator with no way to tell a healthy boot from one
  # wedged in a load, so the line names what is still outstanding and where to
  # watch it; podman applies no health verdict until HEALTH_START_PERIOD is
  # over, so the probe cannot answer the question yet either.
  echo "started $NAME (container up; game 26900, telnet $TELNET_PORT, dashboard 8080)"
  echo "the game is not serving yet: follow the boot with './scripts/run.sh logs'"
  echo "(no health verdict before $HEALTH_START_PERIOD; 'run.sh status' shows it once the game opens the console)"
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
    # a rootless `podman inspect` on an interval. run_bounded (the shared
    # helper, same one the telnet sessions and deploy.sh use) supplies the
    # time bound, so this resolves gtimeout(1) on the macOS workstations where
    # coreutils installs that name: a bare `timeout` there is a command-not-found
    # that returns 127 at once, and the save the telnet request just asked for
    # would be cut short by the podman stop a line below. The bound expires as
    # 124, which is the force-stop signal; any other failure (e.g. the
    # container already gone) falls through silently to the idempotent stop.
    local wait_rc=0
    run_bounded 90 podman wait "$NAME" >/dev/null 2>&1 || wait_rc=$?
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

# Every archive in $BACKUP_DIR, one path per line, oldest first. The glob on
# its own sorts in the caller's locale, and locales disagree about
# punctuation: under en_US.UTF-8 the plain `…-000000.tar.gz` sorts after the
# `…-000000~01.tar.gz` a second-long collision produced, so the newer archive
# of that second would be the first one pruned and the last one a bare restore
# considers, which is exactly the archive a recovery must reach. LC_ALL=C pins
# the byte order the fixed-width stamp and the zero-padded collision counter
# are built for; every name shares the 7dtd-saves- prefix and differs only in
# its digits and separator, so byte order is age order.
backup_archives() {
  local f
  shopt -s nullglob
  for f in "$BACKUP_DIR"/7dtd-saves-*.tar.gz; do
    printf '%s\n' "$f"
  done | LC_ALL=C sort
  shopt -u nullglob
}

archive_saves() {
  # Tar data/userdata/Saves into a fresh owner-only archive and prune the
  # oldest beyond KEEP_BACKUPS. Shared by backup() (the operator's own
  # snapshot) and restore() (the pre-restore snapshot, so a restore is
  # reversible), which is why the live-save telnet request lives in backup().
  # The one argument names the kind: a pre-restore snapshot carries the
  # PRERESTORE_SUFFIX marker so restore()'s newest-by-default pick can skip it.
  # The directory itself is owner-only, not just the archives in it: the
  # archive names carry the backup schedule, and the dir is the one a stale
  # world-readable mode would keep open.
  ensure_private_dir "$BACKUP_DIR"
  # The archive carries the world saves (player names, positions, inventories)
  # alongside serveradmin.xml and the .webadmin-password record, so it gets
  # the entrypoint's credential-file treatment: owner-only.
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
    # Zero-padded, because the prune and the bare restore below both read these
    # names as an age order and '~10' sorts before '~2'.
    archive="$BACKUP_DIR/$stem${ARCHIVE_COLLIDE_SEP}$(printf '%02d' "$n").tar.gz"
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
  # backup_archives is age order (see its comment), and the collision suffix
  # sorts after the plain name (ARCHIVE_COLLIDE_SEP), so that holds between two
  # archives of the same second too: prune the oldest beyond KEEP_BACKUPS so a
  # scheduled backup cannot fill the disk.
  local archives=() excess i path
  while IFS= read -r path; do
    archives+=("$path")
  done < <(backup_archives)
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

# Is this archive restorable? Readable gzip/tar, a Saves/ payload, no link
# member, and no entry that writes outside the archive root. Shared by
# restore(), which must not touch data/userdata until the archive passes, and
# verify_backup(), so the periodic check a green backup gets is the same check
# the restore path applies. Names the reason on stderr and returns nonzero; the
# caller decides what refusing means.
check_archive_payload() { # archive
  local archive="$1"
  # tar's own diagnostic is left on stderr rather than discarded: a corrupt
  # archive fails here for many reasons (short read, bad gzip trailer, an
  # unreadable file) and "truncated or corrupt" alone leaves the operator to
  # guess which one they are holding. It is not merged into $listing, because
  # the loop below treats every line of that as an archive entry and a warning
  # line would then read as a path outside the archive root.
  local listing verbose entry has_saves=0
  if ! listing="$(tar -tzf "$archive")"; then
    echo "FATAL: $archive is not a readable tar.gz (truncated or corrupt). tar's own diagnostic is on the line above." >&2
    return 1
  fi
  # Link members, refused outright. The name walk below only sees paths, and a
  # link's path is inside Saves/ like anything else: an archive holding
  # `Saves/escape -> /etc` and `Saves/escape/cron.d/x` lists two ordinary
  # Saves/ entries, passes every name test, and then extraction writes through
  # the symlink to a path outside the archive root (tar extracts members in
  # archive order, so the link is in place before the entry behind it). A world
  # save holds regular files and directories and nothing else, so a link member
  # is never legitimate here and there is no shape worth trying to resolve
  # safely. The mode is the first field of `tar -tv` output, ahead of the name,
  # so a member named `l...` cannot be mistaken for one; the herestring keeps
  # the listing out of a pipeline, where a grep exiting at the first match
  # would SIGPIPE tar and, under pipefail, fail the check it was asked for.
  if ! verbose="$(tar -tvzf "$archive" 2>/dev/null)"; then
    echo "FATAL: $archive cannot be listed with its member types; refusing it" >&2
    return 1
  fi
  if LC_ALL=C grep -Eq '^[lh]' <<<"$verbose"; then
    echo "FATAL: $archive holds a symlink or hard link member; refusing it (a link is how an archive writes outside its own root, and a world save has none)" >&2
    return 1
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
        echo "FATAL: $archive holds an entry outside the archive root ('$entry'); refusing it" >&2
        return 1
        ;;
      Saves|Saves/*) has_saves=1 ;;
    esac
  done <<<"$listing"
  if (( has_saves == 0 )); then
    echo "FATAL: $archive contains no Saves/ payload; refusing it" >&2
    return 1
  fi
}

# Human age of a file from its mtime ("2d 3h", "18h", "4m"), for the RPO an
# operator reads off the archives. Whole minutes at the bottom: a backup that
# just ran reads "0m", which is what it is.
format_age() { # seconds
  local secs="$1"
  if (( secs >= 86400 )); then
    printf '%dd %dh\n' $(( secs / 86400 )) $(( secs % 86400 / 3600 ))
  elif (( secs >= 3600 )); then
    printf '%dh\n' $(( secs / 3600 ))
  else
    printf '%dm\n' $(( secs / 60 ))
  fi
}

verify_backup() { # [archive]
  # Prove the archives are still readable without restoring one, and say how
  # old the newest is. A backup that exited 0 can still be unreadable later
  # (a truncated copy off-host, a filesystem that dropped a tail, bit rot),
  # and without this the only evidence a backup works is the exit code of the
  # run that wrote it. Runs restore()'s own preflight, so a pass here is the
  # same verdict the restore path would give.
  local archive="${1:-}" archives=() now age failed=0 newest_age=-1
  now="$(date -u +%s)"
  if [[ -n "$archive" ]]; then
    archives=("$archive")
  else
    shopt -s nullglob
    archives=("$BACKUP_DIR"/7dtd-saves-*.tar.gz)
    shopt -u nullglob
    if (( ${#archives[@]} == 0 )); then
      echo "FATAL: no backup archive in $BACKUP_DIR to verify; the world has no backup at all" >&2
      exit 1
    fi
  fi
  for archive in "${archives[@]}"; do
    if [[ ! -f "$archive" ]]; then
      # Diagnostics on stderr, the verified archives on stdout, so
      # `verify-backup | grep '^OK:'` counts what a recovery can actually use
      # and a redirected run keeps its failures out of the data stream. The
      # reason check_archive_payload prints above goes the same way.
      echo "FAIL: no such backup archive: $archive" >&2
      failed=1
      continue
    fi
    if ! check_archive_payload "$archive"; then
      echo "FAIL: $archive is not restorable (reason above); an incident today would not recover from it" >&2
      failed=1
      continue
    fi
    # mtime, not the stamp in the name: a hand-placed or rsynced archive
    # carries a name its copy date never earned, and the age of the data is
    # what the RPO claim rests on.
    age=$(( now - $(stat -c %Y "$archive") ))
    (( age < 0 )) && age=0
    echo "OK: $archive ($(du -h "$archive" | cut -f1), written $(format_age "$age") ago)"
    if (( newest_age < 0 || age < newest_age )); then
      newest_age=$age
    fi
  done
  (( failed == 0 )) || exit 1
  if (( newest_age > BACKUP_STALE_SECS )); then
    echo "FATAL: the newest archive was written $(format_age "$newest_age") ago, over the $BACKUP_STALE_SECS limit; the backup schedule is not running, so the RPO is unbounded" >&2
    exit 1
  fi
}

restore() {
  # Put a backup archive back into data/userdata/Saves. This is the other
  # half of backup(): without it a backup is a hypothesis nobody has tested.
  # Refuses a running server (the game would write over the restored files)
  # and preserves the current saves first, so a restore is reversible.
  local archive="${1:-}"
  if [[ -z "$archive" ]]; then
    local candidates=() c
    while IFS= read -r c; do
      # A pre-restore snapshot holds the state a restore discarded, never a
      # recovery target for a bare restore: picking it (it is the newest
      # archive the first restore left behind) makes a second `restore` revert
      # the first. The prune still counts these, so they age out with the rest.
      case "${c##*/}" in
        *-"$PRERESTORE_SUFFIX".tar.gz|*-"$PRERESTORE_SUFFIX"$ARCHIVE_COLLIDE_SEP*.tar.gz) continue ;;
      esac
      candidates+=("$c")
    done < <(backup_archives)
    if (( ${#candidates[@]} == 0 )); then
      echo "FATAL: no backup archive in $BACKUP_DIR to restore (a pre-restore snapshot is not a target; name one explicitly to undo a restore)" >&2
      exit 1
    fi
    # backup_archives is age order (see its comment) and the collision suffix
    # sorts after the plain name (ARCHIVE_COLLIDE_SEP), so the last entry is
    # the newest: the same key the prune uses in archive_saves().
    archive="${candidates[${#candidates[@]} - 1]}"
  fi
  if [[ ! -f "$archive" ]]; then
    echo "FATAL: no such backup archive: $archive" >&2
    exit 1
  fi
  # Preflight before touching data/userdata: a truncated or corrupt archive
  # must fail here, not halfway through a half-replaced Saves/.
  if ! check_archive_payload "$archive"; then
    echo "FATAL: refusing to restore $archive; nothing was changed." >&2
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
  # Owner-only extraction (umask 077 applies to the restored files too, so
  # serveradmin.xml and the webadmin record stay ungroup-readable), and
  # --no-same-owner so an archive carrying a foreign uid cannot chown the
  # restored tree. It lands in a staging dir beside Saves/ and is moved into
  # place below, so a failed extraction leaves the current world in place
  # instead of a half-replaced one. The name carries this run's PID and
  # matches the `.*.tmp.*` shape the host staging scripts sweep, so a SIGKILL
  # mid-restore (which skips every trap) is reclaimed by the next restore
  # rather than accumulating in data/userdata.
  umask 077
  local staged="$USERDATA_DIR/.restore.tmp.$$"
  sweep_stale_staging "$USERDATA_DIR"
  rm -rf "$staged"
  mkdir -p "$staged"
  if ! tar -xzf "$archive" --no-same-owner -C "$staged"; then
    rm -rf "$staged"
    echo "FATAL: extraction of $archive failed; $USERDATA_DIR/Saves is unchanged" >&2
    exit 1
  fi
  # A restore is re-run by a retried command, a double-pressed key, or an
  # operator unsure the first one landed. When Saves already holds the
  # archive's content, the target state is in place, so the run ends here: no
  # pre-restore snapshot (each is a retention slot, so a host with
  # BACKUP_KEEP=7 loses its real backups to seven retried recoveries) and no
  # rewrite of a world the server may have played on since. diff(1) compares
  # content, not mtime, the way sync_tree's skip does; where it is missing
  # the restore runs unconditionally, the behavior this check replaced.
  if [[ -d "$USERDATA_DIR/Saves" ]] && command -v diff >/dev/null 2>&1 \
    && diff -r -q "$staged/Saves" "$USERDATA_DIR/Saves" >/dev/null 2>&1; then
    rm -rf "$staged"
    echo "$USERDATA_DIR/Saves already holds $archive; nothing to restore"
    return 0
  fi
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
  rm -rf "$USERDATA_DIR/Saves"
  if ! mv "$staged/Saves" "$USERDATA_DIR/Saves"; then
    # The replacement is already gone by this point, so the failure message
    # carries the way back: the snapshot taken a line ago holds exactly the
    # saves the rm removed, and naming it is the difference between a named
    # recovery and an operator guessing which archive in backups/ it was.
    if [[ -n "$prerestore_archive" ]]; then
      echo "FATAL: moving $staged/Saves into place failed; $USERDATA_DIR/Saves is incomplete -- the saves it replaced are in $prerestore_archive" >&2
    else
      echo "FATAL: moving $staged/Saves into place failed; $USERDATA_DIR/Saves is incomplete" >&2
    fi
    exit 1
  fi
  rm -rf "$staged"
  echo "restored $archive into $USERDATA_DIR/Saves (start the server to load it)"
}

# podman stamps image layers and config with the wall-clock build time unless
# --timestamp overrides it, so two builds of one tree never share a digest.
# SOURCE_DATE_EPOCH is the reproducible-builds.org stamp: a caller that
# exports it (a release cut, a rebuild of a reported digest) gets an image
# whose mtimes all carry that second, so a rebuild can be diffed against the
# original instead of trusted. Unset, the build keeps its current behavior.
#
# The value is seconds, and podman reads --timestamp as seconds, so a caller
# who reaches for the millisecond stamp a JS or Go program hands out
# (Date.now(), time.Now().UnixMilli()) would otherwise pass a digits-only
# check and pin every layer to the year 55000-something: a build that claims
# to be reproducible and reproduces nothing. The bound below refuses any
# number too large to be a seconds stamp. 99999999999 is 5138-11-16, so
# nothing a real caller means by "the moment this was cut" is refused.
MAX_SOURCE_DATE_EPOCH=99999999999
build_image() {
  if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
    podman build -t "$IMAGE" "$ROOT"
    return
  fi
  # 10# so a zero-padded value is read as decimal rather than as an octal
  # literal (00001000 is 512 to a bare (( )) and would pin the build to
  # 1970). The 11-digit cap is what keeps the comparison below in int64
  # range: arithmetic on a longer number wraps, and 2**64 wraps to 0.
  if [[ ! "$SOURCE_DATE_EPOCH" =~ ^[0-9]{1,11}$ ]] ||
     (( 10#$SOURCE_DATE_EPOCH > MAX_SOURCE_DATE_EPOCH )); then
    echo "FATAL: SOURCE_DATE_EPOCH must be whole seconds since the epoch (0 to $MAX_SOURCE_DATE_EPOCH), got '$SOURCE_DATE_EPOCH'; a millisecond or microsecond stamp does not belong here" >&2
    exit 1
  fi
  podman build --timestamp "$SOURCE_DATE_EPOCH" -t "$IMAGE" "$ROOT"
}

# What podman itself records as the container's state and health verdict, as the
# two words show_status reports ("<state> <health>", the second "(none)" when
# the container carries no health check). Returns nonzero when the verdict
# cannot be read at all: an absent container, or a podman that failed. The
# caller treats that as unknown rather than as a failure, because "no verdict"
# and "unhealthy" are different answers and a report that collapsed them would
# send an operator after a container that is merely gone.
container_health() {
  local out
  out="$(podman inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}(none){{end}}' "$NAME" 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

show_status() {
  # The container line, the verdict podman recorded, and, when the server is
  # not serving, the tail of its own log. `podman ps` on its own answers "is
  # the container there", which is the right question when the answer is yes
  # and the wrong one during an incident: the operator had to leave this output
  # to learn why a server that is up is no longer serving. Everything below is
  # read-only, and a podman that cannot answer leaves the container line plus a
  # warning rather than failing the report, because this is the command an
  # operator runs when things are already wrong.
  # Anchor the name filter: podman treats it as a regex, and unanchored it
  # would also list the $NAME-install pre-warm container.
  podman ps -a --filter "name=^${NAME}$"
  local verdict state health
  if ! verdict="$(container_health)"; then
    echo "health: unknown (podman has no verdict for $NAME; it may not exist)" >&2
    return 0
  fi
  state="${verdict%% *}"
  health="${verdict#* }"
  # podman keeps the output of every health probe it ran, and health_check
  # names the failure in it, so this is the shortest path from "unhealthy" to
  # the dependency that stopped answering, in the same command that reported
  # the verdict.
  if [[ "$health" == "unhealthy" ]]; then
    local detail
    detail="$(podman inspect --format '{{range .State.Health.Log}}{{.Output}}{{end}}' "$NAME" 2>/dev/null)" || detail=""
    if [[ -n "$detail" ]]; then
      printf 'health log: %s\n' "$detail"
    fi
  fi
  if [[ "$state" == "running" && ( "$health" == "healthy" || "$health" == "starting" ) ]]; then
    return 0
  fi
  # The two states a tail can say something about. A running-but-unhealthy
  # container and a stopped one are both "the operator needs the last thing it
  # said"; a healthy or still-starting one needs nothing more here.
  if [[ "$state" == "running" ]]; then
    echo "last log lines of $NAME (running but $health; the game log is data/userdata/Logs/):" >&2
  else
    echo "last log lines of $NAME (state: $state):" >&2
  fi
  # Timestamped for the same reason start()'s smoke-check tail is: these lines
  # are the only record of how far the last boot got, and unstamped they cannot
  # be placed against a `run.sh logs` transcript.
  podman logs --tail 20 --timestamps "$NAME" >&2 || true
}

case "$COMMAND" in
  build)        build_image ;;
  # `version` is answered above, beside --help and before any setup side
  # effect, so it never reaches this dispatcher.
  # Everything below mutates data/, backups/ or the container, so every one of
  # them serializes on the ops lock. The read-only commands (logs, status,
  # config, verify-backup) and the image build do not: they change nothing
  # another run could observe mid-flight. `config` has already exited above.
  start|run|restart|install-only|stop|backup|restore)
                acquire_ops_lock
                case "$COMMAND" in
                  # start() opens with the graceful stop, so restarting needs
                  # nothing else.
                  start|run|restart) start ;;
                  install-only)      install_only ;;
                  stop)              stop ;;
                  backup)            backup ;;
                  restore)           restore "${2:-}" ;;
                esac
                ;;
  # verify-backup only reads backups/: it restores nothing and writes no
  # archive of its own, so it never contends for the lock.
  verify-backup) verify_backup "${2:-}" ;;
  # --timestamps: the game's own lines carry no clock, and neither do the
  # entrypoint's before they were stamped, so without this the stream an
  # operator watches a boot in cannot be ordered or correlated with a later
  # --tail dump. Cheap (one prefix per line), and the only way to tell how
  # long a boot phase took.
  logs)         podman logs -f --timestamps "$NAME" ;;
  # Anchor the name filter: podman treats it as a regex, and unanchored it
  # would also list the $NAME-install pre-warm container.
  status)       show_status ;;
esac
