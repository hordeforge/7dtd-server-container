#!/usr/bin/env bash
# Stop the 7dtd-server container gracefully: ask the game to save + exit via
# telnet, wait for it to exit, then force-stop as a fallback.
# All subcommands live in scripts/run.sh; arguments are forwarded so a
# stray one fails loudly there instead of being dropped here. -h/--help
# is answered below, before any setup side effect.
set -euo pipefail
case "${1:-}" in
  -h|--help)
    cat <<'EOF'
usage: stop.sh [-h|--help]

Daily shortcut for scripts/run.sh stop: telnet save + shutdown, then a
forced stop as fallback. Takes no other arguments; a stray one is rejected
there. scripts/run.sh --help has the full command list.
EOF
    exit 0
    ;;
esac
exec "$(cd "$(dirname "$0")" && pwd)/scripts/run.sh" stop "$@"
