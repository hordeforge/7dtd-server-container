#!/usr/bin/env bash
# Unit/integration tests for scripts/lib-env.sh, run via `make test`.
#
# Methodology: exercise each lib function at its contract boundaries.
#   load_env_file      literal-value semantics, precedence, malformed lines
#   reject_unsafe_*    every forbidden character class plus length rules
#   init_telnet_env    default fill + validation wiring (host and container)
#   check_telnet_port  numeric/range boundaries incl. the octal leading-zero bug
#   telnet_session     real wire bytes against a fake telnet endpoint, and
#                      self-termination at its timeout against a silent one
# Each block runs in a subshell so a FATAL exit marks only that case failed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp="$(mktemp -d)"
server_pid=
cleanup() {
  # One EXIT hook for the whole run: reap the fake server if started, always
  # remove the scratch dir (a previous version leaked it per run).
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
cat > "$tmp/test.env" <<'ENV'
# comment line

PLAIN=hello
DOUBLE="double quoted"
SINGLE='single'
EVIL=$(touch ./pwned-marker)
EMPTY=
export EXPORTED=yes
NOEQUALS
KEY2=a=b
1BAD=x
BAD-KEY=y
BAD.KEY=z
ENV
(
  cd "$tmp"
  set -euo pipefail
  source "$ROOT/scripts/lib-env.sh"
  load_env_file test.env
  [[ "${PLAIN:-}" == "hello" ]] || { echo "FAIL: PLAIN" >&2; exit 1; }
  [[ "${DOUBLE:-}" == "double quoted" ]] || { echo "FAIL: DOUBLE quote stripping" >&2; exit 1; }
  [[ "${SINGLE:-}" == "single" ]] || { echo "FAIL: SINGLE quote stripping" >&2; exit 1; }
  # shellcheck disable=SC2016  # single quotes are the point: asserting the .env value stayed literal
  [[ "${EVIL:-}" == '$(touch ./pwned-marker)' ]] || { echo "FAIL: EVIL must stay literal" >&2; exit 1; }
  [[ ! -e ./pwned-marker ]] || { echo "FAIL: .env value was executed" >&2; exit 1; }
  [[ -z "${EMPTY:-}" && -n "${EMPTY+x}" ]] || { echo "FAIL: EMPTY must be set but empty" >&2; exit 1; }
  [[ "${EXPORTED:-}" == "yes" ]] || { echo "FAIL: export prefix" >&2; exit 1; }
  [[ -z "${NOEQUALS+x}" ]] || { echo "FAIL: lines without = must be skipped" >&2; exit 1; }
  [[ "${KEY2:-}" == "a=b" ]] || { echo "FAIL: KEY2 value with =" >&2; exit 1; }
  # Invalid key names (leading digit, dash, dot) cannot be expanded as shell
  # parameters, so assert via the exported environment listing.
  envlist="$(env)"
  [[ "$envlist" != *'1BAD='* && "$envlist" != *'BAD-KEY='* && "$envlist" != *'BAD.KEY='* ]] || {
    echo "FAIL: invalid key names must be skipped" >&2; exit 1; }
  echo "loader literal semantics OK"
)
# Final line without a trailing newline must still be loaded.
printf 'FIRSTLINE=yes\nNOEOL=last' > "$tmp/noeol.env"
(
  cd "$tmp"
  set -euo pipefail
  source "$ROOT/scripts/lib-env.sh"
  load_env_file noeol.env
  [[ "${FIRSTLINE:-}" == "yes" && "${NOEOL:-}" == "last" ]] || { echo "FAIL: last line without newline dropped" >&2; exit 1; }
  echo "loader no-trailing-newline OK"
)
(
  cd "$tmp"
  set -euo pipefail
  export PLAIN=fromenv EMPTY=fromenv
  source "$ROOT/scripts/lib-env.sh"
  load_env_file test.env
  [[ "${PLAIN:-}" == "fromenv" ]] || { echo "FAIL: environment must win (PLAIN)" >&2; exit 1; }
  [[ "${EMPTY:-}" == "fromenv" ]] || { echo "FAIL: environment must win (EMPTY)" >&2; exit 1; }
  echo "loader precedence OK"
)
# Literal-value corners: a duplicate key keeps the first occurrence (the env
# already has it), a quoted empty string yields set-but-empty, '#' inside a
# value is data (no inline-comment stripping exists), and a CRLF-authored line
# keeps its trailing CR, which the shared value policy must reject downstream
# instead of silently rendering into an XML attribute.
printf 'DUP=first\nDUP=second\nEMPTYQ=""\nHASH=a#b\nCRVAL=abc\r\n' > "$tmp/corner.env"
(
  cd "$tmp"
  set -euo pipefail
  unset DUP EMPTYQ HASH CRVAL
  source "$ROOT/scripts/lib-env.sh"
  load_env_file corner.env
  [[ "${DUP:-}" == "first" ]] || { echo "FAIL: duplicate key must keep the first value" >&2; exit 1; }
  [[ -z "${EMPTYQ:-}" && -n "${EMPTYQ+x}" ]] || { echo "FAIL: quoted empty value must be set but empty" >&2; exit 1; }
  [[ "${HASH:-}" == 'a#b' ]] || { echo "FAIL: '#' inside a value must stay literal" >&2; exit 1; }
  [[ "${CRVAL:-}" == $'abc\r' ]] || { echo "FAIL: CR must survive loading verbatim" >&2; exit 1; }
  # Nested subshell: the checker exits on rejection, which must mark only
  # this case failed, not the whole block.
  if ( TELNET_PASSWORD="$CRVAL" TELNET_PORT=8087 init_telnet_env ) 2>/dev/null; then
    echo "FAIL: CRLF-authored value must be rejected, not rendered into config" >&2; exit 1
  fi
  echo "loader literal corners OK"
)
source "$ROOT/scripts/lib-env.sh"
WEBADMIN_PASSWORD='correct-horse-battery' check_webadmin_password
# shellcheck disable=SC2016  # single-quoted literals: each bad value must reach the checker unexpanded
for bad in 'a|b' 'a&b' 'a"b' "a'b" 'a<b' 'a>b' 'a\b' 'a$b' 'a`b'; do
  if ( WEBADMIN_PASSWORD="$bad" check_webadmin_password ) 2>/dev/null; then
    echo "FAIL: unsafe WEBADMIN_PASSWORD accepted: $bad" >&2; exit 1
  fi
done
if ( WEBADMIN_PASSWORD="$(printf 'a\tb')" check_webadmin_password ) 2>/dev/null; then
  echo "FAIL: control character accepted in WEBADMIN_PASSWORD" >&2; exit 1
fi
if ( WEBADMIN_PASSWORD=short check_webadmin_password ) 2>/dev/null; then
  echo "FAIL: short WEBADMIN_PASSWORD accepted" >&2; exit 1
fi
# Length boundary: 7 is the largest rejected value, exactly 8 must pass.
if ( WEBADMIN_PASSWORD='1234567' check_webadmin_password ) 2>/dev/null; then
  echo "FAIL: 7-character WEBADMIN_PASSWORD accepted" >&2; exit 1
fi
if ! ( WEBADMIN_PASSWORD='12345678' check_webadmin_password ) 2>/dev/null; then
  echo "FAIL: 8-character WEBADMIN_PASSWORD rejected" >&2; exit 1
fi
# The digest renderer must produce the exact bytes the dashboard expects;
# the golden vector pins md5("admin") base64 independent of the implementation.
b64="$(webadmin_password_digest admin)"
[[ "$b64" == "ISMvKXpXpadDiUoOSoAfww==" ]] || { echo "FAIL: md5-base64 digest vector" >&2; exit 1; }
echo "webadmin password rules OK"

# check_telnet_port boundaries. Leading zeros must not hit bash octal parsing
# (the documented bug), and both range ends are exercised.
for good in 8087 1 65535 08087 00001 26902; do
  if ! ( TELNET_PORT="$good" check_telnet_port ) 2>/dev/null; then
    echo "FAIL: valid TELNET_PORT rejected: $good" >&2; exit 1
  fi
done
# shellcheck disable=SC2016  # single-quoted literals: each bad value reaches the checker verbatim
for bad in '' 'abc' '12a' 'a123' '-1' '+80' '0x50' ' 80' '0' '00' '000' '00000' '65536' '99999' '100000' '80870'; do
  if ( TELNET_PORT="$bad" check_telnet_port ) 2>/dev/null; then
    echo "FAIL: invalid TELNET_PORT accepted: '$bad'" >&2; exit 1
  fi
done
echo "telnet port rules OK"

# init_telnet_env: fills unset values with lab defaults, keeps provided ones,
# and rejects an unsafe password or a bad port through the same path used by
# run.sh, perf.sh, and the container entrypoint.
(
  set -euo pipefail
  source "$ROOT/scripts/lib-env.sh"
  unset TELNET_PASSWORD TELNET_PORT
  init_telnet_env
  [[ "${TELNET_PASSWORD:-}" == "retest" && "${TELNET_PORT:-}" == "8087" ]] || {
    echo "FAIL: init_telnet_env did not apply defaults (got '${TELNET_PASSWORD-}'/'${TELNET_PORT-}')" >&2; exit 1; }
  echo "init_telnet_env defaults OK"
)
(
  set -euo pipefail
  source "$ROOT/scripts/lib-env.sh"
  # Callers (run.sh, perf.sh, entrypoint.sh) invoke init_telnet_env at top
  # level with the values already in the environment; mirror that here.
  export TELNET_PASSWORD='s3cret-pass' TELNET_PORT=26902
  init_telnet_env
  [[ "${TELNET_PASSWORD:-}" == "s3cret-pass" && "${TELNET_PORT:-}" == "26902" ]] || {
    echo "FAIL: init_telnet_env clobbered provided values" >&2; exit 1; }
  echo "init_telnet_env precedence OK"
)
if ( TELNET_PASSWORD='a|b' TELNET_PORT=8087 init_telnet_env ) 2>/dev/null; then
  echo "FAIL: init_telnet_env accepted unsafe TELNET_PASSWORD" >&2; exit 1
fi
for bad in 'abc' '65536'; do
  if ( TELNET_PASSWORD='retest' TELNET_PORT="$bad" init_telnet_env ) 2>/dev/null; then
    echo "FAIL: init_telnet_env accepted invalid TELNET_PORT: '$bad'" >&2; exit 1
  fi
done
echo "init_telnet_env validation OK"

# telnet_session guards its own boundary: a non-numeric port would make
# /dev/tcp fall back to another port and hang, so it must exit up front.
for bad in '' 'abc' '80a' '-1'; do
  if timeout 5 bash -c "
    set -euo pipefail
    source '$ROOT/scripts/lib-env.sh'
    telnet_session '$bad' pw payload 1
  " 2>/dev/null; then
    echo "FAIL: telnet_session accepted non-numeric port: '$bad'" >&2; exit 1
  fi
done
echo "telnet_session port guard OK"

# Wire-level integration: ephemeral port from the fake server (no fixed-port
# collisions); the server prints its port once listening. Extra arguments are
# forwarded to the fake server (e.g. --hold for the silent endpoint). Sets
# FAKE_PORT and registers the pid for the EXIT cleanup hook; not run in a
# command substitution so those assignments survive.
start_fake_server() { # received_bytes_path [fake-server args...]
  local port_file="$tmp/port.txt"
  : > "$port_file"
  python3 "$ROOT/scripts/fake-telnet-server.py" 0 "$@" >"$port_file" &
  server_pid=$!
  for _ in $(seq 1 100); do
    [[ -s "$port_file" ]] && break
    kill -0 "$server_pid" 2>/dev/null || { echo "FATAL: fake telnet server died before listening" >&2; exit 1; }
    sleep 0.05
  done
  [[ -s "$port_file" ]] || { echo "FATAL: fake telnet server never reported a port" >&2; exit 1; }
  FAKE_PORT="$( < "$port_file" )"
}
source "$ROOT/scripts/lib-env.sh"

# telnet_probe: non-numeric ports are refused up front, an out-of-range port
# fails fast instead of hanging, and a listening endpoint passes (pinned
# against the fake server below, which treats a no-data connection as a probe).
for bad in '' 'abc' '80a'; do
  if telnet_probe "$bad" 1 2>/dev/null; then
    echo "FAIL: telnet_probe accepted non-numeric port: '$bad'" >&2; exit 1
  fi
done
if telnet_probe 99999 5 2>/dev/null; then
  echo "FAIL: telnet_probe reported success on invalid port 99999" >&2; exit 1
fi
echo "telnet_probe guard OK"

# Single-command payload (the run.sh stop path).
start_fake_server "$tmp/received.bin"
if ! telnet_probe "$FAKE_PORT" 3; then
  echo "FAIL: telnet_probe reported unreachable a listening endpoint" >&2; exit 1
fi
out="$(telnet_session "$FAKE_PORT" retest 'apm status' 10)"
[[ "$out" == *"telnet ok"* ]] || { echo "FAIL: reply not relayed" >&2; exit 1; }
printf 'retest\napm status\n' > "$tmp/expected.bin"
cmp -s "$tmp/received.bin" "$tmp/expected.bin" || { echo "FAIL: wrong bytes on the wire (got $(od -c "$tmp/received.bin" | head -3))" >&2; exit 1; }
echo "telnet_session OK"

# Multi-command payload with an embedded \n (the perf.sh measure path): pins
# the printf %b expansion so each command reaches telnet as its own line.
start_fake_server "$tmp/received2.bin"
out="$(telnet_session "$FAKE_PORT" retest 'apm status\nquit' 10)"
[[ "$out" == *"telnet ok"* ]] || { echo "FAIL: reply not relayed (multi-command payload)" >&2; exit 1; }
printf 'retest\napm status\nquit\n' > "$tmp/expected2.bin"
cmp -s "$tmp/received2.bin" "$tmp/expected2.bin" || {
  echo "FAIL: wrong bytes on the wire (multi-command; got $(od -c "$tmp/received2.bin" | head -3))" >&2; exit 1; }
echo "telnet_session multi-command OK"

# Bounded session: an endpoint that accepts and then stays silent (the wedged
# server case) must end the session at its timeout, rc 124 from timeout(1) --
# never hang. The graceful-stop budget math (run.sh stop, and TimeoutStopSec
# in systemd/7dtd-server.container, pinned by test_systemd_unit.py) assumes
# this bound holds. The inner session timeout is 2s; an outer 8s guard turns
# a removed inner bound into a fast failed check (elapsed > 4) instead of a
# hung suite.
start_fake_server ignored.bin --hold
SECONDS=0
session_rc=0
reply="$(timeout 8 bash -c "
  set -euo pipefail
  source '$ROOT/scripts/lib-env.sh'
  telnet_session '$FAKE_PORT' retest 'apm status' 2
" 2>/dev/null)" || session_rc=$?
[[ "$session_rc" == 124 ]] || {
  echo "FAIL: silent endpoint did not end the session at its timeout (rc $session_rc)" >&2; exit 1; }
(( SECONDS <= 4 )) || { echo "FAIL: session outlived its ${SECONDS}s budget" >&2; exit 1; }
[[ -z "${reply:-}" ]] || { echo "FAIL: silent endpoint produced a reply" >&2; exit 1; }
echo "telnet_session bounded timeout OK"
