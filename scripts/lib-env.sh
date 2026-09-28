# shellcheck shell=bash
# Shared .env loader, telnet env validation, the directory listing helper,
# and the telnet session helper for the ops scripts (run.sh, perf.sh,
# deploy.sh, stage_mods.sh, update_mods.sh) and, via the copy baked into the
# image, for entrypoint.sh.
#
# Semantics: variables already present in the environment win over the file;
# KEY=value lines only; values are taken literally (no variable expansion, no
# command substitution, no word splitting); one matching pair of surrounding
# quotes is stripped. The file is data, never code: nothing in it is eval'd.
# Malformed lines are skipped, but each skip warns on stderr: a typo'd key
# (e.g. TELNET_PASSWD=) must not silently fall back to the default value with
# no trace of why the operator's line had no effect.
#
# Argv guards (require_argc / require_optional_arg / require_command): one
# owner of the usage-error contract shared by the ops scripts. All exit 2 (a
# usage error must be distinguishable from a failed operation) and print the
# offender, then the caller's usage, on stderr. All run before any setup side
# effect, so a typo surfaces as a usage error even when the environment itself
# is broken.
require_argc() { # max_args extra_argv usage_fn
  local max="$1" usage_fn="$2" extra="$3"
  if [[ -n "$extra" ]]; then
    echo "FATAL: unexpected argument '$extra' ($0 takes at most $max argument(s))" >&2
    "$usage_fn" >&2
    exit 2
  fi
}

