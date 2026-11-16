#!/usr/bin/env bash
# Tests for infisical-secret-scanner/scripts/scan-prompt.sh. Each test feeds the hook a UserPromptSubmit input, the way
# Codex does, and checks the result the way Codex reads it:
#   pass       exit 0: the prompt is sent.
#   block      exit 2 and a reason on stderr: the prompt is not sent.
#   fail-open  anything else, including any output on stdout. Codex sends the prompt, so this always fails the test.
#
# Usage: tests/test-scan-prompt.sh [bash binary]. Needs the Infisical CLI and jq. Fake secrets are made at run time.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$REPO/infisical-secret-scanner"
SCRIPT="$PLUGIN/scripts/scan-prompt.sh"
BASH_BIN="${1:-bash}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tmp"

passed=0
failed=0
failures=()

# ----------------------------------------------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------------------------------------------

# Usage: random_chars <tr set> <length>. Reads random bytes in rounds instead of cutting off an endless stream, so tr
# never writes to a closed pipe, which GNU tr reports when SIGPIPE is ignored, as on GitHub's runners.
random_chars() {
  local chars=""
  while [ "${#chars}" -lt "$2" ]; do
    chars="$chars$(head -c $(($2 * 12 + 256)) /dev/urandom | LC_ALL=C tr -dc "$1")"
  done
  printf '%s' "${chars:0:$2}"
}

random_alnum() {
  random_chars 'A-Za-z0-9' "$1"
}

github_token() {
  printf 'ghp_%s' "$(random_alnum 36)"
}

# Unique to this run, to find processes a hook left running without seeing other runs' ones.
RUN_ID="$$$RANDOM"
GH1="$(github_token)"
GH2="$(github_token)"
GH3="$(github_token)"
GH4="$(github_token)"
SLACK="xoxb-$(random_alnum 12 | tr -dc 0-9)1234567890-$(random_alnum 13 | tr -dc 0-9)1234567890-$(random_alnum 24)"

# Usage: tool_dir [tool...]. A folder of links to the tools the hook needs, without the ones named.
tool_dir() {
  local dir="$WORK/bin-$RANDOM$RANDOM" tool path
  mkdir -p "$dir"
  for tool in bash sh cat cut dirname mktemp rm mkdir cp find shasum sha256sum sleep jq infisical env; do
    case " $* " in *" $tool "*) continue ;; esac
    path="$(command -v "$tool" 2>/dev/null)" || continue
    ln -s "$path" "$dir/$tool"
  done
  echo "$dir"
}

# Usage: fake_tool <name> <body>. A tool folder where the named command runs the body.
fake_tool() {
  local dir
  dir="$(tool_dir "$1")"
  printf '#!/bin/bash\n%s\n' "$2" >"$dir/$1"
  chmod +x "$dir/$1"
  echo "$dir"
}

# Usage: fake_report <JSON>. A fake infisical that writes the JSON as its report and says it found secrets.
fake_report() {
  fake_tool infisical "while [ \$# -gt 0 ]; do [ \"\$1\" = --report-path ] && printf '%s' '$1' >\"\$2\"; shift; done; exit 42"
}

new_data() {
  local dir="$WORK/data-$RANDOM$RANDOM"
  mkdir -p "$dir"
  echo "$dir"
}

DATA="$(new_data)"

# Usage: run_hook <prompt> [extra JSON fields]. Runs the hook with the prompt. Uses ENV_PATH, ENV_ROOT, ENV_DATA,
# ENV_EXTRA, RUN_DIR and HOOK_SCRIPT when set. Sets OUT (the reason), ERR, CODE, SECONDS_TAKEN and RESULT.
run_hook() {
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  # Through a file: Linux limits one argument to 128 KB.
  printf '%s' "$1" >"$WORK/prompt"
  jq -n --rawfile prompt "$WORK/prompt" --argjson extra "$extra" '{
    session_id: "s", turn_id: "t", transcript_path: null, cwd: "/tmp", hook_event_name: "UserPromptSubmit",
    model: "m", permission_mode: "default", prompt: $prompt
  } + $extra' >"$WORK/input.json"
  run_input "$WORK/input.json"
}

