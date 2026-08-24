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
  # Sweep staging leftovers from a previously killed run: hidden, so the
  # mods/*/ loop and the entrypoint's cp of /mods/. would otherwise carry
  # them into the game's Mods dir as litter.
  rm -rf mods/.*.tmp.* 2>/dev/null || true
  for d in mods/*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    if [[ -d "mods-available/$name" ]]; then
      # Copy to a sibling temp name and rename: a cp killed midway (disk
      # full, Ctrl-C) must never leave a half-written mod dir in mods/ for
      # the entrypoint to copy into the game.
      staging="mods/.${name}.tmp.$$"
      rm -rf "$staging"
      if ! cp -a "mods-available/$name" "$staging"; then
        rm -rf "$staging"
        echo "FATAL: failed to stage $name from mods-available/$name; keeping existing mods/" >&2
        exit 1
      fi
      rm -rf "$d"
      mv "$staging" "$d"
      echo "restaged $name from mods-available/"
    fi
  done
fi

echo "restarting container to re-sync Mods/ ..."
./scripts/run.sh restart
echo "mods now enabled: $(ls mods)"