# For the one command that takes an optional operand (run.sh restore
# [archive]): usage_fn first, then the script's own argv. Rejects a second
# operand, so a mistyped path plus a flag is still a usage error rather than a
# silently ignored word.
require_optional_arg() { # usage_fn "$@"
  local usage_fn="$1"
  shift
  if (( $# > 1 )); then
    echo "FATAL: unexpected argument '$2' ($0 takes at most 1 argument(s))" >&2
    "$usage_fn" >&2
    exit 2
  fi
}

# Validate the command word: a typo must surface as a usage error naming the
# offender, before any setup side effect, even when the environment itself is
# broken. 2, not 1: a bad invocation must be distinguishable from a failed
# operation by scripts consuming this CLI. The valid set is pipe-separated;
# word-by-word comparison (unquoted case patterns do not expand '|' as
# alternation).
require_command() { # command pipe_separated_valid usage_fn
  local cmd="$1" valid="$2" usage_fn="$3" word
  local IFS='|'
  for word in $valid; do
    if [[ "$cmd" == "$word" ]]; then
      return 0
    fi
  done
  echo "FATAL: unknown command '$cmd'" >&2
  "$usage_fn" >&2
  exit 2
}

# Space-separated names of a directory's entries, "(empty)" when it has
# none. `ls` on an empty directory prints nothing to stdout and writes
# "cannot access ..." to stderr, so a caller reporting a staged or enabled
# mod set would print a blank line and read as an empty-but-successful run.
list_dir() { # dir
  local dir="$1" entries=() restore_nullglob=0
  shopt -q nullglob || restore_nullglob=1
  shopt -s nullglob
  entries=("$dir"/*)
  if (( ${#entries[@]} == 0 )); then
    printf '%s\n' '(empty)'
  else
    printf '%s\n' "${entries[@]##*/}"
  fi
  if (( restore_nullglob == 1 )); then
    shopt -u nullglob
  fi
}

load_env_file() {
  local line key value q
  # An unreadable file would otherwise abort the caller with a bare redirect
  # error naming neither the operation nor which script asked for the file.
  if [[ ! -r "$1" ]]; then
    echo "FATAL: cannot read env file '$1'" >&2
    exit 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      ''|'#'*) continue ;;
      'export '*) line="${line#'export '}" ;;
    esac
    case "$line" in
      *=*) ;;
      *)
        # No '=' means no value ever reached this line, naming it verbatim
        # cannot leak one.
        echo "WARN: $1: ignoring line without '=': $line" >&2
        continue
        ;;
    esac
    key="${line%%=*}"
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      # Name the key side only ('key' stops at the first '='): a malformed
      # line can still carry a secret value that must stay out of the log.
      echo "WARN: $1: ignoring line with invalid key '$key'" >&2
      continue
    fi
    if [[ -n "${!key+x}" ]]; then
      continue
    fi
    value="${line#*=}"
    q="${value:0:1}"
    # Last char via arithmetic offset, not a negative one (${var: -1} needs
    # bash 4.2; this form works back to bash 3.x).
    if [[ ${#value} -ge 2 && ( "$q" == '"' || "$q" == "'" ) && "${value:$(( ${#value} - 1 )):1}" == "$q" ]]; then
      value="${value:1:$(( ${#value} - 2 ))}"
    fi
    export "$key=$value"
  done < "$1"
}

# Install src at dst as a full copy, skipping the write when the two trees
# are already identical. Callers pass absolute paths.
#
# Every deploy and every container boot copies whole mod trees (EfficientServer,
# the APM bridge, BotMod) whose combined size is in the tens of megabytes, and
# a redeploy that changed no mod, or a --restart unless-stopped recovery that
# re-syncs the same bind-mounted /mods, is the common case. Deleting and
# rewriting those bytes every time is pure disk write amplification on the boot
# path; the comparison below reads both trees and writes nothing, so an
# unchanged boot costs a read pass and no writes at all.
#
# diff -r -q compares content, not just size and mtime, and reports a
# destination that gained, lost, or changed an entry, so a skipped copy is
# always a destination already equal to the source. diff(1) comes from
# diffutils, which the container image and the Linux and macOS workstations
# all ship; where it is missing the copy runs unconditionally, the behavior
# this helper replaced.
#
# Atomicity is the caller's contract and lives here: the copy lands in a
# hidden sibling (missed by the staging scripts' `.*.tmp.*` sweep and by the
# entrypoint's copy loop) and is renamed into place, so a cp killed midway
# (disk full, Ctrl-C, container killed) never leaves a half-written mod dir.
# Returns nonzero when the copy fails, with no staging entry left behind; the
# caller owns the message, since each one names a different operation.
sync_tree() { # src dst
  local src="$1" dst="$2" staging
  if [[ -e "$dst" ]] && command -v diff >/dev/null 2>&1 && diff -r -q "$src" "$dst" >/dev/null 2>&1; then
    return 0
  fi
  staging="${dst%/*}/.${dst##*/}.tmp.$$"
  mkdir -p "${dst%/*}"
  rm -rf "$staging"
  if ! cp -a "$src" "$staging"; then
    rm -rf "$staging"
    return 1
  fi
  rm -rf "$dst"
  mv "$staging" "$dst"
}

# Shared character policy for values that travel through double-quoted shell
# strings in the ops scripts (telnet_session) and are rendered by sed into XML
# attribute values (serverconfig.xml, serveradmin.xml; < is illegal there):
# reject unsafe values up front instead of escaping, because the game reads
# the rendered files and a mangled value fails far from the cause as a
# boot-time config parse error, a silent forced stop (no world save), or a
# container that dies on startup. The entrypoint sources this same file from
# the image (/usr/local/lib/7dtd-lib-env.sh), so host scripts and container
# enforce one shared copy of these rules.
#
# The accepted domain is printable ASCII (0x20..0x7E), and every character
# test runs with LC_ALL=C so that domain does not move with the ambient
# locale. `[[:print:]]` and `[[:space:]]` are locale-sensitive, and the two
# sides of this copy deliberately run under different locales: the host in
# the operator's UTF-8 session, the container with no LANG set at all (C).
# Left locale-sensitive, the same value is accepted on one side and rejected
# on the other (a UTF-8 session accepts "café" because é is printable, the
# container rejects it because neither byte of it is), which is precisely the
# drift the shared copy exists to prevent. Pinning to ASCII also settles the
# downstream questions for free: the value is valid UTF-8 with one form only
# (so the MD5 the dashboard stores and the password an operator types agree,
# with no NFC/NFD pair to normalize), and the rendered XML attribute is
# well-formed in whatever encoding the game reads it as.
printable_ascii_check() { # value; prints the rejection reason, or nothing
  local LC_ALL=C
  # Leading or trailing whitespace would not survive the trip through the
  # podman --env-file renderer in run.sh (its parser trims each line), so the
  # value the container sees would silently differ from the one validated
  # here; reject both edges up front. Interior whitespace is kept.
  case "$1" in
    [[:space:]]*|*[[:space:]])
      printf 'whitespace'
      return 0
      ;;
  esac
  # The pattern matches each forbidden character literally; the escaped quote
  # inside it is the only way to write a literal single quote in a pattern.
  # shellcheck disable=SC1003  # intentional literal-quote case pattern
  case "$1" in
    *'\'*|*'|'*|*'&'*|*"'"*|*'"'*|*'$'*|*'`'*|*'<'*|*'>'*|*[![:print:]]*)
      printf 'charset'
      return 0
      ;;
  esac
}

reject_unsafe_value() { # name value
  local name="$1" reason
  reason="$(printable_ascii_check "$2")"
  case "$reason" in
    whitespace)
      echo "FATAL: $name must not start or end with whitespace" >&2
      exit 1
      ;;
    charset)
      echo "FATAL: $name must be printable ASCII: no backslash, |, &, ', \", \$, backtick, <, >, control characters, or non-ASCII characters" >&2
      exit 1
      ;;
  esac
}

# Character count under LC_ALL=C. bash counts characters in a multibyte
# locale and bytes in C, so the same value can satisfy a length rule in one
# locale and break it in another ("pässwörd" is 7 characters and 10 bytes);
# every length limit here states its unit through this helper.
ascii_length() { # value; prints the count
  local LC_ALL=C
  printf '%s' "${#1}"
}

check_webadmin_password() {
  reject_unsafe_value WEBADMIN_PASSWORD "$WEBADMIN_PASSWORD"
  if (( $(ascii_length "$WEBADMIN_PASSWORD") < 8 )); then
    echo "FATAL: WEBADMIN_PASSWORD must be at least 8 characters" >&2
    exit 1
  fi
}

check_telnet_port() {
  case "$TELNET_PORT" in
    ''|*[!0-9]*)
      echo "FATAL: TELNET_PORT must be numeric (got '$TELNET_PORT')" >&2
      exit 1
      ;;
  esac
  # Compare base-10 with leading zeros stripped: a value like 08087 would hit
  # bash's octal arithmetic, where the range test errors out and reads as
  # false, letting the bad port past this check.
  local port="${TELNET_PORT#"${TELNET_PORT%%[!0]*}"}"
  if [[ -z "$port" ]] || (( ${#port} > 5 || port < 1 || port > 65535 )); then
    echo "FATAL: TELNET_PORT must be a TCP port in 1..65535 (got '$TELNET_PORT')" >&2
    exit 1
  fi
}

# Fill unset TELNET_PASSWORD/TELNET_PORT with the committed lab defaults, then
# enforce the value rules above. One owner of both the defaults and the
# validate step so host scripts and the container entrypoint cannot drift
# apart. Call after load_env_file where a .env is in play.
#
# The lab default password is public (it ships in this repo), and a set
# TelnetPassword makes the game listen for telnet on all interfaces, so a boot
# that silently fell back to it would expose a console to everyone on the LAN.
# Applying the default therefore warns on stderr every time, in the ops
# scripts and in the container's captured boot log alike.
init_telnet_env() {
  if [[ -z "${TELNET_PASSWORD:-}" ]]; then
    echo "WARN: TELNET_PASSWORD unset; falling back to the public lab default. Set a private value in .env or the environment." >&2
  fi
  TELNET_PASSWORD="${TELNET_PASSWORD:-retest}"
  TELNET_PORT="${TELNET_PORT:-8087}"
  reject_unsafe_value TELNET_PASSWORD "$TELNET_PASSWORD"
  check_telnet_port
}

# Fill unset STEAMCMD_UPDATE/STEAMCMD_ONLY with the committed defaults, then
# pin both to the documented {0,1} domain. Every reader compares the values
# literally (run.sh forwards them via podman -e; the entrypoint tests == 1 /
# == 0), so a natural spelling like STEAMCMD_UPDATE=true would silently mean
# "skip depot validation on every boot": reject anything outside {0,1} up
# front, the same boundary treatment init_telnet_env gives its values.
init_steamcmd_env() {
  STEAMCMD_UPDATE="${STEAMCMD_UPDATE:-1}"
  STEAMCMD_ONLY="${STEAMCMD_ONLY:-0}"
  local name value
  for name in STEAMCMD_UPDATE STEAMCMD_ONLY; do
    value="${!name}"
    case "$value" in
      0|1) ;;
      *)
        echo "FATAL: $name must be 0 or 1 (got '$value')" >&2
        exit 1
        ;;
    esac
  done
}

# Single owner of the telnet wire exchange: open one /dev/tcp session to
# 127.0.0.1, send the password, send the payload, print the reply until
# timeout or EOF. Callers must have run init_telnet_env first (the port is
# re-checked here). The payload is a printf format
# fragment; separate commands with \n, e.g. 'shutdown' or 'apm status\nquit'.
telnet_session() { # port password payload timeout_secs
  local port="$1" password="$2" payload="$3" timeout_secs="$4"
  # An empty or non-numeric port would make /dev/tcp fall back to the http
  # port and hang the session; callers run check_telnet_port, this pins the
  # contract at the boundary.
  [[ "$port" =~ ^[0-9]+$ ]] || {
    echo "FATAL: telnet_session: port must be numeric (got '$port')" >&2
    exit 1
  }
  # Values travel as environment variables, never as arguments: argv is
  # world-readable via /proc/<pid>/cmdline for the whole session, while
  # environ is readable only by the owning user. The payload keeps %b; the
  # password is data, so %s, which would otherwise mangle a '%' in it.
  # shellcheck disable=SC2016  # non-expansion is the point: values reach bash -c through the environment below
  TELNET_SESSION_PORT="$port" TELNET_SESSION_PASSWORD="$password" \
    TELNET_SESSION_PAYLOAD="$payload" \
    timeout "$timeout_secs" bash -c '
      exec 3<>/dev/tcp/127.0.0.1/"$TELNET_SESSION_PORT"
      printf "%s\n%b\n" "$TELNET_SESSION_PASSWORD" "$TELNET_SESSION_PAYLOAD" >&3
      cat <&3
    '
}

# Reachability probe without authenticating: does something accept a TCP
# connection on the port right now. stop() uses it to avoid sending the
# password into a session racing a container restart. Returns nonzero on a
# non-numeric port or when the connect times out.
telnet_probe() { # port timeout_seconds
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  # shellcheck disable=SC2016  # non-expansion is the point: port passed as "$1" to bash -c
  timeout "$2" bash -c 'exec 3<>/dev/tcp/127.0.0.1/$1' telnet_probe "$port"
}

# One best-effort telnet request shared by stop() and backup(): probe, then
# authenticate and send the command. The reply always fills the caller's
# named variable (reply_var), so a failed session can still be surfaced by
# the caller (e.g. stop()'s forced-stop path). Exit codes: 0 session ran,
# 1 port unreachable, 2 session failed (rejected password, dropped
# connection).
request_telnet() { # reply_var command timeout_secs
  local reply_var="$1" command="$2" timeout_secs="$3" out="" rc=1
  if telnet_probe "$TELNET_PORT" 3 >/dev/null 2>&1; then
    if out="$(telnet_session "$TELNET_PORT" "$TELNET_PASSWORD" "$command" "$timeout_secs" 2>&1)"; then
      rc=0
    else
      rc=2
    fi
  fi
  printf -v "$reply_var" '%s' "$out"
  return "$rc"
}

# Container health probe: is the game actually serving its telnet console
# right now. Exits 0 when the endpoint accepts a connection, nonzero
# otherwise. Sources its own port from init_telnet_env so a container started
# with no telnet environment (the quadlet unit pins none) still probes the
# port the entrypoint defaulted to. telnet_probe only opens a TCP connect, so
# the password never leaves the container on this path; init_telnet_env's
# default warning is silenced here because a health check runs every minute
# and its output is the container log, not an operator-facing report.
health_check() { # timeout_seconds (default 5)
  local timeout_secs="${1:-5}"
  init_telnet_env 2>/dev/null
  telnet_probe "$TELNET_PORT" "$timeout_secs"
}

# MD5 hex digest of stdin, printed bare. md5sum(1) is GNU coreutils and does
# not exist on the macOS workstations the ops scripts also run on, where the
# same digest is spelled md5(1); probe for whichever is present rather than
# branching on the OS name. md5sum prints "hash  -", md5 -q prints "hash";
# the caller strips at the first space, so both forms land there the same.
md5_hex() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q
  else
    echo "FATAL: no MD5 digest tool found (need md5sum or md5)" >&2
    return 1
  fi
}

# Render a webadmin password as the base64 MD5 digest the dashboard expects in
# serveradmin.xml (<user pass="...">). One owner shared by the entrypoint seed
# path and its test vector, so the two cannot drift apart.
webadmin_password_digest() { # password; digest on stdout
  local hex
  hex="$(printf '%s' "$1" | md5_hex)"
  hex="${hex%% *}"
  printf '%b' "$(printf '%s' "$hex" | sed 's/\(..\)/\\x\1/g')" | base64
}
