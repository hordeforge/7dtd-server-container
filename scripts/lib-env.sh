# Shared .env loader and telnet env validation for the ops scripts
# (run.sh, perf.sh).
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
# container that dies on startup. The entrypoint keeps a parallel check for
# its own copy of the values (the image does not ship this lib).
check_telnet_password() {
  case "$TELNET_PASSWORD" in
    *'\'*|*'|'*|*'&'*|*"'"*|*'"'*|*'$'*|*'`'*|*'<'*|*'>'*|*[![:print:]]*)
      echo "FATAL: TELNET_PASSWORD must avoid backslash, |, &, ', \", \$, backtick, <, >, and control characters" >&2
      exit 1
      ;;
  esac
}

check_telnet_port() {
  case "$TELNET_PORT" in
    ''|*[!0-9]*)
      echo "FATAL: TELNET_PORT must be numeric (got '$TELNET_PORT')" >&2
      exit 1
      ;;
  esac
  if (( TELNET_PORT < 1 || TELNET_PORT > 65535 )); then
    echo "FATAL: TELNET_PORT must be a TCP port in 1..65535 (got '$TELNET_PORT')" >&2
    exit 1
  fi
}