# Usage: run_input <file holding the hook input>
run_input() {
  local env_args=(PATH="${ENV_PATH:-$PATH}" HOME="$HOME" TMPDIR="$WORK/tmp") start=$SECONDS
  if [ "${ENV_ROOT-unset}" = unset ]; then env_args+=(PLUGIN_ROOT="$PLUGIN"); elif [ -n "$ENV_ROOT" ]; then env_args+=(PLUGIN_ROOT="$ENV_ROOT"); fi
  if [ "${ENV_DATA-unset}" = unset ]; then env_args+=(PLUGIN_DATA="$DATA"); elif [ -n "$ENV_DATA" ]; then env_args+=(PLUGIN_DATA="$ENV_DATA"); fi
  # shellcheck disable=SC2206
  [ -n "${ENV_EXTRA:-}" ] && env_args+=($ENV_EXTRA)

  (cd "${RUN_DIR:-$WORK}" && env -i "${env_args[@]}" "$BASH_BIN" "${HOOK_SCRIPT:-$SCRIPT}" \
    <"$1" >"$WORK/out" 2>"$WORK/err")
  CODE=$?
  SECONDS_TAKEN=$((SECONDS - start))
  OUT="$(cat "$WORK/err")"
  ERR="$OUT"
  STDOUT="$(cat "$WORK/out")"

  if [ -n "$STDOUT" ]; then
    RESULT=fail-open
  elif [ "$CODE" -eq 0 ]; then
    RESULT=pass
  elif [ "$CODE" -eq 2 ] && [ -n "$(printf '%s' "$ERR" | tr -d '[:space:]')" ]; then
    RESULT=block
  else
    RESULT=fail-open
  fi
}

ok() {
  passed=$((passed + 1))
  printf '  ok    %s\n' "$1"
}

fail() {
  local stdout="${STDOUT:-}" stderr="${ERR:-}"
  failed=$((failed + 1))
  failures+=("$1")
  printf '  FAIL  %s\n        result=%s code=%s seconds=%s\n        stdout: %s\n        stderr: %s\n' "$1" \
    "${RESULT:-}" "${CODE:-}" "${SECONDS_TAKEN:-}" "${stdout:0:600}" "${stderr:0:600}"
}

# Usage: check <name> <command...>. Passes when the command succeeds.
check() {
  local name="$1"
  shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}

# Usage: expect <name> <pass|block> [text the reason must contain] [text the reason must not contain]
expect() {
  local name="$1" want="$2" contains="${3:-}" excludes="${4:-}"
  if [ "$RESULT" != "$want" ]; then
    fail "$name (wanted $want)"
  elif [ -n "$contains" ] && [[ "$OUT" != *"$contains"* ]]; then
    fail "$name (reason lacks: $contains)"
  elif [ -n "$excludes" ] && [[ "$OUT" == *"$excludes"* ]]; then
    fail "$name (reason has: $excludes)"
  else
    ok "$name"
  fi
}

allowlist() {
  ls "${1:-$DATA}/allowlist" 2>/dev/null
}

allowlist_count() {
  allowlist "$@" | wc -l | tr -d ' '
}

took_less_than() {
  [ "$SECONDS_TAKEN" -lt "$1" ]
}

echo "Testing $SCRIPT with $("$BASH_BIN" -c 'echo bash $BASH_VERSION') and $(infisical --version 2>&1 | head -1)"

# ----------------------------------------------------------------------------------------------------------------------
echo "Prompts"
# ----------------------------------------------------------------------------------------------------------------------

run_hook "Refactor the payment module to use dependency injection."
expect "clean prompt passes" pass
run_hook ""
expect "empty prompt passes" pass
run_hook "My token is $GH1, why does the API return 401?"
expect "GitHub token is blocked" block "github-pat on line 1, starts with ghp_" "$GH1"
run_hook "line one
export SLACK_TOKEN=$SLACK
line three
GITHUB=$GH2"
expect "secrets on several lines are blocked" block "on line 4" "$GH2"
check "the reason lists the Slack token's line" test "${OUT#*on line 2}" != "$OUT"
run_hook "$(printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA%s\n%s\n-----END RSA PRIVATE KEY-----' "$(random_alnum 60)" "$(random_alnum 64)")"
expect "private key is blocked" block "private-key"
run_hook "$(printf 'Windows line endings\r\nTOKEN=%s\r\n' "$GH1")"
expect "CRLF prompt with a secret is blocked" block "github-pat"
run_hook "Unicode ✓ ünïcödé \"quotes\" \\backslash\\ \$dollar \`tick\` TOKEN=$GH1"
expect "special characters with a secret are blocked" block "github-pat"
jq -n --arg token "$GH1" '{prompt: ("before a NUL \u0000 after it TOKEN=" + $token)}' >"$WORK/nul.json"
run_input "$WORK/nul.json"
expect "a secret after a NUL character is blocked" block "github-pat"

