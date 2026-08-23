# shellcheck shell=bash
# Shared .env loader, telnet env validation, and the telnet session helper
# for the ops scripts (run.sh, perf.sh).
#
# Semantics: variables already present in the environment win over the file;
# KEY=value lines only; values are taken literally (no variable expansion, no
# command substitution, no word splitting); one matching pair of surrounding
# quotes is stripped. The file is data, never code: nothing in it is eval'd.
load_env_file() {
  local line key value q
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      ''|'#'*) continue ;;
      'export '*) line="${line#'export '}" ;;
    esac
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      continue
    fi
    if [[ -n "${!key+x}" ]]; then
      continue
    fi
    value="${line#*=}"
    q="${value:0:1}"
    if [[ ${#value} -ge 2 && ( "$q" == '"' || "$q" == "'" ) && "${value: -1}" == "$q" ]]; then
      value="${value:1:$(( ${#value} - 2 ))}"
    fi
    export "$key=$value"
  done < "$1"
}

# TELNET_PASSWORD is embedded into double-quoted shell strings by the telnet
# helpers in run.sh/perf.sh and rendered into serverconfig.xml inside the
# container (an XML attribute value, where < is illegal); TELNET_PORT goes
# into both too. Reject unsafe values up front instead of failing later as a
# boot-time config parse error, a silent forced stop (no world save), or a
# container that dies on startup. The entrypoint sources this same file from
# the image (/usr/local/lib/7dtd-lib-env.sh), so host scripts and container
# enforce one shared copy of these rules.
# Shared character policy for secret values that are rendered by sed into XML
# attribute values (serverconfig.xml, serveradmin.xml) and travel through
# double-quoted shell strings in the ops scripts (see telnet_session). Reject
# unsafe values up front instead of escaping: the game reads the rendered
# files, and a mangled value fails far from the cause.
reject_unsafe_value() { # name value
  local name="$1" value="$2"
  case "$value" in
    *'\'*|*'|'*|*'&'*|*"'"*|*'"'*|*'$'*|*'`'*|*'<'*|*'>'*|*[![:print:]]*)
      echo "FATAL: $name must avoid backslash, |, &, ', \", \$, backtick, <, >, and control characters" >&2
      exit 1
      ;;
  esac
}

check_telnet_password() {
  reject_unsafe_value TELNET_PASSWORD "$TELNET_PASSWORD"
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
init_telnet_env() {
  TELNET_PASSWORD="${TELNET_PASSWORD:-retest}"
  TELNET_PORT="${TELNET_PORT:-8087}"
  check_telnet_password
  check_telnet_port
}

# Single owner of the telnet wire exchange: open one /dev/tcp session to
# 127.0.0.1, send the password, send the payload, print the reply until
# timeout or EOF. Callers must have run check_telnet_password/check_telnet_port
# first (the port is re-checked here). The payload is a printf format
# fragment; separate commands with \n, e.g. 'shutdown' or 'apm status\nquit'.
telnet_session() { # port password payload timeout_seconds
  local port="$1" password="$2" payload="$3" timeout_secs="$4"
  # An empty or non-numeric port would make /dev/tcp fall back to the http
  # port and hang the session; callers run check_telnet_port, this pins the
  # contract at the boundary.
  [[ "$port" =~ ^[0-9]+$ ]] || {
    echo "FATAL: telnet_session: port must be numeric (got '$port')" >&2
    exit 1
  }
  # Values travel as positional parameters, never inside the command string,
  # so nothing needs shell quoting. The payload is a printf format fragment
  # (separate commands with \n, e.g. 'shutdown' or 'apm status\nquit') and
  # keeps %b; the password is data, so %s, which would otherwise mangle a
  # '%' in it.
  timeout "$timeout_secs" bash -c '
    exec 3<>/dev/tcp/127.0.0.1/$1
    printf "%s\n%b\n" "$2" "$3" >&3
    cat <&3
  ' telnet_session "$port" "$password" "$payload"
}
