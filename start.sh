#!/usr/bin/env bash
# Start the 7dtd-server container (idempotent: recreates if needed).
# All subcommands live in scripts/run.sh; arguments are forwarded so a
# stray one fails loudly there instead of being dropped here. -h/--help
# is answered below, before any setup side effect.
set -euo pipefail
case "${1:-}" in
  -h|--help)
    cat <<'EOF'
usage: start.sh [-h|--help]

Daily shortcut for scripts/run.sh start: recreate and start the container
(graceful stop first). Takes no other arguments; a stray one is rejected
there. scripts/run.sh --help has the full command list.
EOF
    exit 0
    ;;
esac
exec "$(cd "$(dirname "$0")" && pwd)/scripts/run.sh" start "$@"