echo "Placeholders"
run_hook "Set GITHUB_TOKEN=<your-github-token> and API_KEY=your_api_key_here in .env"
expect "placeholders pass" pass
run_hook "Use token=ghp_EXAMPLE$(random_alnum 29) in the docs"
expect "a one-word value marked as an example passes" pass
run_hook "Post to https://hooks.slack.com/services/T0$(random_alnum 7)/B0EXAMPLE/$(random_alnum 24)"
expect "a whole-URL secret that contains EXAMPLE is still blocked" block "slack"

echo "Inline ignore comments"
run_hook "GITHUB_TOKEN=$GH1 # gitleaks:allow"
expect "a gitleaks:allow comment doesn't hide a secret" block "github-pat"
run_hook "const token = \"$GH1\"; // GitLeaks:Allow"
expect "a gitleaks:allow comment in another case doesn't hide a secret" block "github-pat"

markers="TOKEN=$(github_token)
$(awk 'BEGIN { for (i = 0; i < 27000; i++) print "x gitleaks:allow" }')"
run_hook "$markers"
expect "a secret before 27000 gitleaks:allow comments is blocked" block "github-pat"
check "and is done in under 15 seconds" took_less_than 15
spaces="$(head -c 150000 /dev/zero | tr '\0' ' ')"
run_hook "token $(github_token)$spaces"
expect "a secret before 150000 spaces is blocked" block "github-pat"
check "and is done in under 15 seconds" took_less_than 15

echo "Large prompts"
big="$(random_chars 'a-z ' 1000000)"
run_hook "$big"
expect "1 MB clean prompt passes" pass
check "1 MB prompt scans in under 15 seconds" took_less_than 15
run_hook "${big:0:500000} TOKEN=$GH3 ${big:0:500000}"
expect "secret in a 1 MB prompt is blocked" block "github-pat"
log=""
for i in $(seq 2500); do log="${log}2026-11-13T10:00:$i GET /api/repos Authorization: token $GH4 status=401
"; done
run_hook "$log"
expect "a log with the same token on 2500 lines is blocked" block "github-pat on line 1"
check "and lists the token once" test "$(printf '%s' "$OUT" | grep -c github-pat)" = 1
check "and is done in under 15 seconds" took_less_than 15
many=""
for i in $(seq 1500); do many="${many}TOKEN_$i=$(github_token)
"; done
run_hook "$many"
expect "1500 different tokens are blocked" block "and 1490 more"
check "and are done in under 20 seconds" took_less_than 20

# ----------------------------------------------------------------------------------------------------------------------
echo "Allow and disallow"
# ----------------------------------------------------------------------------------------------------------------------

DATA="$(new_data)"
run_hook "\$infisical-secret-scanner:allow $GH1"
expect "allow confirms" block "allowed this secret" "$GH1"
check "the confirmation names what was allowed" test "${OUT#*github-pat, starts with ghp_}" != "$OUT"
check "allow stores hashes" test "$(allowlist_count)" -ge 1
check "the allowlist holds no secret value" sh -c "! grep -rqF '$GH1' '$DATA'"
mode="$(stat -c '%a' "$DATA/allowlist" 2>/dev/null || stat -f '%Lp' "$DATA/allowlist")"
check "the allowlist folder is private (700)" test "$mode" = 700
run_hook "My token is $GH1, why does the API return 401?"
expect "an allowed secret passes" pass
run_hook "TOKEN=$GH1 and OTHER=$GH2"
expect "an allowed secret next to another one is blocked" block "github-pat"
check "the reason lists only the secret that is not allowed" test "$(printf '%s' "$OUT" | grep -c github-pat)" = 1
run_hook "\$infisical-secret-scanner:disallow $GH1"
expect "disallow confirms" block "secret disallowed" "$GH1"
check "disallow removes the hashes" test "$(allowlist_count)" = 0
run_hook "My token is $GH1"
expect "a disallowed secret is blocked again" block "github-pat"
run_hook "\$infisical-secret-scanner:disallow $GH1"
expect "disallowing a secret that is not allowed changes nothing" block "was not allowed"
run_hook "\$infisical-secret-scanner:allow \"$GH2\""
expect "allow a quoted value" block "allowed this secret"
run_hook "TOKEN=$GH2"
expect "a quoted allow applies to the bare value" pass
run_hook "\$infisical-secret-scanner:allow GITHUB_TOKEN=$GH3"
expect "allow a KEY=value line" block "allowed this secret"
run_hook "please use $GH3 in the request"
expect "a KEY=value allow applies to the value alone" pass
run_hook "$(printf '  \n\t$infisical-secret-scanner:disallow   %s  \n' "$GH3")"
expect "a command after leading whitespace runs" block "secret disallowed"
run_hook "\$infisical-secret-scanner:allow not-a-secret-just-text"
expect "allow a value the scanner doesn't flag" block "allowed the value you gave"

