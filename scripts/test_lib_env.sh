#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
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
  echo "loader literal semantics OK"
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

port=18087
python3 "$ROOT/scripts/fake-telnet-server.py" "$port" "$tmp/received.bin" &
server_pid=$!
cleanup() { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; }
trap cleanup EXIT
for _ in $(seq 1 50); do
  if timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then break; fi
  sleep 0.1
done
source "$ROOT/scripts/lib-env.sh"
out="$(telnet_session "$port" retest 'apm status' 10)"
[[ "$out" == *"telnet ok"* ]] || { echo "FAIL: reply not relayed" >&2; exit 1; }
printf 'retest\napm status\n' > "$tmp/expected.bin"
cmp -s "$tmp/received.bin" "$tmp/expected.bin" || { echo "FAIL: wrong bytes on the wire (got $(od -c "$tmp/received.bin" | head -3))" >&2; exit 1; }
echo "telnet_session OK"
