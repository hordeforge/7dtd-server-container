#!/usr/bin/env bash
# Seeded fuzz harness for the .env parser in scripts/lib-env.sh, run via
# `make test`.
#
# Why this surface: .env is a per-deployment, git-ignored, hand-edited file
# that the host scripts and, through the copy baked into the image, the
# container entrypoint both parse. scripts/test_fuzz_xml.py covers the XML
# side of the same trust boundary; this covers the other parser, the one whose
# input is bytes somebody typed into an editor on whatever workstation they
# happen to use.
#
# Atheris and Hypothesis are not dependencies of this repo (the gate installs
# only the hash-pinned analyzer closure), so coverage comes from a seeded
# generator instead: fixed seeds, a bounded case count, and assertions that
# encode the invariants rather than only catching a crash. A fuzzer proves
# bugs exist; the assertions here are what turn a silently wrong value into a
# failing case.
#
# Cases are assembled from line kinds rather than random bytes: documented
# keys, near-miss and malformed key spellings, quoted and unquoted values,
# values that look like command substitution, CRLF and BOM and NUL bytes, a
# missing final newline, an empty file, a duplicated key, a preset environment
# variable, and a 4 KB value. Expectations come from the generator's intent,
# not from a second copy of the parser, so a loader that changes what it
# exports shows up as a disagreement instead of as two matching wrong answers.
#
# Per case the loader and the key check each run in a fresh shell, and every
# one of these must hold:
#   exported             exactly the intended keys, with the intended values
#   unset                keys the loader must not have touched
#   no line on a stream  exit 0, an empty stdout, and no warning or refusal
#                        carrying a value or echoing a line back
#   check_env_file_keys  0 iff every well-formed key in the file is documented,
#                        naming the file and the offending key, never a value
#   value predicates     ascii_length, reject_unsafe_value, check_telnet_port,
#                        check_steamcmd_env, require_command and require_argc
#                        each agree with an oracle written independently of the
#                        lib: right exit code, right stream, and a refusal that
#                        names what it refused
#   no execution         a value carrying $(...) or backticks stays literal and
#                        creates no file
# A clean run prints one line; every violation is reported with its case.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib-env.sh"

# One case, one driver: past this a case is a hung parser, and past the
# whole-run budget the gate itself is the problem.
SEEDS=(20260928 7717 31337)
ITERATIONS_PER_SEED=60
CASE_SECONDS=10
RUN_SECONDS=120
MAX_REPORTED_VIOLATIONS=10

# The command word set run.sh accepts, read out of run.sh rather than pinned
# here: a copy in this file is how the list went stale when verify-backup was
# added, and the oracle below is only worth anything while it is the real one.
# The sed range matches run.sh's own text, so $COMMAND stays a literal there.
# shellcheck disable=SC2016  # matching run.sh's source, not a variable
COMMAND_WORDS="$(
  sed -n '/^require_command "\$COMMAND"/,/usage$/p' "$ROOT/scripts/run.sh" |
    grep -o "'[^']*'" | tr -d "'"
)"
[[ "$COMMAND_WORDS" == *'|'* ]] || {
  echo "FATAL: could not read the command word list out of scripts/run.sh" >&2
  exit 1
}

# Values a real .env line carries, plus the shapes that break a naive parser:
# a quote character, an embedded '=', command substitution, a shell
# metacharacter, a leading or trailing space, non-ASCII, a comment character,
# a format specifier, a long value, an embedded newline, and the port
# spellings with a sign, a leading zero, and one past the range.
# shellcheck disable=SC2016  # literal payloads: non-expansion is the point
VALUES=(
  'retest' '8087' '0' '1' '7' '' 'a b' 'a=b' "it's" 'say "hi"' '$HOME'
  '$(touch pwned-marker)' '`touch pwned-marker`' 'a\b' 'a|b' 'a&b' 'x<y>z'
  'café' 'ünïcödé' '日本語' '  lead' 'trail  ' '#notacomment' 'a#b' '%s%d'
  '=leading' '08087' '65535' '65536' '99999' '-1' '1.5' 'a
b'
)
VALUES+=("$(printf 'x%.0s' {1..4096})")

