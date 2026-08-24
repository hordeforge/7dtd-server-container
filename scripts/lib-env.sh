# shellcheck shell=bash
# Shared .env loader, telnet env validation, and the telnet session helper
# for the ops scripts (run.sh, perf.sh).
#
# Semantics: variables already present in the environment win over the file;
# KEY=value lines only; values are taken literally (no variable expansion, no
# command substitution, no word splitting); one matching pair of surrounding
# quotes is stripped. The file is data, never code: nothing in it is eval'd.
# Malformed lines are skipped, but each skip warns on stderr: a typo'd key
# (e.g. TELNET_PASSWD=) must not silently fall back to the default value with
# no trace of why the operator's line had no effect.
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

# Shared character policy for values that travel through double-quoted shell
# strings in the ops scripts (telnet_session) and are rendered by sed into XML
# attribute values (serverconfig.xml, serveradmin.xml; < is illegal there):
# reject unsafe values up front instead of escaping, because the game reads
# the rendered files and a mangled value fails far from the cause as a
# boot-time config parse error, a silent forced stop (no world save), or a
# container that dies on startup. The entrypoint sources this same file from
# the image (/usr/local/lib/7dtd-lib-env.sh), so host scripts and container
# enforce one shared copy of these rules.
reject_unsafe_value() { # name value
  local name="$1" value="$2"
  # Leading or trailing whitespace would not survive the trip through the
  # podman --env-file renderer in run.sh (its parser trims each line), so the
  # value the container sees would silently differ from the one validated
  # here; reject both edges up front. Interior whitespace is kept.
  case "$value" in
    [[:space:]]*|*[[:space:]])
      echo "FATAL: $name must not start or end with whitespace" >&2
      exit 1
      ;;
  esac
  # The pattern matches each forbidden character literally; the escaped quote
  # inside it is the only way to write a literal single quote in a pattern.
  # shellcheck disable=SC1003  # intentional literal-quote case pattern
  case "$value" in
    *'\'*|*'|'*|*'&'*|*"'"*|*'"'*|*'$'*|*'`'*|*'<'*|*'>'*|*[![:print:]]*)
      echo "FATAL: $name must avoid backslash, |, &, ', \", \$, backtick, <, >, and control characters" >&2
      exit 1
      ;;
  esac
}

check_webadmin_password() {
  reject_unsafe_value WEBADMIN_PASSWORD "$WEBADMIN_PASSWORD"
  if (( ${#WEBADMIN_PASSWORD} < 8 )); then
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

# Render a webadmin password as the base64 MD5 digest the dashboard expects in
# serveradmin.xml (<user pass="...">). One owner shared by the entrypoint seed
# path and its test vector, so the two cannot drift apart.
webadmin_password_digest() { # password; digest on stdout
  local hex
  hex="$(printf '%s' "$1" | md5sum)"
  hex="${hex%% *}"
  printf '%b' "$(printf '%s' "$hex" | sed 's/\(..\)/\\x\1/g')" | base64
}
