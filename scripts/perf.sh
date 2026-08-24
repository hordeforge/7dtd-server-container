#!/usr/bin/env bash
# Toggle the EfficientServer (perf) mod on/off and restart the container so the
# change takes effect (the mod reads its config at game boot).
# Observe the effects with:
#   ./scripts/perf.sh measure   # bridge `apm status` snapshot via telnet
#   APM web panel: http://<server>:8080  (web login admin/<WEBADMIN_PASSWORD> or Steam)
#   workstation capture: cd 7dtd-server-apm && uv run 7dtd-server-apm capture --seconds 60
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

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

case "${1:-status}" in
  on|off)
    flag=true
    [[ "$1" == off ]] && flag=false
    set_state "$flag"
    ./scripts/run.sh restart
    ;;
  status)
    state="$(get_state || true)"
    echo "EfficientServer: $state"
    ;;
  measure)
    telnet_session "$TELNET_PORT" "$TELNET_PASSWORD" 'apm status\nquit' 15 2>&1 \
      | strings | tail -30
    ;;
  *)
    echo "usage: $0 {on|off|status|measure}" >&2
    exit 1
    ;;
esac