# Key spellings: the documented set is read from the lib, and these are the
# ways of being one character off it plus the shapes the loader must refuse.
BAD_KEYS=(1BAD BAD-KEY BAD.KEY '' ' TELNET_PORT' 'TELNET_PORT ' '9A' 'A' 'export' 'PATH' 'FOO')

violations=0
case_label=startup

fail() {
  violations=$(( violations + 1 ))
  if (( violations <= MAX_REPORTED_VIOLATIONS )); then
    echo "FAIL: fuzz: $case_label: $*" >&2
  fi
}

in_list() { # needle item...
  local needle="$1" item
  shift
  for item in ${1+"$@"}; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# Seeded LCG, advancing in the current shell so a case count cannot depend on
# how many command substitutions happened to run. bash's $RANDOM is re-seeded
# per shell, which would make a reported payload unreproducible; rng_state is
# the whole generator state.
rng_state=0
rnd=0
seed_rng() { rng_state=$(( (SEED * 2654435761) & 0x7fffffff )); }
pick() { # count -> rnd
  rng_state=$(( (rng_state * 1103515245 + 12345) & 0x7fffffff ))
  rnd=$(( (rng_state >> 7) % $1 ))
}

# The lib is the single owner of the documented key list, so the harness reads
# it from there instead of pinning a copy that could drift.
# shellcheck source=scripts/lib-env.sh
source "$LIB"
read -r -a DOC_KEYS <<< "$ENV_FILE_KEYS"

# Independent oracles for the value predicates, each written from the contract
# rather than from the lib's code: one character class in a single bracket
# expression against the lib's chain of per-character globs, a base-10 range
# test against the lib's leading-zero strip.
oracle_reason() {
  # The domain is byte-defined: the lib pins LC_ALL=C for exactly this reason,
  # so an oracle that inherited the operator's UTF-8 session would call "ü"
  # printable and disagree with every container-side check.
  local LC_ALL=C
  case "$1" in
    [[:space:]]*|*[[:space:]])
      printf 'whitespace'
      return 0
      ;;
  esac
  # shellcheck disable=SC1003  # intentional literal-quote bracket expression
  case "$1" in
    *[\'\"\\\|\&\$\`\<\>]*|*[![:print:]]*)
      printf 'charset'
      return 0
      ;;
  esac
  printf ''
}

# The domain oracle as an exit code, so the driver checks a refusal the way the
# lib produces one. The reason string stays the oracle's own vocabulary; the
# lib names the variable it refused and the value never reaches either stream.
oracle_value_rc() { # 0 when the value domain accepts, 1 when it refuses
  if [[ -n "$(oracle_reason "$1")" ]]; then
    printf 1
  else
    printf 0
  fi
}

oracle_length() { printf '%s' "$1" | wc -c | tr -d ' '; }

oracle_port_rc() { # 0 when check_telnet_port accepts, 1 when it refuses
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || { printf 1; return; }
  port="${port#"${port%%[!0]*}"}"
  if [[ -z "$port" ]] || (( ${#port} > 5 )) || (( 10#$port < 1 || 10#$port > 65535 )); then
    printf 1
    return
  fi
  printf 0
}

oracle_switch_rc() { # 0 when the {0,1} domain accepts, 1 when it refuses
  case "$1" in
    0|1) printf 0 ;;
    *) printf 1 ;;
  esac
}

oracle_command_rc() { # 0 when require_command accepts, 2 for a usage error
  local word="$1" IFS='|'
  for w in $COMMAND_WORDS; do
    [[ "$word" == "$w" ]] && { printf 0; return; }
  done
  printf 2
}

# A list of generated payloads as sourceable bash words, so a value holding a
# quote, a newline, or a glob reaches the driver exactly as generated.
quote_each() {
  local item
  for item in ${1+"$@"}; do
    printf '%q ' "$item"
  done
}

# The driver, written to a scratch file and run once per case. It asserts
# everything that needs the loaded environment, one FUZZFAIL line per broken
# invariant, and never exits early, so one case reports all of its findings.
read -r -d '' DRIVER <<'DRIVER_EOF' || true
set -uo pipefail
# shellcheck source=/dev/null
source "$FUZZ_LIB"
# shellcheck source=/dev/null
source "$FUZZ_EXPECT_FILE"

cd "$FUZZ_WORKDIR" || exit 99
report() { printf 'FUZZFAIL %s\n' "$1"; }
scratch() { mktemp "$FUZZ_WORKDIR/.fz.XXXXXX"; }
no_leak() { # text label
  local text="$1" label="$2" secret line
  for secret in "${FUZZ_SECRETS[@]}"; do
    [[ -n "$secret" ]] || continue
    case "$text" in
      *"$secret"*) report "$label carried a value" ;;
    esac
  done
  for line in "${FUZZ_LINES[@]}"; do
    case "$text" in
      *"$line"*) report "$label echoed a line back" ;;
    esac
  done
}

