#!/usr/bin/env bash
# Toggle the EfficientServer (perf) mod on/off and restart the container so the
# change takes effect (the mod reads its config at game boot).
# Observe the effects with:
#   ./scripts/perf.sh measure   # bridge `apm status` snapshot via telnet
#   APM web panel: http://<server>:8080  (web login admin/admin or Steam)
#   workstation capture: cd 7dtd-server-apm && uv run 7dtd-server-apm capture --seconds 60
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CFG="mods/EfficientServer/Config/efficientserver.json"
TELNET_PORT="${TELNET_PORT:-8087}"
TELNET_PASSWORD="${TELNET_PASSWORD:-retest}"

current() {
  if [[ ! -f "$CFG" ]]; then echo "missing"; return 1; fi
  # Anchor like set_state: only the top-level flag counts, otherwise any
  # group-level Enabled (AiLod/Gc/...) makes a disabled mod read as "on".
  grep -Eq '^  "Enabled"[[:space:]]*:[[:space:]]*true([[:space:]]*,?$)' "$CFG" && echo "on" || echo "off"
}

set_state() {
  local was
  if [[ ! -f "$CFG" ]]; then
    echo "FATAL: $CFG not found; is EfficientServer staged and enabled?" >&2
    exit 1
  fi
  was="$(current)"
  # Top-level "Enabled" only (2-space indent); the group-level Enabled flags
  # (AiLod/DynamicMesh/Gc/Governor/TickGuard/...) keep their shipped values.
  sed -i "s/^  \"Enabled\"[[:space:]]*:[[:space:]]*\(true\|false\)/  \"Enabled\": $1/" "$CFG"
  # Verify the edit landed: a config reformatted by a future mod build would
  # make the sed a silent no-op, and restarting the container would change
  # nothing while reporting success.
  if ! grep -Eq "^  \"Enabled\"[[:space:]]*:[[:space:]]*$1([[:space:]]*,?\$)" "$CFG"; then
    echo "FATAL: failed to set top-level \"Enabled\": $1 in $CFG (state after edit: $(current)); config format changed?" >&2
    exit 1
  fi
  echo "EfficientServer -> $1 (was $was)"
}

case "${1:-status}" in
  on)
    set_state true
    ./scripts/run.sh restart
    ;;
  off)
    set_state false
    ./scripts/run.sh restart
    ;;
  status)
    echo "EfficientServer: $(current)"
    ;;
  measure)
    timeout 15 bash -c "exec 3<>/dev/tcp/127.0.0.1/${TELNET_PORT}; printf '${TELNET_PASSWORD}\napm status\nquit\n' >&3; cat <&3" 2>&1 \
      | strings | tail -30
    ;;
  *)
    echo "usage: $0 {on|off|status|measure}" >&2
    exit 1
    ;;
esac