echo "Allow only one value"
before="$(allowlist)"
run_hook "\$infisical-secret-scanner:allow $GH4
that one is a revoked test token. Why does prod fail with this .env?
GITHUB_TOKEN=$GH1"
expect "allow with another secret on a later line is refused" block "holds 2 secrets"
run_hook "\$infisical-secret-scanner:allow $GH4 and also $GH1"
expect "allow with two secrets on one line is refused" block "holds 2 secrets"
run_hook "\$infisical-secret-scanner:allow $GH4
that one is a revoked test token, why does prod fail?"
expect "allow with text on a later line is refused" block "on the same line"
for separator in '\u2028' '\u2029' '\u0085' '\u000b' '\f'; do
  jq -n --arg a "\$infisical-allow $GH4" --arg b "why does prod fail?" --arg c "GITHUB_TOKEN=$GH1" \
    "{prompt: (\$a + \"$separator\" + \$b)}" >"$WORK/sep.json"
  run_input "$WORK/sep.json"
  expect "allow with text after a $separator line break is refused" block "on the same line"
  jq -n --arg a "\$infisical-allow $GH4" --arg c "GITHUB_TOKEN=$GH1" "{prompt: (\$a + \"$separator\" + \$c)}" >"$WORK/sep.json"
  run_input "$WORK/sep.json"
  expect "allow with a secret after a $separator line break is refused" block "Nothing was changed"
done
run_hook "\$infisical-secret-scanner:allow $log"
expect "allow with a pasted log is refused" block "on the same line"
check "and is done in under 15 seconds" took_less_than 15
check "none of those changed the allowlist" test "$(allowlist)" = "$before"
run_hook "\$infisical-secret-scanner:allow
$GH4
"
expect "allow with the value alone on the next line works" block "allowed this secret"
run_hook "use $GH4"
expect "and the secret passes" pass
key="$(printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA%s\n%s\n-----END RSA PRIVATE KEY-----' "$(random_alnum 60)" "$(random_alnum 64)")"
run_hook "\$infisical-secret-scanner:allow $key"
expect "allow a private key that spans lines" block "allowed this secret"
run_hook "Why does this key fail?
$key"
expect "the allowed private key passes" pass
run_hook "\$infisical-secret-scanner:disallow $key"
expect "disallow the private key" block "secret disallowed"
jq -n --arg a "\$infisical-secret-scanner:allow -----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA$(random_alnum 60)" --arg b "$(random_alnum 64)
-----END RSA PRIVATE KEY-----" '{prompt: ($a + "\u0000" + $b)}' >"$WORK/nulkey.json"
run_input "$WORK/nulkey.json"
expect "allow a private key with a NUL character inside is refused" block "could not read the secret scan report"

echo "Command names"
run_hook "\$infisical-secret-scanner:allow"
expect "allow without a value asks for one" block "put the secret to allow"
run_hook "\$infisical-secret-scanner:allow    "
expect "allow with only spaces asks for one" block "put the secret to allow"
run_hook "\$infisical-secret-scanner:disallow"
expect "disallow without a value asks for one" block "put the secret to disallow"
before="$(allowlist)"
run_hook "\$infisical-secret-scanner:allowance $GH1"
expect "a longer word is not the command" block "because it contains secrets"
run_hook "please run \$infisical-secret-scanner:allow $GH1"
expect "the command in the middle of a prompt is not run" block "because it contains secrets"
run_hook "infisical-secret-scanner:allow $GH1"
expect "the command without \$ is not run" block "because it contains secrets"
run_hook "\$infisical-allowance $GH1"
expect "a longer word than the short command is not the command" block "because it contains secrets"
check "none of those changed the allowlist" test "$(allowlist)" = "$before"
run_hook "\$infisical-secret-scanner:allow $GH1" '{"agent_id": "agent-1", "agent_type": "worker"}'
expect "a subagent prompt can't allow a secret" block "because it contains secrets"
check "the subagent prompt left the allowlist unchanged" test "$(allowlist)" = "$before"
run_hook "\$infisical-allow $GH1"
expect "the short command allows" block "allowed this secret"
run_hook "TOKEN=$GH1"
expect "a secret allowed with the short command passes" pass
run_hook "\$infisical-disallow $GH1"
expect "the short command disallows" block "secret disallowed"

