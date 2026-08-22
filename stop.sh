#!/usr/bin/env bash
# Stop the 7dtd-server container gracefully (saves the world, waits up to 60s).
# All subcommands live in scripts/run.sh.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/scripts/run.sh" stop
