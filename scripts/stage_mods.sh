#!/usr/bin/env bash
# Runs on the workstation (where the sibling repos live): stages their built
# mods into mods-available/ and (re)creates the enabled set as real copies in
# mods/, then deploy.sh rsyncs the tree to the server host. Real copies (not
# symlinks) so the bind-mounted mods/ dir is self-contained inside the
# container. The enabled
# set below is EfficientServer (perf) + the APM bridge + BotMod (combat bots,
# remove for clean perf runs). This script owns the enabled set: everything in
# mods/ outside NAMES is wiped on every run, so a mod enabled by hand survives
# only until the next staging run (deploy.sh calls this script). To enable
# another mod persistently, add its name to NAMES; see MODS.md for what each
# shipped mod does.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WS="$(cd "$ROOT/.." && pwd)"

# Parallel indexed arrays, not an associative array: indexed arrays need only
# bash 3.x, so staging also works on workstations whose stock bash predates
# declare -A (macOS ships 3.2).
NAMES=(EfficientServer 7dtd-server-apm-bridge BotMod)
SRCS=(
  "$WS/7dtd-server-optimizer/dist/EfficientServer"
  "$WS/7dtd-server-apm/dist/7dtd-server-apm-bridge"
  "$WS/7dtd-fps-bots/dist/BotMod"
)

mkdir -p "$ROOT/mods-available" "$ROOT/mods"
# Sweep staging leftovers from a previously killed run (both dirs): hidden,
# so the wipes and globs below would keep them, and mods/ is bind-mounted,
# so its litter would reach the game's Mods dir (the entrypoint copies
# /mods/. including dot entries).
rm -rf "$ROOT/mods-available/".*.tmp.* "$ROOT/mods/".*.tmp.* 2>/dev/null || true
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"
  src="${SRCS[$i]}"
  if [[ -d "$src" ]]; then
    # Copy to a sibling temp name and rename (hidden, so it never matches
    # the ls/globs below): a cp killed midway must not leave a half-written
    # mod dir that later gets copied into mods/.
    staging="$ROOT/mods-available/.${name}.tmp.$$"
    rm -rf "$staging"
    if ! cp -a "$src" "$staging"; then
      rm -rf "$staging"
      echo "FATAL: failed to copy $src into mods-available/; check disk space and permissions" >&2
      exit 1
    fi
    rm -rf "$ROOT/mods-available/$name"
    mv "$staging" "$ROOT/mods-available/$name"
    echo "staged $name <- $src"
  else
    echo "WARN: missing $src; $name not staged" >&2
  fi
done

# The wipe keeps hidden files, but the up-front sweep above already removed
# any stale staging entries.
rm -rf "$ROOT/mods/"*
for name in "${NAMES[@]}"; do
  if [[ -d "$ROOT/mods-available/$name" ]]; then
    staging="$ROOT/mods/.${name}.tmp.$$"
    if ! cp -a "$ROOT/mods-available/$name" "$staging"; then
      rm -rf "$staging"
      echo "FATAL: failed to enable $name (copy into mods/ failed)" >&2
      exit 1
    fi
    mv "$staging" "$ROOT/mods/$name"
  else
    echo "WARN: enabled mod $name not staged (missing in mods-available/); server will start without it" >&2
  fi
done

echo "enabled:  $(ls "$ROOT/mods")"
echo "available: $(ls "$ROOT/mods-available")"
echo "enable another mod: cp -a mods-available/<Name> mods/<Name>"