# The environment a run starts in: a variable already set wins over the file.
for k in "${FUZZ_PRESET_KEYS[@]}"; do
  name="FUZZ_PRESET_$k"
  export "$k=${!name}"
done

err="$(scratch)"
out="$(scratch)"
load_rc=0
load_env_file "$FUZZ_CASE_FILE" > "$out" 2> "$err" || load_rc=$?
if (( load_rc != 0 )); then
  report "load_env_file exited $load_rc on a readable file"
fi
if [[ -s "$out" ]]; then
  report "load_env_file wrote to stdout"
fi
load_err="$( < "$err" )"
no_leak "$load_err" "a warning"

# What the case was built to produce, straight from the generator's intent.
for k in "${FUZZ_SET_KEYS[@]}"; do
  name="FUZZ_VALUE_$k"
  if [[ "${!k+x}" != x ]]; then
    report "$k was not exported"
  elif [[ "${!k}" != "${!name}" ]]; then
    report "$k holds a value the case did not ask for"
  fi
done
for k in "${FUZZ_UNSET_KEYS[@]}"; do
  if [[ "${!k+x}" == x ]]; then
    report "$k was exported but the case withheld it"
  fi
done
# A variable the environment already carried keeps the value it had: the file
# does not get the last word.
for k in "${FUZZ_PRESET_KEYS[@]}"; do
  name="FUZZ_PRESET_$k"
  if [[ "${!k}" != "${!name}" ]]; then
    report "$k was overwritten by the file"
  fi
done

# A marker file proves whether a value was executed rather than read.
if [[ -e pwned-marker ]]; then
  report "a .env value was executed"
fi

# The key check is the second entry point over the same bytes, and run.sh runs
# it before the loader, so its verdict has to name what the loader would apply.
keys_err="$(scratch)"
( check_env_file_keys "$FUZZ_CASE_FILE" ) > /dev/null 2> "$keys_err"
keys_rc=$?
if [[ "$keys_rc" != "$FUZZ_KEYCHECK_RC" ]]; then
  report "check_env_file_keys exited $keys_rc, expected $FUZZ_KEYCHECK_RC"
fi
if (( keys_rc != 0 )); then
  keys_out="$( < "$keys_err" )"
  case "$keys_out" in
    *"$FUZZ_CASE_FILE"*) ;;
    *) report "the refusal does not name the file" ;;
  esac
  if [[ -n "$FUZZ_UNKNOWN_KEY" && "$keys_out" != *"$FUZZ_UNKNOWN_KEY"* ]]; then
    report "the refusal does not name the unknown key"
  fi
  no_leak "$keys_out" "the refusal"
fi

# The value predicates take their input from the environment, so the value is
# handed over the way a run would carry it.
probe="$FUZZ_PROBE_VALUE"
if [[ "$(ascii_length "$probe")" != "$FUZZ_LENGTH" ]]; then
  report "ascii_length does not count bytes"
