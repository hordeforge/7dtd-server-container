#!/usr/bin/env bash
# Toggle the EfficientServer (perf) mod on/off and restart the container so the
# change takes effect (the mod reads its config at game boot).
# Runs on the server host: it edits the staged mods/EfficientServer config in
# place and restarts through scripts/run.sh (the container's host).
# Observe the effects with:
#   ./scripts/perf.sh measure   # bridge `apm status` snapshot via telnet
#   APM web panel: http://<server>:8080  (web login admin/<WEBADMIN_PASSWORD> or Steam)
#   workstation capture: cd 7dtd-server-apm && uv run 7dtd-server-apm capture --seconds 60
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
usage: perf.sh {on|off|status|measure}

Toggle the EfficientServer (perf) mod and observe its effects.
  on | off    set the top-level Enabled flag in the staged mod config and
              restart the container (the mod reads it at game boot)
  status      print the current toggle state (default with no command)
  measure     capture an `apm status` snapshot from the telnet console

Observe the effects with:
  ./scripts/perf.sh measure   # bridge `apm status` snapshot via telnet
  APM web panel: http://<server>:8080
EOF
}

case "${1:-}" in
  # Help answers before any .env load or value validation: asking for help
  # must never fail on an unrelated broken env value.
  -h|--help)
    usage
    exit 0
    ;;
esac

# Exactly one command word: a silently ignored second word would make e.g.
# `perf.sh status --json` read as a supported option while status runs with
# its plain output (same guard run.sh applies to its commands).
if (( $# > 1 )); then
  echo "FATAL: unexpected argument '$2' ($0 takes exactly one command)" >&2
  usage >&2
  exit 2
fi

# Validate the command word before the .env load and value validation: a
# typo must surface as a usage error even when the environment itself is
# broken, same rule as --help above (and run.sh's command check).
COMMAND="${1:-status}"
case "$COMMAND" in
  on|off|status|measure) ;;
  *)
    # Name the offender before the usage dump: an error that never says
    # which word was wrong sends the operator re-reading the invocation.
    # 2, not 1: a bad invocation must be distinguishable from a failed
    # operation (same code the CI helper and run.sh use).
    echo "FATAL: unknown command '$1'" >&2
    usage >&2
    exit 2
    ;;
esac

CFG="mods/EfficientServer/Config/efficientserver.json"
# Top-level "Enabled" line only (2-space indent); group-level Enabled flags
# (AiLod/DynamicMesh/Gc/Governor/...) keep their shipped values. One shared
# prefix for get/set/verify below so the three cannot drift apart.
ENABLED_LINE_RE='^  "Enabled"[[:space:]]*:[[:space:]]*'

# Same precedence as run.sh: environment beats .env, .env beats the shared
# defaults. Values are literal (see scripts/lib-env.sh); nothing in .env is
# executed.
source "$ROOT/scripts/lib-env.sh"
if [[ -f "$ROOT/.env" ]]; then
  load_env_file "$ROOT/.env"
fi
# The password travels through telnet_session in measure() below, so the
# shared defaults + validation must run before anything else happens.
init_telnet_env

get_state() {
  if [[ ! -f "$CFG" ]]; then echo "missing"; return 1; fi
  if grep -Eq "${ENABLED_LINE_RE}true([[:space:]]*,?\$)" "$CFG"; then echo "on"; else echo "off"; fi
}

set_state() {
  local was
  if [[ ! -f "$CFG" ]]; then
    echo "FATAL: $CFG not found; is EfficientServer staged and enabled?" >&2
    exit 1
  fi
  was="$(get_state)"
  sed -i -E "s/${ENABLED_LINE_RE}(true|false)/  \"Enabled\": $1/" "$CFG"
  # Verify the edit landed: a config reformatted by a future mod build would
  # make the sed a silent no-op, and restarting the container would change
  # nothing while reporting success.
  if ! grep -Eq "${ENABLED_LINE_RE}$1([[:space:]]*,?\$)" "$CFG"; then
    echo "FATAL: failed to set top-level \"Enabled\": $1 in $CFG (state after edit: $(get_state)); config format changed?" >&2
    exit 1
  fi
  echo "EfficientServer -> $1 (was $was)"
}

case "$COMMAND" in
  on|off)
    flag=true
    [[ "$COMMAND" == off ]] && flag=false
    set_state "$flag"
    ./scripts/run.sh restart
    ;;
  status)
    state="$(get_state || true)"
    echo "EfficientServer: $state"
    ;;
  measure)
    # Capture the reply before the display pipeline: a failed session
    # (container down, timeout) must print why, not die silently inside the
    # pipe where pipefail surfaces only as a bare nonzero exit with no output.
    # The session's own captured output (connection refused, timeout notice)
    # rides along: the generic FATAL line says which step failed, the reply
    # tail says what actually happened on the wire.
    reply="$(telnet_session "$TELNET_PORT" "$TELNET_PASSWORD" 'apm status\nquit' 15 2>&1)" || {
      echo "FATAL: telnet session on port $TELNET_PORT failed (is the container up?); no apm status" >&2
      printf '%s\n' "${reply:-<no output>}" | tail -n 3 >&2
      exit 1
    }
    # Strip control bytes without binutils(1) strings, which a minimal podman
    # host may not ship: keep only printable ASCII plus tab/newline (CR goes,
    # so telnet's \r\n ends up as plain lines; IAC/high bytes go with it).
    printf '%s\n' "$reply" | LC_ALL=C tr -cd '\11\12\40-\176' | tail -30
    ;;
esac