echo "IDE context"
ide="# Context from my IDE setup:

## Active file: src/app.ts

## Open tabs:
- app.ts: src/app.ts
"
run_hook "${ide}
## My request for Codex:
\$infisical-secret-scanner:allow $GH1
"
expect "allow works with IDE context before it" block "allowed this secret"
run_hook "${ide}
## My request for Codex:
use $GH1 for the call"
expect "a secret allowed with IDE context passes" pass
run_hook "${ide}
## My request for Codex:
\$infisical-disallow $GH1"
expect "disallow works with IDE context before it" block "secret disallowed"
run_hook "# Context from my IDE setup:

## Selection:
const token = \"$(github_token)\";

## My request for Codex:
what does this line do?"
expect "a secret in the IDE context is blocked" block "github-pat"

# ----------------------------------------------------------------------------------------------------------------------
echo "Failures block the prompt"
# ----------------------------------------------------------------------------------------------------------------------

ENV_PATH="$(tool_dir infisical)"
run_hook "hello"
expect "missing Infisical CLI blocks" block "Infisical CLI is not installed"
ENV_PATH="$(tool_dir jq)"
run_hook "hello"
expect "missing jq blocks" block "jq is not installed"
ENV_PATH="$(fake_tool infisical 'exit 1')"
run_hook "hello"
expect "a scan error blocks" block "scan failed (exit code 1)"
ENV_PATH="$(fake_tool infisical 'exit 0')"
run_hook "hello"
expect "a fake clean scan passes" pass
ENV_PATH="$(fake_report 'not json')"
run_hook "hello"
expect "a scan report that is not JSON blocks" block "could not read the secret scan report"
ENV_PATH="$(fake_report '{}')"
run_hook "hello"
expect "a scan report that is not a list blocks" block "could not read the secret scan report"
ENV_PATH="$(fake_report '[1, 2]')"
run_hook "hello"
expect "findings that are not objects block" block "could not read the secret scan report"
ENV_PATH="$(fake_report '[{"RuleID": "x", "Secret": 5}]')"
run_hook "hello"
expect "a finding whose secret is not text blocks" block "could not read the secret scan report"
run_hook "\$infisical-allow abc"
expect "a bad report blocks allow" block "could not read the secret scan report"
ENV_PATH="$(fake_report '')"
run_hook "hello"
expect "an empty scan report blocks" block "could not read the secret scan report"
ENV_PATH="$(fake_tool infisical 'exit 42')"
run_hook "hello"
expect "a missing scan report blocks" block "could not read the secret scan report"
ENV_PATH="$(fake_tool shasum 'exit 1')"
rm -f "$ENV_PATH/sha256sum"
run_hook "TOKEN=$GH1"
expect "a hash failure blocks" block "could not hash"
unset ENV_PATH