fi
# The value domain is a refusal, not a printed reason: the contract is the exit
# code against an oracle written from the same character class, the variable
# named on the stream, and the value itself in neither stream nor message.
value_err="$(scratch)"
( reject_unsafe_value FUZZ_PROBE "$probe" ) > /dev/null 2> "$value_err"
value_rc=$?
if (( value_rc != FUZZ_VALUE_RC )); then
  report "reject_unsafe_value exited $value_rc, expected $FUZZ_VALUE_RC"
fi
value_msg="$( < "$value_err" )"
if (( value_rc == 0 )); then
  [[ -z "$value_msg" ]] || report "an accepted value still printed $value_msg"
else
  case "$value_msg" in
    *Traceback*) report "reject_unsafe_value leaked a traceback" ;;
    *FUZZ_PROBE*) ;;
    *) report "a value refusal does not name the variable" ;;
  fi
  no_leak "$value_msg" "the refusal"
fi
# A refusal that names the value it refused is the contract; one that leaks a
# traceback or stays silent is not.
port_err="$(scratch)"
( export TELNET_PORT="$probe"; check_telnet_port ) > /dev/null 2> "$port_err"
port_rc=$?
if (( port_rc != FUZZ_PORT_RC )); then
  report "check_telnet_port exited $port_rc, expected $FUZZ_PORT_RC"
fi
port_msg="$( < "$port_err" )"
if (( port_rc == 0 )); then
  [[ -z "$port_msg" ]] || report "an accepted port still printed $port_msg"
else
  case "$port_msg" in
    *Traceback*) report "check_telnet_port leaked a traceback" ;;
    *"$probe"*) ;;
    *) report "a port refusal does not name the value" ;;
  esac
fi
switch_err="$(scratch)"
( export STEAMCMD_UPDATE="$probe" STEAMCMD_ONLY="$probe"; check_steamcmd_env ) > /dev/null 2> "$switch_err"
switch_rc=$?
if (( switch_rc != FUZZ_SWITCH_RC )); then
  report "check_steamcmd_env exited $switch_rc, expected $FUZZ_SWITCH_RC"
fi
switch_msg="$( < "$switch_err" )"
if (( switch_rc == 0 )); then
  [[ -z "$switch_msg" ]] || report "an accepted switch still printed $switch_msg"
else
  case "$switch_msg" in
    *Traceback*) report "check_steamcmd_env leaked a traceback" ;;
    *"$probe"*) ;;
    *) report "a switch refusal does not name the value" ;;
  esac
fi

usage() { printf 'usage: fuzz\n'; }
cmd_err="$(scratch)"
( export FUZZ_WORD="$probe"; require_command "$FUZZ_WORD" "$FUZZ_COMMANDS" usage ) > /dev/null 2> "$cmd_err"
cmd_rc=$?
if (( cmd_rc != FUZZ_CMD_RC )); then
  report "require_command exited $cmd_rc, expected $FUZZ_CMD_RC"
fi
cmd_msg="$( < "$cmd_err" )"
if (( cmd_rc != 0 )); then
  case "$cmd_msg" in
    *Traceback*) report "a usage error leaked a traceback" ;;
    *"$probe"*) ;;
    *) report "a usage error does not name the offending word" ;;
  esac
else
  [[ -z "$cmd_msg" ]] || report "an accepted command word still printed $cmd_msg"
fi

# The argv guards take the extra word the same way, so a word the case is
# holding gets the same treatment: accepted when it is empty, a usage error
# naming it when it is not.
argc_err="$(scratch)"
( export FUZZ_EXTRA="$probe"; require_argc 1 usage "$FUZZ_EXTRA" ) > /dev/null 2> "$argc_err"
argc_rc=$?
if [[ -n "$probe" ]]; then
  if (( argc_rc != 2 )); then
    report "require_argc exited $argc_rc on an extra word, expected 2"
  fi
  case "$( < "$argc_err" )" in
    *"$probe"*) ;;
    *) report "a usage error does not name the extra word" ;;
  esac
