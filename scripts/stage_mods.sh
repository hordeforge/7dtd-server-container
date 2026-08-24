#!/usr/bin/env bash
# Stage built mods from sibling repos into mods-available/ and (re)create the
# enabled set as real copies in mods/. Real copies (not symlinks) so the
# bind-mounted mods/ dir is self-contained inside the container. The enabled
# set below is EfficientServer (perf) + the APM bridge + BotMod (combat bots,
# remove for clean perf runs); add others with a copy, e.g.:
#   cp -a mods-available/<Name> mods/<Name>
# See MODS.md for what each shipped mod does.
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
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"
  src="${SRCS[$i]}"
  if [[ -d "$src" ]]; then
    rm -rf "$ROOT/mods-available/$name"
    cp -a "$src" "$ROOT/mods-available/$name"
    echo "staged $name <- $src"
  else
    echo "WARN: missing $src; $name not staged" >&2
  fi
done

rm -rf "$ROOT/mods/"*
for name in "${NAMES[@]}"; do
  if [[ -d "$ROOT/mods-available/$name" ]]; then
    cp -a "$ROOT/mods-available/$name" "$ROOT/mods/$name"
  else
    echo "WARN: enabled mod $name not staged (missing in mods-available/); server will start without it" >&2
  fi
done

echo "enabled:  $(ls "$ROOT/mods")"
echo "available: $(ls "$ROOT/mods-available")"
echo "enable another mod: cp -a mods-available/<Name> mods/<Name>"