echo "Time limit"
ENV_PATH="$(fake_tool infisical "exec sleep 30.$RUN_ID")"
ENV_EXTRA="INFISICAL_SCAN_TIMEOUT=2"
run_hook "hello"
expect "a hanging scan blocks" block "took longer than 2 seconds"
check "a hanging scan blocks within its time limit" took_less_than 5
sleep 0.5
check "and leaves no process running" test -z "$(pgrep -f "sleep 30.$RUN_ID")"
run_hook "\$infisical-secret-scanner:allow $GH1"
expect "a hanging scan during allow blocks" block "took longer than 2 seconds"
ENV_PATH="$(fake_tool infisical "sleep 31.$RUN_ID & wait")"
run_hook "hello"
expect "a hanging scan with child processes blocks" block "took longer than 2 seconds"
check "and returns within its time limit" took_less_than 5
sleep 0.5
check "and leaves no process running" test -z "$(pgrep -f "sleep 31.$RUN_ID")"
ENV_PATH="$(fake_tool jq 'exec sleep 30')"
run_hook "hello"
expect "a hanging jq blocks" block "took longer than 2 seconds"
check "and returns within its time limit" took_less_than 5
unset ENV_PATH
jq -n '{prompt: "hello"}' >"$WORK/slow.json"
# The hook is timed on its own: the pipeline lasts as long as the input stays open.
{ cat "$WORK/slow.json"; sleep 8; } | {
  start=$SECONDS
  env -i PATH="$PATH" HOME="$HOME" PLUGIN_ROOT="$PLUGIN" PLUGIN_DATA="$DATA" INFISICAL_SCAN_TIMEOUT=2 \
    "$BASH_BIN" "$SCRIPT" >/dev/null 2>"$WORK/err"
  echo "$? $((SECONDS - start))" >"$WORK/slow.result"
}
read -r CODE SECONDS_TAKEN <"$WORK/slow.result"
ERR="$(cat "$WORK/err")" STDOUT="" RESULT=""
check "input that stays open blocks at the time limit" test "$CODE" = 2 -a "${ERR#*took longer than 2 seconds}" != "$ERR"
check "and returns within its time limit" took_less_than 5
unset ENV_EXTRA
for value in abc 0 -5 '1+1' 'a[$(id>/tmp/infisical-injected)]'; do
  ENV_EXTRA="INFISICAL_SCAN_TIMEOUT=$value"
  run_hook "hello"
  expect "a time limit of '$value' falls back to the default" pass
done
unset ENV_EXTRA
check "the time limit is never evaluated as code" test ! -e /tmp/infisical-injected
ENV_PATH="$(fake_tool infisical 'exec sleep 120')"
ENV_EXTRA="INFISICAL_SCAN_TIMEOUT=100"
run_hook "hello"
expect "a time limit above 45 seconds is lowered to 45" block "took longer than 45 seconds"
check "and the run ends before Codex's 60-second timeout" took_less_than 50
unset ENV_PATH ENV_EXTRA

echo "Bad input"
printf 'this is not JSON' >"$WORK/raw"
run_input "$WORK/raw"
expect "input that is not JSON blocks" block "could not read the prompt"
: >"$WORK/raw"
run_input "$WORK/raw"
expect "empty input blocks" block "could not read the prompt"
printf '{"prompt": 42}' >"$WORK/raw"
run_input "$WORK/raw"
expect "a prompt that is not text blocks" block "could not read the prompt"
printf '{"cwd": "/tmp"}' >"$WORK/raw"
run_input "$WORK/raw"
expect "input without a prompt blocks" block "could not read the prompt"

echo "Environment problems"
ENV_ROOT="$WORK/nowhere"
run_hook "hello"
expect "a missing scan config blocks" block "could not find the plugin's scan config"
unset ENV_ROOT
ENV_PATH="$(fake_tool mktemp 'exit 1')"
run_hook "hello"
expect "no temporary folder blocks" block "temporary folder"
unset ENV_PATH
# Root can write to a read-only folder, so this runs only as another user.
if [ "$(id -u)" != 0 ]; then
  readonly_data="$(new_data)"
  chmod 500 "$readonly_data"
  ENV_DATA="$readonly_data"
  run_hook "\$infisical-secret-scanner:allow $GH1"
  expect "an allowlist that can't be written blocks" block "could not save"
  chmod 700 "$readonly_data"
  unset ENV_DATA
fi
sed 's/^  trap on_exit EXIT$/  trap on_exit EXIT; exit 7/' "$SCRIPT" >"$WORK/crash.sh"
HOOK_SCRIPT="$WORK/crash.sh" ENV_ROOT="$PLUGIN"
run_hook "hello"
expect "an unexpected error exit blocks" block "exit code 7"
sed 's/^  trap on_exit EXIT$/  trap on_exit EXIT; no_such_command_xyz; exit $?/' "$SCRIPT" >"$WORK/crash.sh"
run_hook "hello"
expect "a bash error blocks" block "exit code 127"
sed 's/^  require_tools$/  exit 7/' "$SCRIPT" >"$WORK/crash.sh"
run_hook "hello"
expect "an unexpected error exit in the worker blocks" block "exit code 7"
sed 's/^  require_tools$/  kill -9 $BASHPID 2>\/dev\/null || kill -9 $(sh -c "echo \\$PPID")/' "$SCRIPT" >"$WORK/crash.sh"
run_hook "hello"
expect "a killed worker blocks" block "exit code 137"
sed 's/^  trap on_exit EXIT$/  trap on_exit EXIT; echo noise/' "$SCRIPT" >"$WORK/crash.sh"
run_hook "TOKEN=$(github_token)"
expect "a command that prints to stdout can't reach Codex" block "github-pat"
unset HOOK_SCRIPT ENV_ROOT