else
  if (( argc_rc != 0 )); then
    report "require_argc exited $argc_rc with no extra word, expected 0"
  fi
fi

rm -f "$err" "$out" "$keys_err" "$cmd_err" "$port_err" "$switch_err" "$argc_err" "$value_err"
DRIVER_EOF

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
printf '%s' "$DRIVER" > "$tmp/driver.sh"

LINES=()
SET_KEYS=()
VALUE_OF=()
UNSET_KEYS=()
SECRETS=()
PRESET_KEYS=()
PRESET_OF=()
PENDING_KEYS=()
UNKNOWN_KEY=
EOL=$'\n'
DAMAGE=0
TRAILING=1

# One case. The generated file and the expectations the driver checks against
# are written from the generator's intent; the driver never re-derives them
# from the bytes, so a disagreement is a real defect and not an oracle that
# drifted along with the parser.
generate() {
  LINES=()
  SET_KEYS=()
  VALUE_OF=()
  VALUE_RAW_OF=()
  SET_AT=()
  UNSET_KEYS=()
  SECRETS=()
  PRESET_KEYS=()
  PRESET_OF=()
  PENDING_KEYS=()
  UNKNOWN_KEY=
  EOL=$'\n'
  DAMAGE=0
  TRAILING=1
  pick 8
  if (( rnd == 0 )); then
    EOL=$'\r\n'
  fi
  # The file-level damage is chosen before the lines are, because it changes
  # what the first line means: a BOM makes its key unreadable, and a missing
  # final newline drops the CR a CRLF file put on the last line.
  pick 24
  case $rnd in
    0) DAMAGE=1 ;;
    1) DAMAGE=2 ;;
  esac
  pick 4
  if (( rnd != 0 )); then
    TRAILING=0
  fi
  pick 10
  if (( rnd == 0 )); then
    LINES+=("")
  fi

  # Variables already in the environment win over the file, so a case covers
  # the precedence rule and not only the parse. The driver's environment is
  # this one, so a key that is already set here (PATH, HOME, and anything the
  # harness runner exported) is a preset the loader must leave alone.
  local i key raw raw_value value quote inner kind count applies key_ok tail
  pick 2
  count=$rnd
  for (( i = 0; i < count; i++ )); do
    pick "${#DOC_KEYS[@]}"
    key="${DOC_KEYS[$rnd]}"
    [[ -n "${!key+x}" ]] && continue
    in_list "$key" ${PRESET_KEYS[@]+"${PRESET_KEYS[@]}"} && continue
    PRESET_KEYS+=("$key")
    PRESET_OF+=("a-preset-value")
  done

  pick 11
  count=$rnd
  for (( i = 0; i <= count; i++ )); do
    pick 10
    if (( rnd == 0 )); then
      LINES+=("# comment")
      continue
    fi
    pick 12
    kind=$rnd
    if (( kind < 7 )); then
      pick "${#DOC_KEYS[@]}"
      key="${DOC_KEYS[$rnd]}"
    else
      pick "${#BAD_KEYS[@]}"
      key="${BAD_KEYS[$rnd]}"
    fi
    pick "${#VALUES[@]}"
    inner="${VALUES[$rnd]}"
    value="$inner"
    quote=""
    pick 4
    case $rnd in
      0) quote='"' ;;
      1) quote="'" ;;
    esac
    # A quoted value is stripped only when the line's last character closes
    # the pair, and a value carrying its own newline is a line of its own, so
    # the case splits it the way the file will: the first line is the
    # assignment, the rest are lines without an '=' that the loader skips.
    tail_lines=()
    if [[ "$inner" == *$'\n'* ]]; then
      quote=""
      value="${inner%%$'\n'*}"
      tail="${inner#*$'\n'}"
      if [[ "$tail" == *=* ]]; then
        continue
      fi
      while [[ -n "$tail" ]]; do
        if [[ "$tail" == *$'\n'* ]]; then
          tail_lines+=("${tail%%$'\n'*}")
          tail="${tail#*$'\n'}"
        else
          tail_lines+=("$tail")
          tail=""
        fi
      done
    fi
    raw_value="$quote$inner$quote"
    raw="$key=$raw_value"
    # eff_key is the key the loader will read off this line, which the shape
    # below can change: 'export FOO=x' keeps the key, 'exportFOO=x' does not.
    eff_key="$key"
    applies=1

    # A line the loader is contracted to read another way, for a reason chosen
    # here rather than discovered by the parser.
    pick 14
    case $rnd in
      0) raw="export $raw" ;;
      1)
        # The missing-equals typo an operator actually makes, and the one that
        # used to echo the line back: 'TELNET_PASSWORD hunter2' is a line the
        # loader skips, and the password in it must not reach a log.
        if [[ -z "$inner" || "$inner" == *=* || "$inner" == *$'\n'* ]]; then
          raw="$key"
        else
          raw="$key $inner"
          value="$inner"
        fi
        applies=0
        ;;
      2)
        # 'export' with no space is not the prefix: the key side is the
        # concatenation, and for an empty or well-formed key that lands on a
        # key this project does not document.
        raw="export$raw"
        eff_key="export$key"
        ;;
    esac

    # A BOM in front of the first line makes its key unreadable, so that line
    # is not an assignment any more. A NUL dropped by read(1) is not modelled
    # here: bash drops it from the value it returns, so the key and the value
    # the loader sees are the ones the case generated.
    key_ok=1
    [[ "$eff_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || key_ok=0
    if (( i == 0 )) && (( DAMAGE == 1 )); then
      key_ok=0
      applies=0
    fi

    if (( key_ok )); then
      if (( applies )) && [[ -z "$UNKNOWN_KEY" ]] &&
        ! in_list "$eff_key" ${DOC_KEYS[@]+"${DOC_KEYS[@]}"}; then
        # The key check reads the file, not the environment, so an
        # undocumented key refuses the file even where the loader would skip
        # it. A line with no '=' is not an assignment to either of them.
        UNKNOWN_KEY="$eff_key"
      fi
      if [[ -n "${!eff_key+x}" ]] || in_list "$eff_key" ${PRESET_KEYS[@]+"${PRESET_KEYS[@]}"}; then
        # Already in the environment, or the case pinned it there: the loader
        # must leave the value alone. The driver exports the preset before the
        # load, so the file loses either way.
        if ! in_list "$eff_key" ${PRESET_KEYS[@]+"${PRESET_KEYS[@]}"}; then
          PRESET_KEYS+=("$eff_key")
          PRESET_OF+=("$(printf '%q' "${!eff_key}")")
        fi
      elif ! (( applies )); then
        PENDING_KEYS+=("$eff_key")
      elif in_list "$eff_key" ${SET_KEYS[@]+"${SET_KEYS[@]}"}; then
        : # first occurrence wins; a duplicate must not overwrite it
      else
        SET_KEYS+=("$eff_key")
        VALUE_OF+=("$value")
        VALUE_RAW_OF+=("$raw_value")
        # The index of the line in the file, which is not the loop counter: a
        # case can open with a blank line, and the CR rule below needs to know
        # whether a value sits on the last line.
        SET_AT+=("${#LINES[@]}")
      fi
    elif [[ -n "$eff_key" ]]; then
      # A key the loader cannot expand is a key it cannot set either, unless
      # the environment already carries a variable of that name (a BOM put in
      # front of PATH, say): the loader leaves it alone either way. The verdict
      # is settled after the loop, once every line for this key is known.
      if [[ "$eff_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && [[ -n "${!eff_key+x}" ]]; then
        if ! in_list "$eff_key" ${PRESET_KEYS[@]+"${PRESET_KEYS[@]}"}; then
          PRESET_KEYS+=("$eff_key")
          PRESET_OF+=("$(printf '%q' "${!eff_key}")")
        fi
      else
        PENDING_KEYS+=("$eff_key")
      fi
    fi
    # shellcheck disable=SC2016  # literal payloads: non-expansion is the point
    case "$value" in
      *'$(touch'*|*'`touch'*|hunter2)
        SECRETS+=("$value")
        [[ "$quote" == "$value" ]] || SECRETS+=("$quote$value$quote")
        ;;
    esac
    LINES+=("$raw")
    LINES+=(${tail_lines[@]+"${tail_lines[@]}"})
  done

  # A key whose only lines were skipped was never applied, and nothing about
  # it may reach the environment.
  for key in ${PENDING_KEYS[@]+"${PENDING_KEYS[@]}"}; do
    if ! in_list "$key" ${SET_KEYS[@]+"${SET_KEYS[@]}"} &&
      ! in_list "$key" ${PRESET_KEYS[@]+"${PRESET_KEYS[@]}"}; then
      UNSET_KEYS+=("$key")
    fi
  done

  # A CRLF file puts a CR at the end of every value, and bash's read keeps it:
  # the container then refuses the value as non-printable, which is exactly
  # what an operator editing the file on Windows hits. The last line of a file
  # written without a final newline never got its CR.
  if [[ "$EOL" == $'\r\n' ]]; then
    local j last=$((${#LINES[@]} - 1))
    for j in "${!SET_AT[@]}"; do
      if (( SET_AT[j] != last )) || (( TRAILING )); then
        # A CR on the end is one more character, and a quoted value that ends
        # in a CR is no longer a matching pair of quotes: the loader keeps the
        # quotes, which is why a Windows-edited file is refused downstream
        # rather than quietly half-stripped.
        VALUE_OF[j]="${VALUE_RAW_OF[j]}"$'\r'
      fi
    done
  fi
}

write_case() { # renders LINES into $1, with the damage a real edit leaves behind
  local out="$1" i text="" n=${#LINES[@]}
  for (( i = 0; i < n; i++ )); do
    text+="${LINES[$i]}$EOL"
  done
  if (( ! TRAILING )); then
    # A length-based cut, not ${text%EOL}: a glob pattern does not match a
    # trailing CR, so the CRLF case would keep the line ending it just lost.
    text="${text:0:${#text} - ${#EOL}}"
  fi
  : > "$out"
  if (( DAMAGE == 1 )); then
    printf '\xef\xbb\xbf' >> "$out"
  fi
  if (( DAMAGE == 2 )); then
    # A NUL a binary write or a truncated paste leaves behind. A shell
    # variable cannot hold one, so it goes straight to the file.
    {
      printf '%s' "${text:0:1}"
      printf '\0'
      printf '%s' "${text:1}"
    } >> "$out"
  else
    printf '%s' "$text" >> "$out"
  fi
}

write_expect() { # renders the expectations the driver sources into $1
  local out="$1" probe i long_lines=() line
  pick "${#VALUES[@]}"
  probe="${VALUES[$rnd]}"
  for line in "${LINES[@]}"; do
    # Only a line that carries a payload can leak one: a line with an '=' or a
    # space after the key. A bare key is a substring of the documented-key list
    # the refusal prints on purpose, spaces included.
    [[ "$line" == *=* || "$line" == *' '* ]] || continue
    in_list "${line//[[:space:]]/}" ${DOC_KEYS[@]+"${DOC_KEYS[@]}"} && continue
    (( ${#line} >= 6 )) || continue
    long_lines+=("$line")
  done
  {
    printf 'FUZZ_LIB=%q\n' "$LIB"
    printf 'FUZZ_CASE_FILE=%q\n' "$tmp/case.env"
    printf 'FUZZ_WORKDIR=%q\n' "$tmp/casewd"
    printf 'FUZZ_COMMANDS=%q\n' "$COMMAND_WORDS"
    printf 'FUZZ_PRESET_KEYS=(%s)\n' "$(quote_each ${PRESET_KEYS[@]+"${PRESET_KEYS[@]}"})"
    printf 'FUZZ_SET_KEYS=(%s)\n' "$(quote_each ${SET_KEYS[@]+"${SET_KEYS[@]}"})"
    printf 'FUZZ_UNSET_KEYS=(%s)\n' "$(quote_each ${UNSET_KEYS[@]+"${UNSET_KEYS[@]}"})"
    printf 'FUZZ_SECRETS=(%s)\n' "$(quote_each ${SECRETS[@]+"${SECRETS[@]}"})"
    printf 'FUZZ_LINES=(%s)\n' "$(quote_each ${long_lines[@]+"${long_lines[@]}"})"
    printf 'FUZZ_UNKNOWN_KEY=%q\n' "$UNKNOWN_KEY"
    for i in "${!SET_KEYS[@]}"; do
      printf 'FUZZ_VALUE_%s=%q\n' "${SET_KEYS[$i]}" "${VALUE_OF[$i]}"
    done
    for i in "${!PRESET_KEYS[@]}"; do
      printf 'FUZZ_PRESET_%s=%q\n' "${PRESET_KEYS[$i]}" "${PRESET_OF[$i]}"
    done
    # The key check refuses the file exactly when a well-formed key in it is
    # not one this project documents, whatever else the loader makes of it.
    if [[ -n "$UNKNOWN_KEY" ]]; then
      printf 'FUZZ_KEYCHECK_RC=1\n'
    else
      printf 'FUZZ_KEYCHECK_RC=0\n'
    fi
    printf 'FUZZ_PROBE_VALUE=%q\n' "$probe"
    printf 'FUZZ_LENGTH=%s\n' "$(oracle_length "$probe")"
    printf 'FUZZ_VALUE_RC=%s\n' "$(oracle_value_rc "$probe")"
    printf 'FUZZ_PORT_RC=%s\n' "$(oracle_port_rc "$probe")"
    printf 'FUZZ_SWITCH_RC=%s\n' "$(oracle_switch_rc "$probe")"
    printf 'FUZZ_CMD_RC=%s\n' "$(oracle_command_rc "$probe")"
  } > "$out"
}

SECONDS=0
cases=0
for SEED in "${SEEDS[@]}"; do
  seed_rng
  for (( i = 0; i < ITERATIONS_PER_SEED; i++ )); do
    case_label="seed $SEED case $i"
    rm -rf "$tmp/casewd"
    mkdir -p "$tmp/casewd"
    generate
    write_case "$tmp/case.env"
    write_expect "$tmp/case.expect"
    case_started=$SECONDS
    out="$(
      FUZZ_LIB="$LIB" \
        FUZZ_EXPECT_FILE="$tmp/case.expect" \
        bash "$tmp/driver.sh" 2>&1
    )" || true
    while IFS= read -r line; do
      case "$line" in
        FUZZFAIL*) fail "${line#FUZZFAIL }" ;;
      esac
    done <<< "$out"
    cases=$(( cases + 1 ))
    if (( SECONDS - case_started > CASE_SECONDS )); then
      fail "case exceeded its time budget ($(( SECONDS - case_started ))s)"
    fi
    if (( SECONDS > RUN_SECONDS )); then
      fail "fuzz run exceeded its wall-clock budget (${SECONDS}s)"
      break 2
    fi
    (( violations == 0 )) || break
  done
done

if (( violations > MAX_REPORTED_VIOLATIONS )); then
  echo "FAIL: fuzz: ... and $(( violations - MAX_REPORTED_VIOLATIONS )) more" >&2
fi
if (( violations > 0 )); then
  echo "FAIL: env parser fuzz: $cases cases, $violations broken invariants (${SECONDS}s)" >&2
  exit 1
fi
echo "OK: env parser fuzz: $cases .env cases hold every invariant (${SECONDS}s)"
