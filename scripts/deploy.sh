#!/usr/bin/env bash
# Stage mods, then rsync this project to the server host. Runtime data/ on the
# server host is never touched (it is created and owned by run.sh there).
# Env overrides: SEVENDTD_SERVER_HOST (default 192.168.0.100),
# SEVENDTD_SERVER_USER (default maci), SEVENDTD_SERVER_DIR (default
# /home/maci/7dtd-server, the remote account's home, not the local ~).
# Each is shape-checked before staging, because they reach ssh/rsync argv.
#
#   ./scripts/deploy.sh            # push project + mods
#   ./scripts/deploy.sh --restart  # push, then restart the container so the
#                                  # entrypoint re-syncs Mods/ (no image rebuild)
# Exit codes: 0 success, 2 usage error, 1 for a failed deploy/restart step.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib-env.sh"
HOST="${SEVENDTD_SERVER_HOST:-192.168.0.100}"
SSH_USER="${SEVENDTD_SERVER_USER:-maci}"
DEST_DIR="${SEVENDTD_SERVER_DIR:-/home/${SSH_USER}/7dtd-server}"

usage() {
  cat <<EOF
usage: deploy.sh [--restart]

Stage mods, then rsync this project to ${SSH_USER}@${HOST}:${DEST_DIR}/.
  --restart   push, then restart the container on the server host so the
              entrypoint re-syncs Mods/ (no image rebuild)

Env overrides: SEVENDTD_SERVER_HOST (default ${HOST}),
SEVENDTD_SERVER_USER (default ${SSH_USER}),
SEVENDTD_SERVER_DIR (default ${DEST_DIR}).

Exit codes: 0 success, 2 usage error (bad flag or rejected target value),
1 a failed deploy or restart step.
EOF
}

# At most one flag: a silently ignored second word would make e.g.
# `deploy.sh --restart dry-run` read as a supported option while the full
# deploy runs anyway. Checked before staging, so a bad invocation touches
# nothing (guard lives in scripts/lib-env.sh, shared with the other ops
# scripts).
require_argc 1 usage "${2:-}"

RESTART=0
case "${1:-}" in
  "") ;;
  -h|--help)
    usage
    exit 0
    ;;
  --restart) RESTART=1 ;;
  *)
    # Name the offender before the usage dump (same shape as run.sh).
    echo "FATAL: unexpected argument '$1'" >&2
    usage >&2
    exit 2
    ;;
esac

# All three SEVENDTD_* values reach ssh/rsync argv, and ssh reads any token
# starting with '-' as an option rather than a destination: a host or user of
# '-oProxyCommand=touch /tmp/pwn' becomes an option that runs that command on
# the deploy workstation. Pin the shape at the boundary instead of trusting the
# environment. A host or user is a DNS label, IPv4 literal, or dotted/underscore
# name; a destination is an absolute path built from the same safe set. This
# rejects an IPv6 literal (it needs brackets), which no configured host here
# uses. Checked before staging, so a bad value touches nothing.
reject_deploy_target() { # name value pattern
  local name="$1" value="$2" pattern="$3"
  if [[ ! "$value" =~ $pattern ]]; then
    echo "FATAL: $name must match $pattern (got '$value')" >&2
    exit 2
  fi
}
reject_deploy_target SEVENDTD_SERVER_HOST "$HOST" '^[A-Za-z0-9][A-Za-z0-9._-]*$'
reject_deploy_target SEVENDTD_SERVER_USER "$SSH_USER" '^[A-Za-z0-9][A-Za-z0-9._-]*$'
reject_deploy_target SEVENDTD_SERVER_DIR "$DEST_DIR" '^/[A-Za-z0-9._/-]*$'

# Staging is a phase of this deploy, and its failure gets the same treatment
# the rsync and restart phases below do: stage_mods.sh names its own cause, and
# this line names the phase and the fact that nothing reached the server host.
# A bare set -e exit here would leave the operator reading a FATAL from another
# script with no idea which step of the deploy produced it.
stage_rc=0
"$ROOT/scripts/stage_mods.sh" || stage_rc=$?
if (( stage_rc != 0 )); then
  echo "FATAL: mod staging failed (exit $stage_rc); nothing was pushed to ${SSH_USER}@${HOST}:${DEST_DIR}" >&2
  exit 1
