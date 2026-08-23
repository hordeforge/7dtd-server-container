#!/usr/bin/env bash
# 7dtd-server entrypoint: install/validate the game via steamcmd, write the
# platform config, render serverconfig.xml, seed the admin file, stage mods,
# then run the dedicated server in the foreground.
#
# All runtime data lives in the host-mounted volumes (data/game, data/userdata,
# mods, config); this container is disposable.
set -euo pipefail

GAME_DIR="${GAME_DIR:-/root/7dtd}"
USERDATA_DIR="${USERDATA_DIR:-/root/.local/share/7DaysToDie}"
if command -v steamcmd >/dev/null 2>&1; then
  STEAMCMD="$(command -v steamcmd)"
elif [[ -x /root/.local/share/Steam/steamcmd/steamcmd.sh ]]; then
  STEAMCMD=/root/.local/share/Steam/steamcmd/steamcmd.sh
else
  echo "[entrypoint] FATAL: steamcmd not found" >&2
  exit 1
fi
STEAM_APPID="${STEAM_APPID:-294420}"
UPDATE="${STEAMCMD_UPDATE:-1}"      # 1 = steamcmd validate every start, 0 = skip
INSTALL_ONLY="${STEAMCMD_ONLY:-0}"  # 1 = install/update then exit (pre-warm)
TELNET_PASSWORD="${TELNET_PASSWORD:-retest}"
TELNET_PORT="${TELNET_PORT:-8087}"

log() { echo "[entrypoint] $*"; }

fatal() { echo "[entrypoint] FATAL: $*" >&2; exit 1; }

# The password is substituted into serverconfig.xml via sed (delimiter |,
# replacement metachars & and \) into an XML attribute value ("), and embedded
# single-quoted into the telnet helpers of run.sh/perf.sh on the host, where
# the surrounding double quotes make $ and backticks expand. Reject anything
# that would corrupt either path instead of producing a broken config later.
check_telnet_password() {
  case "$TELNET_PASSWORD" in
    *'\'*|*'|'*|*'&'*|*"'"*|*'"'*|*'$'*|*'`'*|*[![:print:]]*)
      fatal "TELNET_PASSWORD contains a character that breaks config rendering or telnet clients; avoid backslash, |, &, ', \", \$, backtick, and control characters"
      ;;
  esac
}

check_telnet_port() {
  case "$TELNET_PORT" in
    ''|*[!0-9]*)
      fatal "TELNET_PORT must be numeric (got '$TELNET_PORT')"
      ;;
  esac
}

install_or_update() {
  local attempt rc max_attempts=3
  for attempt in 1 2 3; do
    rc=0
    log "steamcmd: install/validate app $STEAM_APPID into $GAME_DIR (attempt $attempt/$max_attempts)"
    "$STEAMCMD" +force_install_dir "$GAME_DIR" \
      +login anonymous +app_update "$STEAM_APPID" validate +quit || rc=$?
    (( rc == 0 )) && break
    # Transient Steam network errors are common; app_update validate is
    # idempotent, so retrying is safe. Bounded so a persistent failure exits.
    if (( attempt < max_attempts )); then
      log "steamcmd exited $rc; retrying in $((attempt * 10))s"
      sleep $((attempt * 10))
    fi
  done
  if (( rc != 0 )); then
    fatal "steamcmd failed after $max_attempts attempts (app $STEAM_APPID, last exit $rc)"
  fi
  if [[ ! -x "$GAME_DIR/7DaysToDieServer.x86_64" ]]; then
    fatal "steamcmd finished but 7DaysToDieServer.x86_64 is missing in $GAME_DIR"
  fi
}

write_platform_cfg() {
  # Same platform selection the workspace lab uses: Steam server with LAN and
  # Local platform joins allowed (lets a no-Steam client and loadgen bots in).
  cat > "$GAME_DIR/platform.cfg" <<'EOF'
platform=Steam
crossplatform=None
serverplatforms=Steam,LAN,Local,
EOF
}

render_config() {
  log "render serverconfig.xml (telnet port $TELNET_PORT)"
  sed -e "s|@TELNET_PASSWORD@|${TELNET_PASSWORD}|g" \
      -e "s|@TELNET_PORT@|${TELNET_PORT}|g" \
      -e "s|@USERDATA_DIR@|${USERDATA_DIR}|g" \
      /config/serverconfig.tmpl.xml > "$GAME_DIR/serverconfig.xml"
  if grep -q '@TELNET_PASSWORD@\|@TELNET_PORT@\|@USERDATA_DIR@' "$GAME_DIR/serverconfig.xml"; then
    fatal "unrendered placeholders remain in $GAME_DIR/serverconfig.xml; template mismatch"
  fi
  # The server regenerates an empty serveradmin.xml on fresh saves; re-seed the
  # dashboard admin + webuser once so the APM panel is reachable after wipes.
  if [[ ! -f "$USERDATA_DIR/Saves/serveradmin.xml" ]]; then
    mkdir -p "$USERDATA_DIR/Saves"
    cp /config/serveradmin_seed.xml "$USERDATA_DIR/Saves/serveradmin.xml"
    log "seeded serveradmin.xml (dashboard webuser admin/admin)"
  fi
}

sync_mods() {
  log "sync Mods/ from /mods (keeping stock 0_TFP_Harmony)"
  mkdir -p "$GAME_DIR/Mods"
  cd "$GAME_DIR/Mods"
  for d in */; do
    [[ -d "$d" ]] || continue
    case "$d" in
      0_TFP_Harmony/) : ;;
      *) rm -rf "$d" ;;
    esac
  done
  if [[ -d /mods ]]; then
    cp -a /mods/. "$GAME_DIR/Mods/"
  fi
  if [[ ! -d "$GAME_DIR/Mods/0_TFP_Harmony" ]]; then
    log "WARN: 0_TFP_Harmony not present in depot Mods; C# mods will not load" >&2
  fi
}

mkdir -p "$GAME_DIR" "$USERDATA_DIR/Logs"
check_telnet_password
check_telnet_port
if [[ "$UPDATE" == "1" || ! -x "$GAME_DIR/7DaysToDieServer.x86_64" ]]; then
  install_or_update
else
  log "STEAMCMD_UPDATE=0: skipping steamcmd (server binary present)"
fi
if [[ "$INSTALL_ONLY" == "1" ]]; then
  log "STEAMCMD_ONLY=1: install/update complete, exiting"
  exit 0
fi
write_platform_cfg
render_config
sync_mods

cd "$GAME_DIR"
exec ./7DaysToDieServer.x86_64 \
  -logfile "$USERDATA_DIR/Logs/output.log" \
  -quit -batchmode -nographics -dedicated \
  -configfile="$GAME_DIR/serverconfig.xml"
