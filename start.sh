#!/usr/bin/env bash
# Start the 7dtd-server container (idempotent: recreates if needed).
# All subcommands live in scripts/run.sh.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/scripts/run.sh" start
