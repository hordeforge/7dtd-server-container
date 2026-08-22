#!/usr/bin/env bash
# Toggle the EfficientServer (perf) mod on/off and restart the container so the
# change takes effect (the mod reads its config at game boot).
# Observe the effects with:
#   ./scripts/perf.sh measure   # bridge `apm status` snapshot via telnet
#   APM web panel: http://<server>:8080  (web login admin/admin or Steam)
#   workstation capture: cd 7dtd-apm && uv run 7dtd-apm capture --seconds 60
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CFG="mods/EfficientServer/Config/efficientserver.json"
TELNET_PORT="${TELNET_PORT:-8087}"
TELNET_PASSWORD="${TELNET_PASSWORD:-retest}"

current() {
  if [[ ! -f "$CFG" ]]; then echo "missing"; return 1; fi
  grep -q '"Enabled"[[:space:]]*:[[:space:]]*true' "$CFG" && echo "on" || echo "off"
}

set_state() {
  local was
  was="$(current || echo unknown)"
  # Top-level "Enabled" only (2-space indent); the group-level Enabled flags
  # (AiLod/DynamicMesh/Gc/Governor/TickGuard/...) keep their shipped values.
  sed -i "s/^  \"Enabled\"[[:space:]]*:[[:space:]]*\(true\|false\)/  \"Enabled\": $1/" "$CFG"
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
