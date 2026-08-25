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

# Bound the network waits: ConnectTimeout stops a dead host from hanging the
# TCP connect, --timeout aborts a stalled transfer after 60s of no data.
# data/ is server-owned state; the rest are workstation-local caches that must
# not accumulate on the server host (.env travels on purpose so the
# server-side scripts render and validate the same values). The .scratch*
# pattern also covers scratch files dropped beside the directory (e.g.
# .scratch_<name>.sh copies kept for reference).
rsync -a --delete --timeout=60 -e "ssh -o ConnectTimeout=10" \
  --exclude .git \
  --exclude data \
  --exclude .mypy_cache \
  --exclude .ruff_cache \
  --exclude __pycache__ \
  --exclude coverage \
  --exclude coverage.cobertura.xml \
  --exclude .scratch* \
  "$ROOT/" "${SSH_USER}@${HOST}:${DEST_DIR}/"

echo "deployed $ROOT -> ${SSH_USER}@${HOST}:${DEST_DIR}/"
if [[ "$RESTART" == "1" ]]; then
  # DEST_DIR travels as stdin data, never inside the remote command string, so
  # no character in SEVENDTD_SERVER_DIR can change what the remote shell runs.
  # The whole remote restart is bounded (update_mods restage + run.sh stop's
  # 133s worst case + start), and a local time bound kills a wedged local ssh
  # instead of pinning the session open forever like every unbounded wait here
  # would; the remote script keeps running to its own bounded completion.
  # The bound is a capability probe, not an assumption: timeout(1) is GNU
  # coreutils and absent from stock macOS (coreutils' gtimeout arrives only
  # via brew), while this script also runs on workstations that are not Linux
  # (stage_mods.sh targets bash 3.x for exactly those). With neither binary,
  # warn and continue unsupervised: ConnectTimeout still bounds the connect
  # and the remote side self-bounds, so only a wedged established connection
  # now hangs until the operator interrupts it -- a hard failure here would
  # strand a half-deployed tree instead.
  TIMEOUT_BIN=""
  for timeout_candidate in timeout gtimeout; do
    if command -v "$timeout_candidate" >/dev/null 2>&1; then
      TIMEOUT_BIN="$timeout_candidate"
      break
    fi
  done
  # shellcheck disable=SC2016  # non-expansion is the point: dest_dir belongs to the remote shell
  REMOTE_CMD='read -r dest_dir && cd "$dest_dir" && ./scripts/update_mods.sh'
  if [[ -n "$TIMEOUT_BIN" ]]; then
    printf '%s\n' "$DEST_DIR" \
      | "$TIMEOUT_BIN" 300 ssh -o ConnectTimeout=10 "${SSH_USER}@${HOST}" "$REMOTE_CMD"
  else
    echo "WARN: timeout(1) not found; running the remote restart without a local time bound" >&2
    printf '%s\n' "$DEST_DIR" \
      | ssh -o ConnectTimeout=10 "${SSH_USER}@${HOST}" "$REMOTE_CMD"
  fi
fi
