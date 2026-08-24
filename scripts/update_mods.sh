#!/usr/bin/env bash
# Restage enabled mods from mods-available/ (if present) and restart the
# container so the entrypoint re-syncs the game's Mods/ dir.
# No image rebuild involved: mods are bind-mounted from ./mods.
# Runs on the server host; the usual trigger is remote, `./scripts/deploy.sh
# --restart` from the workstation rsyncs and then calls this script there.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -d mods-available ]]; then
  for d in mods/*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    if [[ -d "mods-available/$name" ]]; then
      rm -rf "$d"
      cp -a "mods-available/$name" "$d"
      echo "restaged $name from mods-available/"
    fi
  done
fi

echo "restarting container to re-sync Mods/ ..."
./scripts/run.sh restart
echo "mods now enabled: $(ls mods)"
