#!/usr/bin/env bash
# 7dtd-server entrypoint: install/validate the game via steamcmd, write the
# platform config, render serverconfig.xml, seed the admin file, stage mods,
# then run the dedicated server in the foreground.
#
# All runtime data lives in the host-mounted volumes (data/game, data/userdata,
# mods, config); this container is disposable.
set -euo pipefail

GAME_DIR=/root/7dtd
USERDATA_DIR=/root/.local/share/7DaysToDie

log() { echo "[entrypoint] $*"; }

fatal() { echo "[entrypoint] FATAL: $*" >&2; exit 1; }

if STEAMCMD="$(command -v steamcmd 2>/dev/null)"; then
  :
elif [[ -x /root/.local/share/Steam/steamcmd/steamcmd.sh ]]; then
  STEAMCMD=/root/.local/share/Steam/steamcmd/steamcmd.sh
else
  fatal "steamcmd not found"
fi
STEAM_APPID=294420
UPDATE="${STEAMCMD_UPDATE:-1}"      # 1 = steamcmd validate every start, 0 = skip
INSTALL_ONLY="${STEAMCMD_ONLY:-0}"  # 1 = install/update then exit (pre-warm)

# Shared telnet defaults + value validation (same rules the host ops scripts
# use). The lib is shipped into the image by the Containerfile so both sides
# enforce one copy of the rules; it exits 1 with a FATAL line on a bad value.
# shellcheck disable=SC1091  # the lib lives at this absolute path inside the image, not on the host
source /usr/local/lib/7dtd-lib-env.sh
init_telnet_env

# Assert every template placeholder was replaced: an unrendered @TOKEN@ means
# template and render script drifted, which must fail here rather than surface
# as a game-boot config parse error far from the cause.
assert_rendered() { # file placeholder...
  local file="$1"
  shift
  local ph
  for ph in "$@"; do
    if grep -qF -- "$ph" "$file"; then
      fatal "unrendered placeholder $ph remains in $file; template mismatch"
    fi
  done
}

install_or_update() {
  local attempt rc max_attempts=3
  for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
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
  assert_rendered "$GAME_DIR/serverconfig.xml" '@TELNET_PASSWORD@' '@TELNET_PORT@' '@USERDATA_DIR@'
}

seed_admin_file() {
  # The game creates Saves/ on its own first run, but this seed happens
  # before that; without it a fresh host crashes here writing serveradmin.xml.
  mkdir -p "$USERDATA_DIR/Saves"
  if [[ -f "$USERDATA_DIR/Saves/serveradmin.xml" ]]; then
    return 0
  fi
  # The server regenerates an empty serveradmin.xml on fresh saves; re-seed the
  # dashboard admin + webuser once so the APM panel is reachable after wipes.
  # The webuser credential never ships in the image or repo: WEBADMIN_PASSWORD
  # wins when set, otherwise a random value is minted for this seed. Only the
  # MD5 digest the dashboard expects is written to serveradmin.xml; the
  # plaintext is printed once, below (host-user-readable container log).
  if [[ -z "${WEBADMIN_PASSWORD:-}" ]]; then
    WEBADMIN_PASSWORD="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    export WEBADMIN_PASSWORD
  fi
  check_webadmin_password
  local hex b64
  hex="$(printf '%s' "$WEBADMIN_PASSWORD" | md5sum)"
  hex="${hex%% *}"
  b64="$(printf '%b' "$(printf '%s' "$hex" | sed 's/\(..\)/\\x\1/g')" | base64)"
  sed -e "s|@WEBADMIN_PASSWORD_HASH@|${b64}|g" \
    /config/serveradmin_seed.xml > "$USERDATA_DIR/Saves/serveradmin.xml"
  assert_rendered "$USERDATA_DIR/Saves/serveradmin.xml" '@WEBADMIN_PASSWORD_HASH@'
  log "seeded serveradmin.xml (dashboard webuser admin, password: $WEBADMIN_PASSWORD)"
}

sync_mods() {
  log "sync Mods/ from /mods (keeping stock 0_TFP_Harmony)"
  mkdir -p "$GAME_DIR/Mods"
  (
    cd "$GAME_DIR/Mods"
    for d in */; do
      [[ -d "$d" ]] || continue
      case "$d" in
        0_TFP_Harmony/) : ;;
        *) rm -rf "$d" ;;
      esac
    done
  )
  if [[ -d /mods ]]; then
    cp -a /mods/. "$GAME_DIR/Mods/"
  fi
  if [[ ! -d "$GAME_DIR/Mods/0_TFP_Harmony" ]]; then
    log "WARN: 0_TFP_Harmony not present in depot Mods; C# mods will not load" >&2
  fi
}

mkdir -p "$GAME_DIR" "$USERDATA_DIR/Logs"
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
seed_admin_file
sync_mods

cd "$GAME_DIR"
exec ./7DaysToDieServer.x86_64 \
  -logfile "$USERDATA_DIR/Logs/output.log" \
  -quit -batchmode -nographics -dedicated \
  -configfile="$GAME_DIR/serverconfig.xml"
