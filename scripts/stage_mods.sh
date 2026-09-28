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
source "$ROOT/scripts/lib-env.sh"
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

usage() {
  cat <<'EOF'
usage: stage_mods.sh

Stage the sibling repos' built mods into mods-available/ and (re)create the
enabled set (EfficientServer, 7dtd-server-apm-bridge, BotMod) as real
copies in mods/. Takes no arguments; everything in mods/ outside the
enabled set is wiped on every run. To enable another mod persistently, add
its name to NAMES in this script.
EOF
}

# Help answers before any staging side effect, like every script here.
case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

# Takes no arguments: any stray word or flag fails loudly instead of being
# dropped while the enabled set was rebuilt anyway (guards live in
# scripts/lib-env.sh, shared with the other ops scripts).
require_argc 0 usage "${2:-${1:-}}"

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
    # sync_tree skips the copy when mods-available/$name is already identical
    # to $src, which is the usual outcome of a redeploy that changed no mod,
    # and stages through a hidden temp rename otherwise.
    if ! sync_tree "$src" "$ROOT/mods-available/$name"; then
      echo "FATAL: failed to copy $src into mods-available/; check disk space and permissions" >&2
      exit 1
    fi
    echo "staged $name <- $src"
  else
    echo "WARN: missing $src; $name not staged" >&2
  fi
done

# Remove what the enabled set no longer names, and nothing else, so a mod
# enabled by hand survives only until the next staging run. Entries in NAMES
# are left for the sync_tree calls below, which rewrite one only when its
# content differs from mods-available/; wiping the whole tree first would
# leave nothing to compare against and copy every mod on every run.
# The sweep keeps hidden files, but the up-front sweep above already removed
# any stale staging entries.
for d in "$ROOT/mods"/*/; do
  [[ -d "$d" ]] || continue
  name="${d%/}"
  name="${name##*/}"
  enabled=0
  for wanted in "${NAMES[@]}"; do
    if [[ "$name" == "$wanted" ]]; then
      enabled=1
      break
    fi
  done
  if (( enabled == 0 )); then
    rm -rf "$d"
  fi
done
for name in "${NAMES[@]}"; do
  if [[ -d "$ROOT/mods-available/$name" ]]; then
    if ! sync_tree "$ROOT/mods-available/$name" "$ROOT/mods/$name"; then
      echo "FATAL: failed to enable $name (copy into mods/ failed)" >&2
      exit 1
    fi
  else
    echo "WARN: enabled mod $name not staged (missing in mods-available/); server will start without it" >&2
  fi
done

echo "enabled:  $(ls "$ROOT/mods")"
echo "available: $(ls "$ROOT/mods-available")"
echo "enable another mod persistently: add its name to NAMES in $ROOT/scripts/stage_mods.sh"