echo "Temporary files"
run_hook "TOKEN=$GH4"
check "no temporary folder is left after a run" test -z "$(ls "$WORK/tmp")"
mkdir -p "$WORK/tmp/infisical-secret-scanner.old123" "$WORK/tmp/infisical-secret-scanner.new123" "$WORK/tmp/other.old123"
touch -t 202001010000 "$WORK/tmp/infisical-secret-scanner.old123" "$WORK/tmp/other.old123"
run_hook "hello"
check "a folder left by a killed run is removed" test ! -e "$WORK/tmp/infisical-secret-scanner.old123"
check "a folder of a run that may still be going is kept" test -e "$WORK/tmp/infisical-secret-scanner.new123"
check "other folders are kept" test -e "$WORK/tmp/other.old123"
rm -rf "$WORK/tmp"/*

# ----------------------------------------------------------------------------------------------------------------------
echo "Config"
# ----------------------------------------------------------------------------------------------------------------------

override="$(new_data)"
printf '[extend]\nuseDefault = true\n[[allowlists]]\ndescription = "everything"\nregexTarget = "secret"\nregexes = [".*"]\n' \
  >"$override/infisical-scan.toml"
ENV_DATA="$override"
run_hook "TOKEN=$GH1"
expect "a config in the data folder replaces the default" pass
unset ENV_DATA
project="$WORK/project"
mkdir -p "$project"
cp "$override/infisical-scan.toml" "$project/.infisical-scan.toml"
cp "$override/infisical-scan.toml" "$project/.gitleaks.toml"
RUN_DIR="$project"
run_hook "TOKEN=$GH1"
expect "a config in the project is ignored" block "github-pat"
unset RUN_DIR

echo "Without plugin variables (as a managed hook)"
codex_home="$WORK/codex-home"
ENV_ROOT="" ENV_DATA="" ENV_EXTRA="CODEX_HOME=$codex_home"
run_hook "TOKEN=$GH1"
expect "a secret is blocked" block "github-pat"
run_hook "\$infisical-allow $GH1"
expect "allow works" block "allowed this secret"
check "the allowlist is in CODEX_HOME" test -n "$(allowlist "$codex_home/infisical-secret-scanner")"
run_hook "TOKEN=$GH1"
expect "the allowed secret passes" pass
claude_data="$(new_data)"
ENV_EXTRA="CLAUDE_PLUGIN_ROOT=$PLUGIN CLAUDE_PLUGIN_DATA=$claude_data"
run_hook "\$infisical-allow $GH2"
expect "CLAUDE_PLUGIN_* variables work" block "allowed this secret"
check "CLAUDE_PLUGIN_DATA holds the allowlist" test "$(allowlist_count "$claude_data")" -ge 1
unset ENV_ROOT ENV_DATA ENV_EXTRA

# ----------------------------------------------------------------------------------------------------------------------
echo "Concurrency"
# ----------------------------------------------------------------------------------------------------------------------

DATA="$(new_data)"
pids=()
for _ in 1 2 3 4 5 6 7 8; do
  (
    secret="$(github_token)"
    run() {
      jq -n --arg p "$1" '{prompt: $p}' |
        env -i PATH="$PATH" HOME="$HOME" PLUGIN_ROOT="$PLUGIN" PLUGIN_DATA="$DATA" "$BASH_BIN" "$SCRIPT" 2>&1 >/dev/null
    }
    out="$(run "\$infisical-allow $secret")"
    [ $? -eq 2 ] && [[ "$out" == *"allowed this secret"* ]] || exit 1
    run "use $secret" >/dev/null
  ) &
  pids+=($!)
done
bad=0
for pid in "${pids[@]}"; do wait "$pid" || bad=$((bad + 1)); done
RESULT="" CODE="" STDOUT="" ERR="" SECONDS_TAKEN=""
check "8 sessions allow and use secrets at the same time" test "$bad" = 0
check "all 8 secrets are stored" test "$(allowlist_count)" -ge 8

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ] || {
  printf '  - %s\n' "${failures[@]}"
  exit 1
}
