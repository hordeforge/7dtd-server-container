#!/usr/bin/env bash
# Runs on the workstation (where the sibling repos live): stages their built
# mods into mods-available/ and (re)creates the enabled set as real copies in
# mods/, then deploy.sh rsyncs the tree to the server host. Real copies (not
# symlinks) so the bind-mounted mods/ dir is self-contained inside the
# container. The enabled
# set below is EfficientServer (perf) + the APM bridge + BotMod (combat bots,
# remove for clean perf runs). This script owns the enabled set: everything in
# mods/ outside NAMES is wiped by every successful run, so a mod enabled by
# hand survives only until the next staging run (deploy.sh calls this script).
# The new set
# is built beside the old one and swapped in only once every copy succeeded,
# so a failed run leaves the previously enabled mods in place, and a run that
# would stage none of them fails instead of wiping the set. To enable another
# mod persistently, add its name to NAMES; see MODS.md for what each shipped
# mod does.
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
# The two arrays are read by index, so their lengths are part of the contract:
# a mod added to one and not the other would stage a sibling's dist under
# another mod's name instead of failing. Bash expands "${#a[@]}" on an unset or
# empty array without nounset error, so the check is safe before any staging.
if (( ${#NAMES[@]} != ${#SRCS[@]} )); then
  echo "FATAL: ${NAMES[*]} and SRCS must list one entry per mod (${#NAMES[@]} vs ${#SRCS[@]})" >&2
  exit 1
fi

usage() {
  cat <<'EOF'
usage: stage_mods.sh

Stage the sibling repos' built mods into mods-available/ and (re)create the
enabled set (EfficientServer, 7dtd-server-apm-bridge, BotMod) as real
copies in mods/. Takes no arguments; everything in mods/ outside the
enabled set is wiped on every successful run. To enable another mod
persistently, add its name to NAMES in this script.
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

# The enabled set is rebuilt out of the way and swapped in only after every
# copy has succeeded. Wiping mods/ up front (as an in-place rebuild does)
# leaves the tree with a half-built or empty enabled set when a copy fails,
# and deploy.sh pushes whatever stands there, so the server host would boot
# without its mods after a run that reported the failure. The previous set
# stays intact until the new one is complete.
enabled_staging="$ROOT/mods/.enabled.tmp.$$"

# Sweep staging leftovers from a previously killed run (both dirs): hidden,
# so the wipes and globs below would keep them, and mods/ is bind-mounted,
# so its litter would reach the game's Mods dir (the entrypoint copies
# /mods/. including dot entries). Keyed on the owning PID, so a concurrent
# staging run's in-flight entries survive the sweep (sweep_stale_staging).
sweep_stale_staging "$ROOT/mods-available" "$ROOT/mods"
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

# The new set is built here, in a staging dir, and swapped in below, so a
# failed copy leaves the previously enabled mods in place. Staging starts as a
# copy of the currently enabled set, so sync_tree still finds an identical
# tree to skip on a redeploy that changed no mod. Nothing in $ROOT/mods is
# touched until every copy has succeeded: a sync_tree into mods/$name here, or
# pruning the old tree before the new one is complete, would destroy a working
# enabled set on a run that then reports the failure, and the swap below
# overwrites mods/ wholesale anyway, so that write bought nothing. The swap's
# `rm -rf mods/*` already empties mods/ and drops whatever the new set does
# not name, so a mod enabled by hand still survives only until the next
# successful staging run.
rm -rf "$enabled_staging"
mkdir -p "$enabled_staging"
for name in "${NAMES[@]}"; do
  if [[ -d "$ROOT/mods/$name" ]]; then
    cp -a "$ROOT/mods/$name" "$enabled_staging/$name"
  fi
done
enabled=0
for name in "${NAMES[@]}"; do
  if [[ -d "$ROOT/mods-available/$name" ]]; then
    if ! sync_tree "$ROOT/mods-available/$name" "$enabled_staging/$name"; then
      rm -rf "$enabled_staging"
      echo "FATAL: failed to enable $name (copy into $enabled_staging failed); $ROOT/mods left unchanged" >&2
      exit 1
    fi
  else
    echo "WARN: enabled mod $name not staged (missing in mods-available/); server will start without it" >&2
    continue
  fi
  enabled=$((enabled + 1))
done
# An empty new set means every sibling dist is missing: swapping it in would
# wipe a working enabled set and deploy a mod-less tree as a successful run.
if (( enabled == 0 )); then
  rm -rf "$enabled_staging"
  echo "FATAL: none of the enabled mods are staged in $ROOT/mods-available (${NAMES[*]}); $ROOT/mods left unchanged" >&2
  exit 1
fi
# The swap. Everything in mods/ outside the new set is wiped here and nowhere
# earlier: a sweep before staging would remove a previously enabled mod from a
# run that then failed, leaving the tree with less than it started with, and
# the staged set is complete by now, so the swap cannot lose anything. That is
# what makes the FATAL above true: a run that fails to stage anything has not
# yet touched the enabled set. The per-entry renames below are atomic, and each
# mod is either its old tree or its new one, never a half-written mix. The
# directory is bind-mounted, so the swap is per entry rather than one rename of
# mods/ itself.
rm -rf "$ROOT/mods/"*
for d in "$enabled_staging"/*/; do
  [[ -d "$d" ]] || continue
  entry="${d%/}"
  mv "$entry" "$ROOT/mods/${entry##*/}"
done
rm -rf "$enabled_staging"

echo "enabled:  $(list_dir "$ROOT/mods")"
echo "available: $(list_dir "$ROOT/mods-available")"
echo "enable another mod persistently: add its name to NAMES in $ROOT/scripts/stage_mods.sh"
