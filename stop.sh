#!/usr/bin/env bash
# Stop the 7dtd-server container gracefully: ask the game to save + exit via
# telnet, wait for it to exit, then force-stop as a fallback.
# All subcommands live in scripts/run.sh.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/scripts/run.sh" stop
