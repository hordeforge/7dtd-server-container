#!/usr/bin/env bash
# Unit/integration tests for scripts/lib-env.sh, run via `make test`.
#
# Methodology: exercise each lib function at its contract boundaries.
#   load_env_file      literal-value semantics, precedence, malformed lines
#   reject_unsafe_*    every forbidden character class plus length rules
#   init_telnet_env    default fill + validation wiring (host and container)
#   check_telnet_port  numeric/range boundaries incl. the octal leading-zero bug
#   telnet_session     real wire bytes against a fake telnet endpoint
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
hex="$(printf '%s' admin | md5sum)"; hex="${hex%% *}"
b64="$(printf '%b' "$(printf '%s' "$hex" | sed 's/\(..\)/\\x\1/g')" | base64)"
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
if ( TELNET_PASSWORD='retest' TELNET_PORT='abc' init_telnet_env ) 2>/dev/null; then
  echo "FAIL: init_telnet_env accepted non-numeric TELNET_PORT" >&2; exit 1
fi
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
# collisions); the server prints its port once listening.
python3 "$ROOT/scripts/fake-telnet-server.py" 0 "$tmp/received.bin" >"$tmp/port.txt" &
server_pid=$!
for _ in $(seq 1 100); do
  [[ -s "$tmp/port.txt" ]] && break
  kill -0 "$server_pid" 2>/dev/null || { echo "FATAL: fake telnet server died before listening" >&2; exit 1; }
  sleep 0.05
done
[[ -s "$tmp/port.txt" ]] || { echo "FATAL: fake telnet server never reported a port" >&2; exit 1; }
port="$(cat "$tmp/port.txt")"
source "$ROOT/scripts/lib-env.sh"
out="$(telnet_session "$port" retest 'apm status' 10)"
[[ "$out" == *"telnet ok"* ]] || { echo "FAIL: reply not relayed" >&2; exit 1; }
printf 'retest\napm status\n' > "$tmp/expected.bin"
cmp -s "$tmp/received.bin" "$tmp/expected.bin" || { echo "FAIL: wrong bytes on the wire (got $(od -c "$tmp/received.bin" | head -3))" >&2; exit 1; }
echo "telnet_session OK"