fi

# Bound the network waits: ConnectTimeout stops a dead host from hanging the
# TCP connect, --timeout aborts a stalled transfer after 60s of no data.
# data/ is server-owned state; backups/ holds the save archives run.sh backup
# writes on the server host (deleting them here would be a --delete away);
# the rest are workstation-local caches that must not accumulate on the
# server host (.env travels on purpose so the server-side scripts render and
# validate the same values). The .scratch* pattern also covers scratch files
# dropped beside the directory (e.g. .scratch_<name>.sh copies kept for
# reference). Quoted because the pattern must reach rsync verbatim: unquoted,
# the shell expands it against the caller's cwd first, so a deploy run from a
# directory that happens to hold .scratch passes a narrower exclude than the
# one this script documents.
# --delay-updates stages every updated file in the receiver's .~tmp~ directory
# and renames it into place only once the whole transfer finished, so a
# dropped connection or an rsync killed mid-run cannot leave the server host
# running a half-written script: the tree is the old one or the new one, never
# a file that was cut off in the middle. Without it a failed push is not just
# incomplete but mixed, and the run.sh that then boots it is the residue of two
# revisions.
rsync_rc=0
rsync -a --delete --delay-updates --timeout=60 -e "ssh -o ConnectTimeout=10" \
  --exclude .git \
  --exclude data \
  --exclude backups \
  --exclude .mypy_cache \
  --exclude .ruff_cache \
  --exclude .venv \
  --exclude __pycache__ \
  --exclude coverage \
  --exclude coverage.cobertura.xml \
  --exclude '.scratch*' \
  "$ROOT/" "${SSH_USER}@${HOST}:${DEST_DIR}/" || rsync_rc=$?
# rsync --delete applies deletions as it goes, so a failed transfer can still
# leave the server host with fewer files than it started with (--delay-updates
# covers the contents of what is transferred, not the removals). Name the phase
# and the residue instead of letting the run die on rsync's own exit.
if (( rsync_rc != 0 )); then
  echo "FATAL: rsync of $ROOT/ to ${SSH_USER}@${HOST}:${DEST_DIR}/ failed (exit $rsync_rc); the tree there is partial -- re-run $0 before trusting the server host" >&2
  exit 1
fi

echo "deployed $ROOT -> ${SSH_USER}@${HOST}:${DEST_DIR}/"
if [[ "$RESTART" == "1" ]]; then
  # DEST_DIR travels as stdin data, never inside the remote command string, so
  # no character in SEVENDTD_SERVER_DIR can change what the remote shell runs.
  # The whole remote restart is bounded (update_mods restage + run.sh stop's
  # 133s worst case + start), and a local time bound kills a wedged local ssh
  # instead of pinning the session open forever like every unbounded wait here
  # would; the remote script keeps running to its own bounded completion.
  # run_bounded (scripts/lib-env.sh) owns the bound and the workstation
  # fallback: it probes for timeout(1) or coreutils' gtimeout(1), and with
  # neither it warns and continues unsupervised, because ConnectTimeout still
  # bounds the connect and the remote side self-bounds, while a hard failure
  # would strand a half-deployed tree.
  # shellcheck disable=SC2016  # non-expansion is the point: dest_dir belongs to the remote shell
  REMOTE_CMD='read -r dest_dir && cd "$dest_dir" && ./scripts/update_mods.sh'
  SSH_ARGV=(ssh -o ConnectTimeout=10 "${SSH_USER}@${HOST}" "$REMOTE_CMD")
  restart_rc=0
  printf '%s\n' "$DEST_DIR" \
    | run_bounded 300 "${SSH_ARGV[@]}" || restart_rc=$?
  # A failed restart must not read as a plain ssh hiccup: rsync already pushed
  # the tree, so the server host now holds code its running container has not
  # picked up. Name the phase and the way out instead of dying with bare ssh
  # output (the rc is preserved in the message; the exit itself stays 1 like
  # every other fatal path here).
  if (( restart_rc != 0 )); then
    echo "FATAL: remote restart on ${SSH_USER}@${HOST} failed (exit $restart_rc); the tree is deployed but the container still runs the old mods -- run ./scripts/update_mods.sh on ${HOST} or re-run '$0 --restart'" >&2
    exit 1
  fi
fi
