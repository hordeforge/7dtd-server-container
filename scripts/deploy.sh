#!/usr/bin/env bash
# Stage mods, then rsync this project to the server host. Runtime data/ on the
# server host is never touched (it is created and owned by run.sh there).
# Env overrides: SEVENDTD_SERVER_HOST (default 192.168.0.100),
# SEVENDTD_SERVER_USER (default maci), SEVENDTD_SERVER_DIR (default ~/7dtd-server).
#
#   ./scripts/deploy.sh            # push project + mods
#   ./scripts/deploy.sh --restart  # push, then restart the container so the
#                                  # entrypoint re-syncs Mods/ (no image rebuild)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${SEVENDTD_SERVER_HOST:-192.168.0.100}"
SSH_USER="${SEVENDTD_SERVER_USER:-maci}"
DEST_DIR="${SEVENDTD_SERVER_DIR:-/home/${SSH_USER}/7dtd-server}"
RESTART=0
case "${1:-}" in
  "") ;;
  --restart) RESTART=1 ;;
  *)
    echo "usage: $0 [--restart]" >&2
    exit 1
    ;;
esac

"$ROOT/scripts/stage_mods.sh"

rsync -a --delete \
  --exclude .git \
  --exclude data \
  "$ROOT/" "${SSH_USER}@${HOST}:${DEST_DIR}/"

echo "deployed $ROOT -> ${SSH_USER}@${HOST}:${DEST_DIR}/"
if [[ "$RESTART" == "1" ]]; then
  # DEST_DIR is quoted inside the remote command so spaces or shell-special
  # characters in SEVENDTD_SERVER_DIR cannot split the command.
  # shellcheck disable=SC2029  # HOST/SSH_USER/DEST_DIR are meant to expand client-side
  ssh "${SSH_USER}@${HOST}" "cd '${DEST_DIR}' && ./scripts/update_mods.sh"
fi
