#!/usr/bin/env bash
# Restage enabled mods from mods-available/ (if present) and restart the
# container so the entrypoint re-syncs the game's Mods/ dir.
# No image rebuild involved: mods are bind-mounted from ./mods.
# Runs on the server host; the usual trigger is remote, `./scripts/deploy.sh
# --restart` from the workstation rsyncs and then calls this script there.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/lib-env.sh"

usage() {
  cat <<'EOF'
usage: update_mods.sh

Restage enabled mods from mods-available/ (if present) and restart the
container so the entrypoint re-syncs the game's Mods/ dir. No image
rebuild: mods are bind-mounted from ./mods. Takes no arguments; the usual
trigger is remote, `./scripts/deploy.sh --restart`.
EOF
}

# Help answers before any restage or restart side effect.
case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

# Takes no arguments: any stray word or flag fails loudly instead of being
# dropped while the restage runs anyway (guards live in scripts/lib-env.sh,
# shared with the other ops scripts).
require_argc 0 usage "${2:-${1:-}}"

if [[ -d mods-available ]]; then
  # Sweep staging leftovers from a previously killed run: hidden, so the
  # mods/*/ loop and the entrypoint's cp of /mods/. would otherwise carry
  # them into the game's Mods dir as litter.
  rm -rf mods/.*.tmp.* 2>/dev/null || true
  for d in mods/*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    if [[ -d "mods-available/$name" ]]; then
      # sync_tree stages through a hidden temp rename, so a cp killed midway
      # (disk full, Ctrl-C) never leaves a half-written mod dir in mods/ for
      # the entrypoint to copy into the game, and skips the write entirely
      # when mods/ already matches mods-available/, which is the usual case
      # for a restart that changed no mod.
      if ! sync_tree "mods-available/$name" "mods/$name"; then
        echo "FATAL: failed to stage $name from mods-available/$name; keeping existing mods/" >&2
        exit 1
      fi
      echo "restaged $name from mods-available/"
    fi
  done
fi

echo "restarting container to re-sync Mods/ ..."
restart_rc=0
./scripts/run.sh restart || restart_rc=$?
# The restage above already landed in mods/, so a failed restart leaves the
# server host holding mods the running container never loaded. Name that state
# instead of dying on run.sh's bare exit.
if (( restart_rc != 0 )); then
  echo "FATAL: restart failed (exit $restart_rc); mods/ holds the restaged set but the container still runs the old Mods/ -- re-run ./scripts/run.sh start" >&2
  exit 1
fi
echo "mods now enabled: $(list_dir mods)"
